#!/usr/bin/env bash
set -euo pipefail

# scripts/mcp-grafana.sh
# Launches the mcp-grafana MCP server (Grafana Labs, official) for Claude Code.
#
# Unlike scripts/with-secrets.sh (which does `fnox exec` -> ALL repo secrets),
# this fetches ONLY the single GRAFANA_SERVICE_ACCOUNT_TOKEN via `fnox get`, so
# the third-party binary never sees Cloudflare/Porkbun/TFC/etc. infra creds.
#
# Ensure mise-managed binaries (fnox, mcp-grafana, bw) resolve regardless of how
# the MCP client spawned us.
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"

# BW_SESSION: resolved and validated by the shared resolver (env -> ~/.bw_session).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=includes/bw-session.sh
source "$SCRIPT_DIR/includes/bw-session.sh"
resolve_bw_session || exit 1

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
