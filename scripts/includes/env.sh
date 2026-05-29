#!/usr/bin/env bash
# scripts/includes/env.sh
# Shared environment helpers for bootstrap scripts.
# Source this file -- do not execute it directly.

# Locate the repo root relative to this file.
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$_SCRIPT_DIR/../.." && pwd)"

# load_env -- secrets are injected by fnox (see scripts/with-secrets.sh), so
# there is normally nothing to source here. A legacy repo-root .env is still
# honored if present, for transition.
load_env() {
  local env_file="$REPO_ROOT/.env"
  if [[ -f "$env_file" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$env_file"
    set +a
  fi
  # Otherwise rely on the environment provided by `fnox exec` / with-secrets.sh.
}

# require_vars VAR1 VAR2 ... -- exit with an error listing any unset or empty vars.
require_vars() {
  local missing=()
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("$var")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: the following required environment variables are not set:" >&2
    for var in "${missing[@]}"; do
      echo "  - $var" >&2
    done
    echo "" >&2
    echo "These are injected by fnox -- run via 'mise run <task>' or" >&2
    echo "'./scripts/with-secrets.sh <cmd>'. Check mappings in fnox.toml." >&2
    exit 1
  fi
}
