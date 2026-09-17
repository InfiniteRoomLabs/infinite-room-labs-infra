#!/usr/bin/env bash
# docker/agent-box/image/entrypoint.sh
# Container entrypoint. Runs as the non-root `agent` user on every start:
#   1. bring up the egress firewall (unless AGENT_BOX_FIREWALL=0),
#   2. make sure the home volume has the directories logins expect,
#   3. load the box's SSH identity into an agent if one exists,
#   4. exec the requested command (default: bash).
#
# It never touches the workspace and never writes secrets. Everything
# stateful lands in /home/agent, which the host wrapper mounts as a named
# volume.
set -euo pipefail

log() { printf 'agent-box: %s\n' "$*" >&2; }

# 1. Firewall. Default-deny is the whole point of running unattended, so a
#    misconfigured run (no NET_ADMIN cap) fails loudly instead of running open.
if [[ "${AGENT_BOX_FIREWALL:-1}" == "1" ]]; then
  if ! sudo -n /usr/local/bin/init-firewall.sh; then
    log "firewall setup failed. Either run the box with --cap-add NET_ADMIN --cap-add NET_RAW"
    log "(the host wrapper does this) or start it with AGENT_BOX_FIREWALL=0 to run open."
    exit 1
  fi
else
  log "firewall disabled (AGENT_BOX_FIREWALL=0); egress is unrestricted"
fi

# 2. Home skeleton. Idempotent; the volume persists across containers.
mkdir -p "$HOME/.ssh" "$HOME/.kube" "$HOME/.config" "$HOME/.claude"
chmod 700 "$HOME/.ssh"
# Seed the starship config once; afterwards the volume copy is yours to edit.
if [[ ! -f "$HOME/.config/starship.toml" && -f /etc/agent-box/starship.toml ]]; then
  cp /etc/agent-box/starship.toml "$HOME/.config/starship.toml"
fi

# 3. SSH identity. The box always has its own key (never a copy of a host
#    key). Created once, on first start; `agent-box.sh identity` prints it
#    and can install it on the homelab/GitHub. The repo's mise.toml also
#    reads the .pub at shell startup, so it must exist before any prompt.
if [[ ! -f "$HOME/.ssh/id_ed25519" ]]; then
  ssh-keygen -q -t ed25519 -N "" -C "agent-box-$(date +%Y%m%d)" -f "$HOME/.ssh/id_ed25519"
  log "created the box's SSH identity: $(cut -d' ' -f1-2 "$HOME/.ssh/id_ed25519.pub" | cut -c1-40)..."
fi
# ~/.ssh/config is regenerated from the AGENT_BOX_* env the wrapper passes
# in (derived from the repo's inventory), so no host detail is baked into
# the image. Empty values skip the block.
{
  if [[ -n "${AGENT_BOX_SSH_USER:-}" && -n "${AGENT_BOX_SSH_HOST:-}" ]]; then
    cat <<EOF
Host homelab-ts
  HostName ${AGENT_BOX_SSH_HOST}
  User ${AGENT_BOX_SSH_USER}
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
EOF
  fi
  if [[ -n "${AGENT_BOX_GIT_HOST:-}" ]]; then
    cat <<EOF
Host ${AGENT_BOX_GIT_HOST}
  Port ${AGENT_BOX_GIT_SSH_PORT:-22}
  User git
  IdentityFile ~/.ssh/id_ed25519
  StrictHostKeyChecking accept-new
EOF
  fi
} >"$HOME/.ssh/config"
chmod 600 "$HOME/.ssh/config"
eval "$(ssh-agent -s)" >/dev/null
ssh-add -q "$HOME/.ssh/id_ed25519" 2>/dev/null || log "could not load ~/.ssh/id_ed25519 into ssh-agent"

# 4. Hand off. `exec` so signals reach the real process.
exec "$@"
