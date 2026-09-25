#!/usr/bin/env bash
# docker/agent-box/agent-box.sh
# Host-side wrapper for the agent box: a Linux container running Claude Code
# plus the whole homelab toolchain as a non-root user, with its own identity
# and an egress denylist firewall. See README.md next to this file.
#
# HOW the box runs (mounts, caps, env) is defined in compose.yaml and its
# overlays. This script adds what compose cannot: deriving values from the
# repo (SSH target, working dir), the two workflows that need HOST
# credentials once (identity, kubeconfig), and Git Bash path/TTY quirks.
#
# Usage:
#   agent-box.sh build [--no-cache]        build the image (pins: image/Dockerfile ARGs + mise.toml)
#   agent-box.sh shell                     interactive bash in the box
#   agent-box.sh claude [args...]          run Claude Code in the box
#   agent-box.sh run <cmd> [args...]       run one command in the box
#   agent-box.sh batch [options] [--] [prompt...]
#                                          run the agent unattended on one prompt, print
#                                          its output, exit with its outcome (see below)
#   agent-box.sh mcp [--dir DIR | --workspace]
#                                          Claude Code as an MCP server on stdin/stdout
#   agent-box.sh doctor                    check tools, logins, reach, firewall
#   agent-box.sh identity [--authorize-homelab] [--github]
#                                          print the box's SSH key; optionally install it
#   agent-box.sh kubeconfig                mint a box-only kubeconfig from a k3s ServiceAccount
#   agent-box.sh compose [--open] [--ci] <compose args...>
#                                          docker compose with derived env + overlays applied
#   agent-box.sh config                    show effective knobs, then the rendered compose config
#   agent-box.sh help
#
# batch options (the prompt is the words, or --prompt-file, or piped stdin):
#   -f, --prompt-file FILE    read the prompt from FILE ('-' = stdin)
#   -o, --output FMT          text (default) | json (one result object) | stream-json
#   -t, --timeout DUR         agent wall clock: 90s, 30m, 2h; 0 = none  [AGENT_BOX_BATCH_TIMEOUT]
#   -m, --max-turns N         stop after N agent turns                  [AGENT_BOX_BATCH_MAX_TURNS]
#       --permission-mode M   claude --permission-mode: acceptEdits, auto, bypassPermissions, ...
#                                                                      [AGENT_BOX_BATCH_PERMISSION_MODE]
#   -C, --dir DIR             the ONLY host directory mounted (default: the current directory)
#       --workspace           mount all of AGENT_BOX_WORKSPACE instead; start in --dir inside it
#   -a, --claude-arg ARG      extra argument for claude, repeatable (-a --model -a sonnet)
# batch exit codes: 0 done, 2 agent error, 3 max turns reached, 4 no result,
#   124 timed out, 64 usage, 1 the box could not start (reason on stderr).
# mcp takes --dir/--workspace with the same meaning; its stdout is protocol only.
#
# Configuration (env > ~/.config/agent-box/env > default): see lib/config.sh.
# Runs from bash on Linux/macOS and from Git Bash on Windows; needs only
# docker (plus kubectl on the host for `kubeconfig`, ssh/gh for `identity`
# installs). Deliberately does not depend on mise/usage/task so it works on
# a fresh host before any of that exists.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=lib/paths.sh
source "$SCRIPT_DIR/lib/paths.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/docker.sh
source "$SCRIPT_DIR/lib/docker.sh"

AGENT_BOX_REPO="$(repo_root_from "$SCRIPT_DIR")" || die "not inside a git checkout"
load_config

usage() { sed -n '/^# Usage:/,/^# Configuration/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; }

# compose_files [--open] [--ci] -> prints the -f arguments for the stack:
# base, then compose.override.yaml if present (compose only auto-loads it
# when no -f is given, so we add it explicitly), then requested overlays.
compose_files() {
  local -a files=("$SCRIPT_DIR/compose.yaml")
  [[ -f "$SCRIPT_DIR/compose.override.yaml" ]] && files+=("$SCRIPT_DIR/compose.override.yaml")
  local a
  for a in "$@"; do
    case "$a" in
      --open) files+=("$SCRIPT_DIR/compose.open.yaml") ;;
      --ci)   files+=("$SCRIPT_DIR/compose.ci.yaml") ;;
      --scoped) files+=("$SCRIPT_DIR/compose.scoped.yaml") ;;
    esac
  done
  local f
  for f in "${files[@]}"; do printf -- '-f\n%s\n' "$(host_to_docker_path "$f")"; done
}

