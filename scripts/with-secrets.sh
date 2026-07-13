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

# A candidate is only trusted if bw accepts it -- an inherited env BW_SESSION
# can be stale (e.g. a long-lived agent shell started before a re-unlock).
session_ok() { [[ -n "$1" ]] && BW_SESSION="$1" bw status 2>/dev/null | grep -q '"status":"unlocked"'; }

BW_OK=""
for candidate in "${BW_SESSION:-}" "$(fnox get BW_SESSION 2>/dev/null || true)" "$(cat "$HOME/.bw_session" 2>/dev/null || true)"; do
  if session_ok "$candidate"; then BW_OK="$candidate"; break; fi
done
if [[ -z "$BW_OK" ]]; then
  echo "with-secrets.sh: no valid BW_SESSION -- run scripts/bw-unlock-prompt.sh, then retry" >&2
  exit 1
fi
export BW_SESSION="$BW_OK"

if [[ $# -eq 0 ]]; then
  echo "usage: $(basename "$0") <command> [args...]" >&2
  exit 64
fi

exec fnox exec -- "$@"
