#!/usr/bin/env -S usage bash
set -euo pipefail

#USAGE cmd "playbook" help="Run ansible-playbook" { arg "<args>..." help="ansible-playbook args" }
#USAGE cmd "galaxy" help="Run ansible-galaxy" { arg "<args>..." help="ansible-galaxy args" }
#USAGE cmd "vault" help="Run ansible-vault" { arg "<args>..." help="ansible-vault args" }
#USAGE cmd "helm" help="Run helm" { arg "<args>..." help="helm args" }
#USAGE cmd "kubectl" help="Run kubectl" { arg "<args>..." help="kubectl args" }
#USAGE cmd "shell" help="Open an interactive bash shell in the runner container"

# ansible/run-ansible.sh
# Wrapper that runs Ansible inside a Docker container so the operator's
# workstation never needs a local Ansible install. (Legacy path -- the
# preferred local path is `cd ansible/ && uv run ansible-playbook ...`, which
# reads the vault password via scripts/vault-pass.sh.)
#
# Subcommands/args are parsed by the `usage` spec above (auto --help). The vault
# password is resolved on the HOST via fnox into a temp file and mounted, since
# fnox is not present inside the container. Run via `mise run ansible -- ...` or
# `./scripts/with-secrets.sh ./ansible/run-ansible.sh ...` so BW_SESSION exists.
#
# Environment:
#   ANSIBLE_VAULT_PASSWORD_FILE  Vault password file (auto-resolved via fnox if unset)
#   SSH_KEY                      SSH private key (default: ~/.ssh/id_ed25519)
#   KUBECONFIG                   kubeconfig (default: ~/.kube/homelab.yaml)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE_NAME="irl-ansible"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/homelab.yaml}"

# ── Build the image if it doesn't exist ──────────────────────────────
if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
  echo "==> Building Ansible runner image..."
  docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"
  echo ""
fi

# ── Common Docker run flags ──────────────────────────────────────────
DOCKER_ARGS=(
  --rm
  -i
)
# Only attach a pseudo-TTY when one is available (avoids "not a TTY" errors
# when run from CI, cron, or agent contexts).
if [ -t 0 ]; then
  DOCKER_ARGS+=(-t)
fi

DOCKER_ARGS+=(
  -v "$SCRIPT_DIR:/ansible:ro"
  -v "$SSH_KEY:/root/.ssh/id_ed25519:ro"
  -v "$HOME/.ssh/known_hosts:/root/.ssh/known_hosts:rw"
  -e "ANSIBLE_CONFIG=/ansible/ansible.cfg"
)

# Mount kubeconfig if it exists (needed for kubernetes.core modules and helm/kubectl commands)
if [[ -f "$KUBECONFIG_PATH" ]]; then
  DOCKER_ARGS+=(-v "$KUBECONFIG_PATH:/root/.kube/config:ro")
  DOCKER_ARGS+=(-e "KUBECONFIG=/root/.kube/config")
fi

# Resolve the vault password on the host via fnox (the container has no fnox).
# Writes a locked-down temp file, removed on exit. Mirrors the old mounted
# .vault-password. Skipped if ANSIBLE_VAULT_PASSWORD_FILE is already set.
VAULT_PASS_TMP=""
cleanup_vault_tmp() { [[ -n "$VAULT_PASS_TMP" && -f "$VAULT_PASS_TMP" ]] && rm -f "$VAULT_PASS_TMP"; }
trap cleanup_vault_tmp EXIT

if [[ -z "${ANSIBLE_VAULT_PASSWORD_FILE:-}" ]]; then
  # scripts/vault-pass.sh validates BW_SESSION candidates (inherited env can be stale).
  if _vp="$("$REPO_ROOT/scripts/vault-pass.sh" 2>/dev/null)" && [[ -n "$_vp" ]]; then
    VAULT_PASS_TMP="$(mktemp)"
    chmod 600 "$VAULT_PASS_TMP"
    printf '%s' "$_vp" > "$VAULT_PASS_TMP"
    unset _vp
    ANSIBLE_VAULT_PASSWORD_FILE="$VAULT_PASS_TMP"
  fi
fi

# Pass through vault password file if set
if [[ -n "${ANSIBLE_VAULT_PASSWORD_FILE:-}" ]]; then
  DOCKER_ARGS+=(-v "$ANSIBLE_VAULT_PASSWORD_FILE:/tmp/vault_pass:ro")
  DOCKER_ARGS+=(-e "ANSIBLE_VAULT_PASSWORD_FILE=/tmp/vault_pass")
fi

# ── Dispatch commands ────────────────────────────────────────────────
COMMAND="${1:-}"
shift || true

case "$COMMAND" in
  playbook)
    echo "==> Running ansible-playbook $*"
    docker run "${DOCKER_ARGS[@]}" \
      --entrypoint ansible-playbook \
      "$IMAGE_NAME" "$@"
    ;;
  galaxy)
    echo "==> Running ansible-galaxy $*"
    docker run "${DOCKER_ARGS[@]}" \
      --entrypoint ansible-galaxy \
      "$IMAGE_NAME" "$@"
    ;;
  vault)
    echo "==> Running ansible-vault $*"
    docker run "${DOCKER_ARGS[@]}" \
      -v "$SCRIPT_DIR:/ansible:rw" \
      --entrypoint ansible-vault \
      "$IMAGE_NAME" "$@"
    ;;
  helm)
    echo "==> Running helm $*"
    docker run "${DOCKER_ARGS[@]}" \
      --entrypoint helm \
      "$IMAGE_NAME" "$@"
    ;;
  kubectl)
    echo "==> Running kubectl $*"
    docker run "${DOCKER_ARGS[@]}" \
      --entrypoint kubectl \
      "$IMAGE_NAME" "$@"
    ;;
  shell)
    echo "==> Opening shell in Ansible runner container"
    docker run "${DOCKER_ARGS[@]}" \
      --entrypoint /bin/bash \
      "$IMAGE_NAME"
    ;;
  ""|--help|-h)
    cat <<HELP
Usage: $(basename "$0") COMMAND [ARGS...]

Commands:
  playbook PLAYBOOK [OPTS]  Run ansible-playbook
  galaxy SUBCOMMAND [OPTS]  Run ansible-galaxy (e.g., galaxy install)
  vault SUBCOMMAND [OPTS]   Run ansible-vault (e.g., vault edit FILE)
  helm SUBCOMMAND [OPTS]    Run helm (e.g., helm list -n irl)
  kubectl SUBCOMMAND [OPTS] Run kubectl (e.g., kubectl get pods -n irl)
  shell                     Open an interactive bash shell in the container

Environment:
  SSH_KEY                      SSH private key (default: ~/.ssh/id_ed25519)
  ANSIBLE_VAULT_PASSWORD_FILE  Vault password file path
  KUBECONFIG                   Kubeconfig path (default: ~/.kube/homelab.yaml)

Examples:
  $(basename "$0") playbook site.yml
  $(basename "$0") playbook playbooks/k3s.yml
  $(basename "$0") playbook playbooks/helm-deploy.yml --tags postgres
  $(basename "$0") galaxy install -r requirements.yml
  $(basename "$0") vault encrypt inventory/group_vars/all/vault.yml
  $(basename "$0") helm list -n irl
  $(basename "$0") kubectl get pods -n irl
HELP
    ;;
  *)
    echo "Unknown command: $COMMAND" >&2
    echo "Run '$(basename "$0") --help' for usage." >&2
    exit 1
    ;;
esac