# compose [--open] [--ci] <args...> -> `docker compose` with the stack and
# derived environment applied. Everything else in this script goes through it.
compose() {
  local -a overlays=() fargs=()
  while [[ "${1:-}" == --open || "${1:-}" == --ci || "${1:-}" == --scoped ]]; do overlays+=("$1"); shift; done
  mapfile -t fargs < <(compose_files "${overlays[@]}")
  export_derived_for_compose
  dockr compose --project-directory "$(host_to_docker_path "$SCRIPT_DIR")" "${fargs[@]}" "$@"
}

# Same, but exec'd with the TTY shim so interactive sessions get a real terminal.
compose_exec() {
  local -a overlays=() fargs=()
  while [[ "${1:-}" == --open || "${1:-}" == --ci ]]; do overlays+=("$1"); shift; done
  mapfile -t fargs < <(compose_files "${overlays[@]}")
  export_derived_for_compose
  local tty
  tty="$(docker_tty_prefix)"
  export MSYS_NO_PATHCONV=1   # process is replaced by exec; see lib/docker.sh
  # shellcheck disable=SC2086  # $tty is empty or the single word "winpty"
  exec $tty docker compose --project-directory "$(host_to_docker_path "$SCRIPT_DIR")" "${fargs[@]}" "$@"
}

cmd_build() {
  docker_require
  log_info "building ${AGENT_BOX_IMAGE} (repo context: $AGENT_BOX_REPO)"
  compose build "$@" box
  log_info "built ${AGENT_BOX_IMAGE}"
}

# require_runtime: docker, the image, the home volume. require_image adds
# the workspace, which batch/mcp need only with --workspace.
require_runtime() {
  docker_require
  image_exists "$AGENT_BOX_IMAGE" || die "image $AGENT_BOX_IMAGE not built yet: run '$(basename "$0") build'"
  volume_ensure "$AGENT_BOX_VOLUME"   # compose.yaml declares it external
}
require_image() {
  require_runtime
  [[ -d "$AGENT_BOX_WORKSPACE_HOST" ]] || die "workspace $AGENT_BOX_WORKSPACE_HOST does not exist"
}

