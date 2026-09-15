#!/usr/bin/env bash
# docker/agent-box/lib/docker.sh
# Thin helpers over the docker CLI. Source it; do not execute it.
#
#   dockr ...                 -> `docker ...` with MSYS path conversion off
#   docker_require            -> die unless the daemon answers
#   image_exists "tag"        -> 0/1
#   volume_ensure "name"      -> create the named volume if missing
#   docker_tty_prefix         -> prints "winpty" when Git Bash needs it for -it
# shellcheck shell=bash

# Every docker call goes through here so Git Bash never rewrites container
# paths like /work or /home/agent in the arguments. Harmless elsewhere.
dockr() { MSYS_NO_PATHCONV=1 docker "$@"; }

docker_require() {
  command -v docker >/dev/null 2>&1 || die "docker CLI not found on PATH"
  dockr version --format '{{.Server.Version}}' >/dev/null 2>&1 \
    || die "docker daemon is not reachable (is Docker Desktop running?)"
}

image_exists() { dockr image inspect "$1" >/dev/null 2>&1; }

volume_ensure() {
  if ! dockr volume inspect "$1" >/dev/null 2>&1; then
    log_info "creating volume $1 (holds /home/agent: logins, keys, caches)"
    dockr volume create "$1" >/dev/null
  fi
}

# Git Bash's mintty is not a Windows console, so `docker run -it` needs the
# winpty shim to get a real TTY. Only relevant for interactive use; the
# Claude Code Bash tool and CI never have a TTY and skip this.
docker_tty_prefix() {
  if is_msys && [[ -t 0 && -t 1 ]] && command -v winpty >/dev/null 2>&1; then
    printf 'winpty'
  fi
}
