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
# BW_SESSION bootstrap: the fnox `bitwarden` provider needs BW_SESSION to talk
# to the vault. BW_SESSION itself is an age-backed fnox secret (decryptable
# without the vault), so we resolve it first, then hand off to `fnox exec`.
# Resolution order: existing env -> fnox age secret -> ~/.bw_session (fish
# `bw-unlock` cache, transitional).

if [[ -z "${BW_SESSION:-}" ]]; then
  BW_SESSION="$(fnox get BW_SESSION 2>/dev/null || true)"
fi
if [[ -z "${BW_SESSION:-}" && -f "$HOME/.bw_session" ]]; then
  BW_SESSION="$(cat "$HOME/.bw_session")"
fi
export BW_SESSION

if [[ $# -eq 0 ]]; then
  echo "usage: $(basename "$0") <command> [args...]" >&2
  exit 64
fi

exec fnox exec -- "$@"
