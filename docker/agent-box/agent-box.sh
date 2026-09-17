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
#   agent-box.sh doctor                    check tools, logins, reach, firewall
#   agent-box.sh identity [--authorize-homelab] [--github]
#                                          print the box's SSH key; optionally install it
#   agent-box.sh kubeconfig                mint a box-only kubeconfig from a k3s ServiceAccount
#   agent-box.sh compose [--open] [--ci] <compose args...>
#                                          docker compose with derived env + overlays applied
#   agent-box.sh config                    show effective knobs, then the rendered compose config
#   agent-box.sh help
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
    esac
  done
  local f
  for f in "${files[@]}"; do printf -- '-f\n%s\n' "$(host_to_docker_path "$f")"; done
}

# compose [--open] [--ci] <args...> -> `docker compose` with the stack and
# derived environment applied. Everything else in this script goes through it.
compose() {
  local -a overlays=() fargs=()
  while [[ "${1:-}" == --open || "${1:-}" == --ci ]]; do overlays+=("$1"); shift; done
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

require_image() {
  docker_require
  image_exists "$AGENT_BOX_IMAGE" || die "image $AGENT_BOX_IMAGE not built yet: run '$(basename "$0") build'"
  volume_ensure "$AGENT_BOX_VOLUME"   # compose.yaml declares it external
  [[ -d "$AGENT_BOX_WORKSPACE_HOST" ]] || die "workspace $AGENT_BOX_WORKSPACE_HOST does not exist"
}

cmd_shell()  { require_image; compose_exec run --rm box; }
cmd_claude() { require_image; compose_exec run --rm claude "$@"; }
cmd_run()    { [[ $# -gt 0 ]] || die "run: missing command"; require_image; compose_exec run --rm box "$@"; }
cmd_doctor() { require_image; compose_exec run --rm doctor; }

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
    identity)   cmd_identity "$@" ;;
    kubeconfig) cmd_kubeconfig ;;
    compose)    cmd_compose "$@" ;;
    config)     cmd_config ;;
    help|-h|--help) usage ;;
    *) log_error "unknown command: $cmd"; usage; exit 64 ;;
  esac
}

main "$@"