cmd_shell()  { require_image; compose_exec run --rm box; }
cmd_claude() { require_image; compose_exec run --rm claude "$@"; }
cmd_run()    { [[ $# -gt 0 ]] || die "run: missing command"; require_image; compose_exec run --rm box "$@"; }
cmd_doctor() { require_image; compose_exec run --rm doctor; }

# ── Unattended modes: batch and mcp ──────────────────────────────────────
# Both run a `-T` (no TTY) service whose stdout another program reads, so
# nothing here writes to stdout (lib/log.sh is stderr-only) and the winpty
# shim is never used.

# resolve_mount DIR WHOLE: decide what the box sees and where it starts.
#   WHOLE=0  bind only DIR (compose.scoped.yaml, via AGENT_BOX_MOUNT_SRC/_DST)
#   WHOLE=1  bind the whole workspace as usual; DIR must be inside it
# Either way DIR lands where an interactive session would see it
# (/work/<path relative to the workspace>), so Claude Code's per-project
# state in the home volume is shared with interactive use. A DIR outside
# the workspace lands at /work/<basename>. Exports AGENT_BOX_REPO_DIR, the
# in-box working dir (compose.yaml's working_dir).
resolve_mount() {
  local dir="$1" whole="$2" abs ws dst
  abs="$(abs_path "$dir")"
  [[ -n "$abs" ]] || die "--dir $dir is not a directory" 64
  ws="$(abs_path "$AGENT_BOX_WORKSPACE_HOST")"
  if [[ -n "$ws" && "$abs" == "$ws" ]]; then
    dst=/work
  elif [[ -n "$ws" && "$abs" == "$ws"/* ]]; then
    dst="/work/${abs#"$ws"/}"
  elif [[ "$whole" == 1 ]]; then
    die "--workspace: $abs is not inside AGENT_BOX_WORKSPACE ($AGENT_BOX_WORKSPACE_HOST)" 64
  else
    dst="/work/$(basename "$abs")"
  fi
  [[ "$dst" != *:* ]] || die "cannot mount $abs: a ':' in the path breaks the volume syntax" 64
  if [[ "$whole" == 0 ]]; then
    # An unattended agent gets a project, not a machine.
    case "$abs" in /|/[A-Za-z]) die "refusing to mount a filesystem root ($abs); point --dir at a project" 64 ;; esac
    [[ "$abs" != "$(abs_path "$HOME")" ]] || die "refusing to mount your whole home directory; point --dir at a project" 64
    AGENT_BOX_MOUNT_SRC="$(host_to_docker_path "$abs")"
    export AGENT_BOX_MOUNT_SRC AGENT_BOX_MOUNT_DST="$dst"
  fi
  export AGENT_BOX_REPO_DIR="$dst"
}

# run_oneoff NAME <compose args...>: run a named one-off container and make
# sure it is gone afterwards, however this script ends (Ctrl-C, the MCP
# client killing us). compose runs in the background so the traps can fire
# while it runs (bash defers traps until a foreground child exits), and
# `0<&0` keeps stdin attached, since an async command otherwise gets /dev/null.
run_oneoff() {
  local name="$1"; shift
  local pid rc=0
  # shellcheck disable=SC2064  # expand $name now, not when the trap fires
  trap "dockr rm -f '$name' >/dev/null 2>&1 || true" EXIT
  trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
  compose "$@" 0<&0 &
  pid=$!
  wait "$pid" || rc=$?
  trap - EXIT INT TERM HUP    # ended on its own; `run --rm` already removed it
  return "$rc"
}

oneoff_name() { printf 'agent-box-%s-%s-%s' "$1" "$$" "$RANDOM"; }

# scope WHOLE DIR: sets the caller's `overlay` array and the mount env.
scope() {
  local whole="$1" dir="$2"
  if [[ "$whole" == 1 ]]; then
    [[ -d "$AGENT_BOX_WORKSPACE_HOST" ]] || die "workspace $AGENT_BOX_WORKSPACE_HOST does not exist"
    overlay=()
  else
    overlay=(--scoped)
  fi
  resolve_mount "$dir" "$whole"
}

cmd_batch() {
  local dir="$PWD" whole=0 prompt_file="" output=text
  local timeout="$AGENT_BOX_BATCH_TIMEOUT" max_turns="$AGENT_BOX_BATCH_MAX_TURNS" mode="$AGENT_BOX_BATCH_PERMISSION_MODE"
  local -a words=() claude_args=() runner_args=() overlay=()
  local name what
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--prompt-file|-o|--output|-t|--timeout|-m|--max-turns|--permission-mode|-C|--dir|-a|--claude-arg)
        [[ $# -ge 2 ]] || die "batch: $1 needs a value" 64 ;;
    esac
    case "$1" in
      -f|--prompt-file)   prompt_file="$2"; shift 2 ;;
      -o|--output)        output="$2"; shift 2 ;;
      -t|--timeout)       timeout="$2"; shift 2 ;;
      -m|--max-turns)     max_turns="$2"; shift 2 ;;
      --permission-mode)  mode="$2"; shift 2 ;;
      -C|--dir)           dir="$2"; shift 2 ;;
      --workspace)        whole=1; shift ;;
      -a|--claude-arg)    claude_args+=("$2"); shift 2 ;;
      --)                 shift; words+=("$@"); break ;;
      -?*)                die "batch: unknown option $1 (see '$(basename "$0") help')" 64 ;;
      *)                  words+=("$1"); shift ;;
    esac
  done

  # Checked here as well as in image/batch.sh, so a typo fails at once
  # instead of after the box has booted.
  case "$output" in text|json|stream-json) ;; *) die "batch: --output must be text, json or stream-json" 64 ;; esac
  [[ "$timeout" =~ ^[0-9]+[smhd]?$ ]] || die "batch: --timeout must look like 600, 90s, 30m or 2h (0 = none)" 64
  [[ -z "$max_turns" || "$max_turns" =~ ^[1-9][0-9]*$ ]] || die "batch: --max-turns must be a positive integer" 64

  # The prompt reaches the box on stdin (fd 4 here): never argv, so size
  # and quoting do not matter and it never shows up in `docker ps`.
  if [[ ${#words[@]} -gt 0 && -n "$prompt_file" ]]; then
    die "batch: give the prompt as words OR --prompt-file, not both" 64
  elif [[ ${#words[@]} -gt 0 ]]; then
    exec 4<<<"${words[*]}"
  elif [[ -n "$prompt_file" && "$prompt_file" != - ]]; then
    [[ -r "$prompt_file" ]] || die "batch: cannot read prompt file $prompt_file" 64
    exec 4<"$prompt_file"
  elif [[ -n "$prompt_file" || ! -t 0 ]]; then
    exec 4<&0
  else
    die "batch: no prompt (pass it as words, --prompt-file FILE, or pipe it in)" 64
  fi

  require_runtime
  scope "$whole" "$dir"
  if [[ "$whole" == 1 ]]; then what="the whole workspace"; else what="only $dir"; fi
  if [[ "$mode" == bypassPermissions ]]; then
    log_warn "bypassPermissions: every tool call is allowed, unattended. What still holds is the box:"
    log_warn "non-root, no host credentials, the egress denylist, and $what mounted read-write."
  fi

  runner_args=(--output "$output" --timeout "$timeout" --permission-mode "$mode")
  [[ -n "$max_turns" ]] && runner_args+=(--max-turns "$max_turns")
  name="$(oneoff_name batch)"
  log_info "batch $name: $what mounted, working in $AGENT_BOX_REPO_DIR, output $output"
  run_oneoff "$name" "${overlay[@]}" run --rm -i -T --name "$name" batch \
    agent-box-batch "${runner_args[@]}" -- "${claude_args[@]}" <&4
}

# mcp: Claude Code's own MCP server (`claude mcp serve`) inside the box, on
# this process's stdin/stdout. Register it on the host with this script as
# the server command; see README "MCP mode".
cmd_mcp() {
  local dir="$PWD" whole=0 name
  local -a overlay=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -C|--dir)    [[ $# -ge 2 ]] || die "mcp: $1 needs a value" 64; dir="$2"; shift 2 ;;
      --workspace) whole=1; shift ;;
      *)           die "mcp: unknown argument $1 (only --dir DIR and --workspace)" 64 ;;
    esac
  done
  require_runtime
  scope "$whole" "$dir"
  name="$(oneoff_name mcp)"
  log_info "mcp $name: serving $AGENT_BOX_REPO_DIR on stdio"
  run_oneoff "$name" "${overlay[@]}" run --rm -i -T --name "$name" mcp
}

# identity: print the box's own ed25519 key (the entrypoint creates it on
# first start, inside the volume; never a copy of a host key). Optional
# installs use HOST credentials once, so the box itself never needs them.
cmd_identity() {
  local authorize_homelab=0 github=0 pub a
  for a in "$@"; do
    case "$a" in
      --authorize-homelab) authorize_homelab=1 ;;
      --github) github=1 ;;
      *) die "identity: unknown option $a" ;;
    esac
  done
  require_image
  pub="$(compose run --rm -T box cat /home/agent/.ssh/id_ed25519.pub | tr -d '\r')"
  [[ "$pub" == ssh-ed25519* ]] || die "identity: no public key produced (entrypoint failed?)"
  printf '%s\n' "$pub"
  log_info "that is the box's public key (kept in volume $AGENT_BOX_VOLUME)"

  if [[ "$authorize_homelab" == 1 ]]; then
    log_info "authorizing on homelab via the host's ssh (homelab-ts)"
    # $pub is expanded here on purpose: the remote side receives the literal key.
    # shellcheck disable=SC2029
    if ssh homelab-ts "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && { grep -qF '$pub' ~/.ssh/authorized_keys || echo '$pub' >> ~/.ssh/authorized_keys; }"; then
      log_info "homelab: authorized"
    else
      die "homelab: failed to append the key"
    fi
  fi
  if [[ "$github" == 1 ]]; then
    command -v gh >/dev/null 2>&1 || die "--github needs gh on the host"
    if printf '%s\n' "$pub" | gh ssh-key add - --title "agent-box $(hostname)"; then
      log_info "github: key added"
    else
      die "github: gh ssh-key add failed"
    fi
  fi
  log_info "Gitea: add the key in its web UI under user settings > SSH keys (no CLI path for that yet)"
}

# kubeconfig: a ServiceAccount + long-lived token that only the box holds.
# Revoke with: kubectl -n kube-system delete sa agent-box (and the binding).
cmd_kubeconfig() {
  require_image
  command -v kubectl >/dev/null 2>&1 || die "kubeconfig needs kubectl on the host (context '$AGENT_BOX_KUBE_CONTEXT')"
  local ctx="$AGENT_BOX_KUBE_CONTEXT" sa=agent-box ns=kube-system
  local server ca token cfg
  log_info "minting ServiceAccount $ns/$sa with cluster-admin via host context $ctx"
  kubectl --context "$ctx" -n "$ns" get sa "$sa" >/dev/null 2>&1 \
    || kubectl --context "$ctx" -n "$ns" create sa "$sa" >/dev/null
  kubectl --context "$ctx" get clusterrolebinding "$sa-admin" >/dev/null 2>&1 \
    || kubectl --context "$ctx" create clusterrolebinding "$sa-admin" --clusterrole=cluster-admin --serviceaccount="$ns:$sa" >/dev/null
  kubectl --context "$ctx" -n "$ns" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $sa-token
  namespace: $ns
  annotations:
    kubernetes.io/service-account.name: $sa
type: kubernetes.io/service-account-token
EOF
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    token="$(kubectl --context "$ctx" -n "$ns" get secret "$sa-token" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    [[ -n "$token" ]] && break
    sleep 1
  done
  [[ -n "$token" ]] || die "token was not populated on secret $sa-token"
  server="$(kubectl --context "$ctx" config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
  ca="$(kubectl --context "$ctx" config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
  [[ -n "$server" && -n "$ca" ]] || die "could not read server/CA from host context $ctx"
  cfg="$(cat <<EOF
apiVersion: v1
kind: Config
clusters:
- name: homelab
  cluster:
    server: $server
    certificate-authority-data: $ca
users:
- name: $sa
  user:
    token: $token
contexts:
- name: homelab
  context:
    cluster: homelab
    user: $sa
current-context: homelab
EOF
)"
  printf '%s\n' "$cfg" | compose --open run --rm -T box \
    bash -c 'mkdir -p ~/.kube && cat > ~/.kube/config && chmod 600 ~/.kube/config && echo written'
  log_info "kubeconfig stored in volume $AGENT_BOX_VOLUME; revoke with: kubectl -n $ns delete sa $sa; kubectl delete clusterrolebinding $sa-admin"
}

cmd_compose() { docker_require; compose_exec "$@"; }

cmd_config() {
  print_config
  printf '\n# rendered compose config (base + override if present):\n'
  docker_require
  compose config
}

main() {
  local cmd="${1:-help}"; shift || true
  case "$cmd" in
    build)      cmd_build "$@" ;;
    shell)      cmd_shell ;;
    claude)     cmd_claude "$@" ;;
    run)        cmd_run "$@" ;;
    doctor)     cmd_doctor ;;
    batch)      cmd_batch "$@" ;;
    mcp)        cmd_mcp "$@" ;;
    identity)   cmd_identity "$@" ;;
    kubeconfig) cmd_kubeconfig ;;
    compose)    cmd_compose "$@" ;;
    config)     cmd_config ;;
    help|-h|--help) usage ;;
    *) log_error "unknown command: $cmd"; usage; exit 64 ;;
  esac
}

main "$@"
