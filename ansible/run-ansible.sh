#!/usr/bin/env bash
set -euo pipefail

# ansible/run-ansible.sh
# Wrapper that runs Ansible inside a Docker container so the operator's
# workstation never needs a local Ansible install.
#
# Usage:
#   ./ansible/run-ansible.sh playbook site.yml [EXTRA ANSIBLE ARGS ...]
#   ./ansible/run-ansible.sh galaxy install
#   ./ansible/run-ansible.sh vault edit inventory/group_vars/all/vault.yml
#   ./ansible/run-ansible.sh helm list -n irl
#   ./ansible/run-ansible.sh kubectl get pods -n irl
#   ./ansible/run-ansible.sh shell
#
# Environment:
#   ANSIBLE_VAULT_PASSWORD_FILE  Path to vault password file (optional)
#   SSH_KEY                      Path to SSH private key (default: ~/.ssh/id_ed25519)
#   KUBECONFIG                   Path to kubeconfig (default: ~/.kube/homelab.yaml)

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
  -it
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
