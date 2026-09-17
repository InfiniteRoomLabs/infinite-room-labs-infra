#!/usr/bin/env bash
# docker/agent-box/agent-box.sh
# Host-side wrapper for the agent box: a Linux container running Claude Code
# plus the whole homelab toolchain as a non-root user, with its own identity
# and a default-deny egress firewall. See README.md next to this file.
#
# Usage:
#   agent-box.sh build [--no-cache]        build the image (pins: image/Dockerfile ARGs + mise.toml)
#   agent-box.sh shell                     interactive bash in the box
#   agent-box.sh claude [args...]          run Claude Code in the box
#   agent-box.sh run <cmd> [args...]       run one command in the box
#   agent-box.sh doctor                    check tools, logins, reach, firewall
#   agent-box.sh identity [--authorize-homelab] [--github]
#                                          create the box's SSH key; optionally install it
#   agent-box.sh kubeconfig                mint a box-only kubeconfig from a k3s ServiceAccount
#   agent-box.sh config                    show effective configuration and sources
#   agent-box.sh help
#
# Configuration (env > ~/.config/agent-box/env > default): see lib/config.sh.
# Runs from bash on Linux/macOS and from Git Bash on Windows; needs only
# docker (plus kubectl on the host for `kubeconfig`, ssh/gh for `identity`
# installs). Deliberately does not depend on mise/usage so it works on a
# fresh host before any of that exists.
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
# shellcheck source=lib/mounts.sh
source "$SCRIPT_DIR/lib/mounts.sh"

AGENT_BOX_REPO="$(repo_root_from "$SCRIPT_DIR")" || die "not inside a git checkout"
load_config

usage() { sed -n '/^# Usage:/,/^# Configuration/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; }

# run_in_box [interactive=1] -- <cmd...> : the one place `docker run` is built.
run_in_box() {
  local interactive="$1"; shift
  local args=() tty
  box_run_args args "$interactive"
  tty="$(docker_tty_prefix)"
  export MSYS_NO_PATHCONV=1   # process is replaced by exec below; see lib/docker.sh
  # shellcheck disable=SC2086  # $tty is empty or the single word "winpty"
  exec $tty docker run "${args[@]}" "$AGENT_BOX_IMAGE" "$@"
}

# Same as run_in_box but captures output for the caller instead of exec-ing.
run_in_box_capture() {
  local args=()
  box_run_args args 0
  dockr run "${args[@]}" "$AGENT_BOX_IMAGE" "$@"
}

cmd_build() {
  local extra=()
  [[ "${1:-}" == "--no-cache" ]] && extra+=(--no-cache)
  docker_require
  log_info "building $AGENT_BOX_IMAGE (context: image/, repo context: $AGENT_BOX_REPO)"
  dockr build "${extra[@]}" \
    -f "$(host_to_docker_path "$SCRIPT_DIR/image/Dockerfile")" \
    --build-context "repo=$(host_to_docker_path "$AGENT_BOX_REPO")" \
    -t "$AGENT_BOX_IMAGE" \
    "$(host_to_docker_path "$SCRIPT_DIR/image")"
  log_info "built $AGENT_BOX_IMAGE"
}

require_image() {
  docker_require
  image_exists "$AGENT_BOX_IMAGE" || die "image $AGENT_BOX_IMAGE not built yet: run '$(basename "$0") build'"
  volume_ensure "$AGENT_BOX_VOLUME"
  [[ -d "$AGENT_BOX_WORKSPACE" ]] || die "workspace $AGENT_BOX_WORKSPACE does not exist"
}

cmd_shell()  { require_image; run_in_box 1 bash; }
cmd_claude() { require_image; run_in_box 1 claude "$@"; }
cmd_run()    { [[ $# -gt 0 ]] || die "run: missing command"; require_image; run_in_box 1 "$@"; }
cmd_doctor() { require_image; run_in_box 1 agent-box-doctor; }

# identity: print the box's own ed25519 key (the entrypoint creates it on
# first start, inside the volume; never a copy of a host key). Optional
# installs use HOST credentials once, so the box itself never needs them.
cmd_identity() {
  local authorize_homelab=0 github=0 pub
  for a in "$@"; do
    case "$a" in
      --authorize-homelab) authorize_homelab=1 ;;
      --github) github=1 ;;
      *) die "identity: unknown option $a" ;;
    esac
  done
  require_image
  pub="$(run_in_box_capture cat /home/agent/.ssh/id_ed25519.pub)"
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
  log_info "Gitea: paste the key at https://git.lab.infiniteroomlabs.cloud/user/settings/keys (no CLI path for that yet)"
}

# kubeconfig: a ServiceAccount + long-lived token that only the box holds.
# Revoke with: kubectl -n kube-system delete sa agent-box (and the binding).
cmd_kubeconfig() {
  require_image
  command -v kubectl >/dev/null 2>&1 || die "kubeconfig needs kubectl on the host (context 'homelab')"
  local ctx="${AGENT_BOX_KUBE_CONTEXT:-homelab}" sa=agent-box ns=kube-system
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
  local args=()
  box_run_args args 0
  printf '%s\n' "$cfg" | dockr run -i "${args[@]}" -e AGENT_BOX_FIREWALL=0 "$AGENT_BOX_IMAGE" \
    bash -c 'mkdir -p ~/.kube && cat > ~/.kube/config && chmod 600 ~/.kube/config && echo written'
  log_info "kubeconfig stored in volume $AGENT_BOX_VOLUME; revoke with: kubectl -n $ns delete sa $sa; kubectl delete clusterrolebinding $sa-admin"
}

cmd_config() { print_config; }

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
    config)     cmd_config ;;
    help|-h|--help) usage ;;
    *) log_error "unknown command: $cmd"; usage; exit 64 ;;
  esac
}

main "$@"
