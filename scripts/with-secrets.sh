#!/usr/bin/env bash
set -euo pipefail

# scripts/with-secrets.sh
# Runs a command with this repo's secrets injected as environment variables,
# sourced from fnox (Bitwarden-backed). Secrets exist only in the child
# process -- they never touch the ambient/interactive shell. There is no
# .envrc; this wrapper is the single entry point for secret-bearing commands.
#
# Usage:
#   ./scripts/with-secrets.sh terragrunt plan
#   ./scripts/with-secrets.sh ./scripts/bootstrap.sh --plan
#
# The fnox `bitwarden` provider needs a valid BW_SESSION; the shared resolver
# validates env/cache candidates and exports one (see includes/bw-session.sh).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=includes/bw-session.sh
source "$SCRIPT_DIR/includes/bw-session.sh"
resolve_bw_session || exit 1

if [[ $# -eq 0 ]]; then
  echo "usage: $(basename "$0") <command> [args...]" >&2
  exit 64
fi

exec fnox exec -- "$@"
