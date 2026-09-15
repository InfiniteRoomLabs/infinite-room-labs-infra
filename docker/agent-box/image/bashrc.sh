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
