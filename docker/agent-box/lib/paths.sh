#!/usr/bin/env bash
# docker/agent-box/lib/paths.sh
# Host path helpers. Source it; do not execute it.
#
# The wrapper runs from plain bash on Linux/macOS and from Git Bash (MSYS)
# on Windows. Docker Desktop on Windows wants Windows-style paths in -v
# arguments, and MSYS likes to rewrite anything that looks like a POSIX
# path inside arguments. These helpers hide both quirks.
#
#   is_msys                      -> true on Git Bash / MSYS2
#   host_to_docker_path "/c/x"   -> "C:\x" on MSYS, unchanged elsewhere
#   repo_root_from "$dir"        -> walks up to the git toplevel
# shellcheck shell=bash

is_msys() { [[ "$(uname -s 2>/dev/null)" == MINGW* || "$(uname -s 2>/dev/null)" == MSYS* ]]; }

host_to_docker_path() {
  local p="$1"
  if is_msys && command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$p"
  else
    printf '%s' "$p"
  fi
}

repo_root_from() {
  git -C "$1" rev-parse --show-toplevel 2>/dev/null
}

# abs_path DIR -> canonical absolute path in the shell's own notation.
# On MSYS, git prints "C:/x" while the shell sees "/c/x"; `pwd -P` after a
# `cd` normalizes both to the shell form, so comparisons work. `realpath`
# does not do this conversion, which is why it is not used here.
abs_path() {
  (cd "$1" 2>/dev/null && pwd -P)
}

# MSYS path conversion mangles "/work" style container paths in `-v a:/work`
# and `--workdir /work`, but native Windows git NEEDS the conversion for its
# own arguments. So the opt-out is applied per docker invocation (see
# `dockr` in lib/docker.sh), never exported globally.
