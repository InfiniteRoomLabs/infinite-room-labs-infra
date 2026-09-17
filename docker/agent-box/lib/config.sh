#!/usr/bin/env bash
# docker/agent-box/lib/config.sh
# Configuration with 12-factor precedence. Source it; do not execute it.
#
#   environment variable    (highest; set it on the command line)
#   ~/.config/agent-box/env (a sourced bash file of KEY=value lines)
#   built-in default        (lowest)
#
# Every knob is declared once in AGENT_BOX_KNOBS as "NAME|default|description"
# so the precedence loop and `agent-box.sh config` stay in sync. Defaults are
# evaluated with `eval`, so they may reference other variables or run a
# command substitution; they must not contain a literal pipe character.
#
# The knobs are exported, and compose.yaml interpolates the same names, so
# this file is the single place precedence is decided for both the wrapper
# and compose. (Direct `docker compose` use reads .env instead; see
# .env.example.)
#
# Requires AGENT_BOX_REPO (the repo root) to be set before load_config, and
# lib/paths.sh to be sourced (abs_path, host_to_docker_path).
# shellcheck shell=bash

AGENT_BOX_KNOBS=(
  "AGENT_BOX_IMAGE|irl-agent-box:local|image tag to build and run"
  "AGENT_BOX_VOLUME|irl-agent-box-home|named volume mounted at /home/agent"
  "AGENT_BOX_WORKSPACE|\$HOME/Projects|host directory mounted at /work"
  "AGENT_BOX_FIREWALL|1|1 = apply the egress denylist from image/denylist.txt, 0 = no firewall"
  "AGENT_BOX_TZ|\${TZ:-America/New_York}|timezone inside the box"
  "AGENT_BOX_KUBE_CONTEXT|homelab|host kubectl context used by 'kubeconfig'"
  # SSH target for the box's ~/.ssh/config. Defaults are read from files the
  # repo already tracks (inventory + mise.toml) so no host detail is
  # duplicated in this directory; override them in the config file.
  "AGENT_BOX_SSH_USER|\$(sed -n '/^ansible_user=/{s/^ansible_user=//p;q}' \"\$AGENT_BOX_REPO/ansible/inventory/hosts.ini\" 2>/dev/null)|ssh user for homelab-ts inside the box"
  "AGENT_BOX_SSH_HOST|\$(sed -n '/^HOMELAB_TAILSCALE_IP/{s/.*\"\\(.*\\)\".*/\\1/p;q}' \"\$AGENT_BOX_REPO/mise.toml\" 2>/dev/null)|ssh host for homelab-ts inside the box"
  "AGENT_BOX_GIT_HOST||optional Gitea SSH hostname for the box's ssh config (empty = skip)"
  "AGENT_BOX_GIT_SSH_PORT|30022|SSH port for AGENT_BOX_GIT_HOST"
  "AGENT_BOX_CONFIG_FILE|\${XDG_CONFIG_HOME:-\$HOME/.config}/agent-box/env|config file (env-or-default only)"
)

# _knob_fields "entry" -> sets _k_name _k_default _k_desc
_knob_fields() {
  _k_name="${1%%|*}"
  local rest="${1#*|}"
  _k_default="${rest%%|*}"
  _k_desc="${rest#*|}"
}

# load_config: apply precedence for every knob, then compute the derived
# values compose needs. Safe to call once.
load_config() {
  local entry preset=() saved=() n cfg

  # 1. Knobs already in the environment win over everything.
  for entry in "${AGENT_BOX_KNOBS[@]}"; do
    [[ "$entry" == \#* || -z "$entry" ]] && continue
    _knob_fields "$entry"
    [[ -v "$_k_name" ]] && preset+=("$_k_name")
  done

  # 2. The config file fills in what the environment did not set.
  if [[ -v AGENT_BOX_CONFIG_FILE ]]; then
    cfg="$AGENT_BOX_CONFIG_FILE"
  else
    cfg="${XDG_CONFIG_HOME:-$HOME/.config}/agent-box/env"
  fi
  if [[ -f "$cfg" ]]; then
    for n in "${preset[@]}"; do saved+=("$n=${!n}"); done
    # shellcheck disable=SC1090
    source "$cfg"
    for n in "${saved[@]}"; do export "${n?}"; done
  fi

  # 3. Defaults for anything still unset.
  for entry in "${AGENT_BOX_KNOBS[@]}"; do
    [[ "$entry" == \#* || -z "$entry" ]] && continue
    _knob_fields "$entry"
    if [[ -v "$_k_name" ]]; then
      export "${_k_name?}"
    else
      eval "export $_k_name=\"$_k_default\""
    fi
  done

  # 4. Derived: where the infra repo lands inside the box. /work/<relative
  #    path> when the repo is under the workspace, else just /work.
  local repo_abs ws_abs
  repo_abs="$(abs_path "$AGENT_BOX_REPO")"
  ws_abs="$(abs_path "$AGENT_BOX_WORKSPACE")"
  if [[ -n "$repo_abs" && -n "$ws_abs" && "$repo_abs" == "$ws_abs"/* ]]; then
    export AGENT_BOX_REPO_DIR="/work/${repo_abs#"$ws_abs"/}"
  else
    export AGENT_BOX_REPO_DIR="/work"
  fi
  # Keep the shell-form path for host-side checks; compose gets the
  # docker-form one (Windows style under Git Bash) via export_derived_for_compose.
  export AGENT_BOX_WORKSPACE_HOST="$AGENT_BOX_WORKSPACE"
}

# export_derived_for_compose: last step before any `docker compose` call.
# Compose interpolates the knob names directly; the only translation is the
# workspace path, which Docker Desktop on Windows wants in Windows form.
export_derived_for_compose() {
  AGENT_BOX_WORKSPACE="$(host_to_docker_path "$AGENT_BOX_WORKSPACE_HOST")"
  export AGENT_BOX_WORKSPACE
}

# print_config: every knob, its effective value, and its description.
print_config() {
  local entry
  for entry in "${AGENT_BOX_KNOBS[@]}"; do
    [[ "$entry" == \#* || -z "$entry" ]] && continue
    _knob_fields "$entry"
    printf '%-24s %-36s %s\n' "$_k_name" "${!_k_name}" "$_k_desc"
  done
  printf '%-24s %-36s %s\n' "AGENT_BOX_REPO_DIR" "$AGENT_BOX_REPO_DIR" "(derived) working dir inside the box"
}
