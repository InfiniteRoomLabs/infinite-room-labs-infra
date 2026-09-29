#!/usr/bin/env bash
# docker/agent-box/image/entrypoint.sh
# Container entrypoint. Runs as the non-root `agent` user on every start:
#   1. bring up the egress firewall (unless AGENT_BOX_FIREWALL=0),
#   2. make sure the home volume has the directories logins expect,
#   3. load the box's SSH identity into an agent if one exists,
#   4. make sure git has a commit identity,
#   5. exec the requested command (default: bash).
#
# It never touches the workspace and never writes secrets. Everything
# stateful lands in /home/agent, which the host wrapper mounts as a named
# volume.
set -euo pipefail

log() { printf 'agent-box: %s\n' "$*" >&2; }

# stdout belongs to the command we exec, never to this setup. In MCP mode
# (`claude mcp serve`) it is the protocol channel and in batch mode it is
# the agent's result, so one stray line from a tool below would corrupt
# it. Park the real stdout on fd 3 and point fd 1 at stderr until the exec.
exec 3>&1 1>&2

# 1. Firewall (denylist: default allow, listed destinations blocked). A
#    misconfigured run (no NET_ADMIN cap) fails loudly rather than silently
#    skipping the blocks.
if [[ "${AGENT_BOX_FIREWALL:-1}" == "1" ]]; then
  if ! sudo -n /usr/local/bin/init-firewall.sh; then
    log "firewall setup failed. Either run the box with --cap-add NET_ADMIN --cap-add NET_RAW"
    log "(the host wrapper does this) or start it with AGENT_BOX_FIREWALL=0 to skip the denylist."
    exit 1
  fi
else
  log "firewall disabled (AGENT_BOX_FIREWALL=0); denylist not applied"
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
  # GitHub over SSH with the box's key (private org repos, e.g. ccsm).
  cat <<'EOF'
Host github.com
  User git
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
EOF
} >"$HOME/.ssh/config"
chmod 600 "$HOME/.ssh/config"

# Volume-scoped tools (agent-box-extras installs into ~/.local) must be on
# PATH for everything, including Claude Code's hooks, not only interactive
# shells. So export it here, before the exec.
export PATH="$HOME/.local/bin:$PATH"
# The daemon must not inherit fd 3 (the real stdout) and hold it open.
eval "$(ssh-agent -s 3>&-)" >/dev/null
ssh-add -q "$HOME/.ssh/id_ed25519" 2>/dev/null || log "could not load ~/.ssh/id_ed25519 into ssh-agent"

# 4. Git identity, reconciled on every start, so an existing volume picks it
#    up on its next start after an upgrade with nothing to run by hand.
#    Precedence per field:
#      AGENT_BOX_GIT_NAME/EMAIL (the wrapper defaults them to the host's own
#        git identity, so the box commits as whoever runs it)
#      > whatever the volume's ~/.gitconfig already has
#      > the GitHub account `gh` is logged in as (noreply address)
#      > unset, with one line saying how to fix it.
#    Writes only when a value changes, so a normal start stays quiet.
set_git_identity() { # key value source
  [[ -n "$2" && "$(git config --global --get "$1" || true)" != "$2" ]] || return 0
  git config --global "$1" "$2"
  log "git $1 set from $3"
}
set_git_identity user.name "${AGENT_BOX_GIT_NAME:-}" AGENT_BOX_GIT_NAME
set_git_identity user.email "${AGENT_BOX_GIT_EMAIL:-}" AGENT_BOX_GIT_EMAIL
if ! git config --global --get user.name >/dev/null || ! git config --global --get user.email >/dev/null; then
  if gh_user=$(timeout 5 gh api user --jq '[.id, .login, (.name // "")] | @tsv' 2>/dev/null); then
    IFS=$'\t' read -r gh_id gh_login gh_name <<<"$gh_user"
    git config --global --get user.name >/dev/null || set_git_identity user.name "${gh_name:-$gh_login}" "the gh login"
    git config --global --get user.email >/dev/null ||
      set_git_identity user.email "${gh_id}+${gh_login}@users.noreply.github.com" "the gh login (GitHub noreply)"
  fi
fi
git config --global --get user.email >/dev/null ||
  log "no git identity: set AGENT_BOX_GIT_NAME/AGENT_BOX_GIT_EMAIL or run 'gh auth login' in the box"

# 5. Hand off. `exec` so signals reach the real process; restore stdout
#    (and close the spare fd) on the way.
exec "$@" 1>&3 3>&-
