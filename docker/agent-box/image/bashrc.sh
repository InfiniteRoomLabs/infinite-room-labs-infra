# docker/agent-box/image/bashrc.sh
# Sourced by every interactive bash inside the box (via /etc/bash.bashrc).
# Keeps the shell honest about where it is and wires mise for the cwd.
# shellcheck shell=bash

# mise: activate so per-directory mise.toml pins apply as you cd around.
if command -v mise >/dev/null 2>&1; then
  eval "$(mise activate bash)"
fi

# Prompt: make it obvious this is the box, and which repo we are in.
PS1='\[\e[1;35m\][agent-box]\[\e[0m\] \[\e[1;34m\]\w\[\e[0m\]\$ '

# History across containers lives in the home volume.
export HISTFILE="$HOME/.bash_history" HISTSIZE=50000 HISTFILESIZE=50000
shopt -s histappend

# Where the repo's own tooling expects to be run from.
alias infra='cd /work/infinite-room-labs-infra'
alias doctor='agent-box-doctor'

# ── Bitwarden session, the repo's way ──────────────────────────────────
# The repo's scripts (scripts/includes/bw-session.sh, vault-pass.sh, fnox)
# read the session key from ~/.bw_session: the raw key, owner-only, mode
# 600. This mirrors the laptop's fish `bw-unlock` function so the same
# muscle memory works in the box. The box's bw login is its own (the CLI's
# data dir lives in the home volume); a host session key does not carry.
#
#   bw login              once per volume
#   bw-unlock             each time the vault is locked; writes the cache
#   bw-lock               lock and drop the cache
if [[ -r "$HOME/.bw_session" && -s "$HOME/.bw_session" ]]; then
  BW_SESSION="$(<"$HOME/.bw_session")"
  export BW_SESSION
fi

bw-unlock() {
  local key
  key="$(bw unlock --raw)" || { echo "bw-unlock: unlock failed" >&2; return 1; }
  (umask 077 && printf '%s' "$key" >"$HOME/.bw_session")
  chmod 600 "$HOME/.bw_session"
  export BW_SESSION="$key"
  bw status 2>/dev/null | grep -q '"status": *"unlocked"' && echo "bw-unlock: unlocked, session cached in ~/.bw_session"
}

bw-lock() {
  bw lock >/dev/null 2>&1 || true
  rm -f "$HOME/.bw_session"
  unset BW_SESSION
  echo "bw-lock: locked, cache removed"
}
