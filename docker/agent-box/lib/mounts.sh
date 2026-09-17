#!/usr/bin/env bash
# docker/agent-box/lib/mounts.sh
# Assembles the `docker run` argument list. Source it; do not execute it.
#
# There are exactly two mounts, on purpose (see README "Boundary"):
#   named volume  AGENT_BOX_VOLUME     -> /home/agent   (state: logins, keys)
#   bind          AGENT_BOX_WORKSPACE  -> /work         (your repos, rw)
# No host ~/.ssh, ~/.kube, or credential files are ever mounted.
#
#   box_run_args ARRAY_NAME [interactive]
#     fills ARRAY_NAME with everything between `docker run` and the image.
# shellcheck shell=bash

box_run_args() {
  local -n _out="$1"
  local interactive="${2:-1}"
  local ws
  ws="$(host_to_docker_path "$AGENT_BOX_WORKSPACE")"

  _out=(
    --rm
    --init
    --hostname agent-box
    -v "${AGENT_BOX_VOLUME}:/home/agent"
    -v "${ws}:/work"
    -e "AGENT_BOX_FIREWALL=${AGENT_BOX_FIREWALL}"
    -e "TZ=${AGENT_BOX_TZ}"
    -e "AGENT_BOX_SSH_USER=${AGENT_BOX_SSH_USER}"
    -e "AGENT_BOX_SSH_HOST=${AGENT_BOX_SSH_HOST}"
    -e "AGENT_BOX_GIT_HOST=${AGENT_BOX_GIT_HOST}"
    -e "AGENT_BOX_GIT_SSH_PORT=${AGENT_BOX_GIT_SSH_PORT}"
  )

  # Land in the infra repo when it is inside the workspace, else in /work.
  local repo_abs ws_abs repo_dir
  repo_abs="$(abs_path "$AGENT_BOX_REPO")"
  ws_abs="$(abs_path "$AGENT_BOX_WORKSPACE")"
  if [[ -n "$repo_abs" && -n "$ws_abs" && "$repo_abs" == "$ws_abs"/* ]]; then
    repo_dir="/work/${repo_abs#"$ws_abs"/}"
    _out+=(--workdir "$repo_dir" -e "AGENT_BOX_REPO_DIR=$repo_dir")
  else
    _out+=(--workdir /work)
  fi

  # The in-container firewall needs these two capabilities and nothing else.
  if [[ "$AGENT_BOX_FIREWALL" == "1" ]]; then
    _out+=(--cap-add NET_ADMIN --cap-add NET_RAW)
  fi

  if [[ "$interactive" == "1" && -t 0 && -t 1 ]]; then
    _out+=(-it)
  elif [[ "$interactive" == "1" ]]; then
    _out+=(-i)
  fi
}
