#!/usr/bin/env bash
set -euo pipefail

# scripts/mcp-grafana.sh
# Launches the mcp-grafana MCP server (Grafana Labs, official) for Claude Code.
#
# Unlike scripts/with-secrets.sh (which does `fnox exec` -> ALL repo secrets),
# this fetches ONLY the single GRAFANA_SERVICE_ACCOUNT_TOKEN via `fnox get`, so
# the third-party binary never sees Cloudflare/Porkbun/TFC/etc. infra creds.
#
# BW_SESSION resolution: try each source and USE THE FIRST THAT ACTUALLY UNLOCKS.
# A plain env -> fnox -> ~/.bw_session fallback chain is buggy here: `fnox get
# BW_SESSION` (age provider) returns a stale-but-nonempty session that shadows a
# working ~/.bw_session, yielding an empty token and a 401. Probing `bw status`
# per candidate sidesteps the recurring stale-session trap.

# Ensure mise-managed binaries (fnox, mcp-grafana, bw) resolve regardless of how
# the MCP client spawned us.
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"

_incoming="${BW_SESSION:-}"
BW_SESSION=""
for cand in "$_incoming" "$(fnox get BW_SESSION 2>/dev/null || true)" "$(cat "$HOME/.bw_session" 2>/dev/null || true)"; do
  [[ -z "$cand" ]] && continue
  if [[ "$(BW_SESSION="$cand" bw status 2>/dev/null | jq -r '.status' 2>/dev/null)" == "unlocked" ]]; then
    BW_SESSION="$cand"; break
  fi
done
export BW_SESSION
if [[ -z "$BW_SESSION" ]]; then
  echo "mcp-grafana: no unlocked Bitwarden session (run 'bw-unlock')" >&2
  exit 1
fi

GRAFANA_URL="${GRAFANA_URL:-https://grafana.lab.infiniteroomlabs.cloud}"
GRAFANA_TOKEN="$(fnox get GRAFANA_SERVICE_ACCOUNT_TOKEN)"

# Exec with a CLEAN env (env -i) so mcp-grafana sees ONLY what it needs. This
# strips any infra secrets that may be ambient in the launching shell -- the
# `fnox get` above is single-secret, but env -i is what actually guarantees the
# third-party binary can't read Cloudflare/TFC/etc. tokens. PATH carries the
# mise shims so the binary resolves; HOME for any config lookup.
exec env -i \
  PATH="$PATH" \
  HOME="$HOME" \
  GRAFANA_URL="$GRAFANA_URL" \
  GRAFANA_SERVICE_ACCOUNT_TOKEN="$GRAFANA_TOKEN" \
  mcp-grafana "$@"
