#!/usr/bin/env bash
# gunio-cookie-refresh.sh -- weekly push of the local browser's live gun.io
# session cookie into Vault, so the public gunio-mcp deployment keeps a valid
# session without manual rotation (see docs/runbooks/gunio-mcp.md).
#
# Flow: resolve BW_SESSION -> approle login (write-only token) -> harvest the
# cookie host-side -> vault kv put -> force the ESO refresh and restart the pod
# (envFrom is not hot-reloaded, so the running pod keeps the old cookie until a
# restart). The cookie and the Vault token never touch argv, disk, or the log.
#
# Auth is a dedicated WRITE-ONLY AppRole (policy gunio-cookie-writer: create/
# update on irl/data/gunio-mcp/app only -- cannot read the cookie back, cannot
# touch any other path). Its role-id + secret-id live ONLY in the Bitwarden
# item `vault-gunio-cookie-writer` (never committed) and are read live here.
#
# Shipped from this infra repo (ansible/files/laptop/), installed by
# playbooks/laptop.yml. Run standalone:
#   systemctl --user start gunio-cookie-refresh.service
#   journalctl --user -u gunio-cookie-refresh -e
set -euo pipefail

# mise shims FIRST: ~/.local/bin/vault is claude-code-tools' dotenv tool, which
# shadows the real HashiCorp CLI. bw/kubectl live in /usr/local/bin.
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
export VAULT_ADDR="https://vault.lab.infiniteroomlabs.cloud"   # Tailscale split-DNS; no port-forward
export KUBECONFIG="$HOME/.kube/homelab.yaml"

REPO="$HOME/projects/infinite-room-labs/infinite-room-labs-infra"
HARVEST="$HOME/projects/infinite-room-labs/gunio-mcp/scripts/lib/harvest-cookie.sh"

[[ -x "$HARVEST" ]] || { echo "gunio-cookie-refresh: harvest script missing at $HARVEST" >&2; exit 1; }

# BW_SESSION for `bw get` (validated; env or ~/.bw_session cache). A locked
# vault is a clean skip, not a crash -- monitoring (auth_status) catches a
# genuinely stale cookie, and next week's run retries.
# shellcheck source=/dev/null
. "$REPO/scripts/includes/bw-session.sh"
resolve_bw_session || { echo "gunio-cookie-refresh: Bitwarden locked, skipping this run" >&2; exit 0; }

# Short-lived write-only token from the dedicated AppRole.
rid=$(bw get username vault-gunio-cookie-writer)
sid=$(bw get password vault-gunio-cookie-writer)
tok=$(vault write -field=token auth/approle/login role_id="$rid" secret_id="$sid")
unset rid sid

# Harvest from the logged-in browser and write. A pipe keeps the value off argv
# and out of shell history; harvest exits non-zero (set -e aborts) if no live
# session is found, leaving the existing Vault value untouched.
"$HARVEST" | VAULT_TOKEN="$tok" vault kv put irl/gunio-mcp/app GUNIO_COOKIE=-
unset tok

# Make it take effect: ESO's refresh is lazy (1h) and envFrom is not
# hot-reloaded, so nudge the sync and restart the (stateless) pod.
kubectl -n gunio annotate externalsecret gunio-mcp-secrets force-sync="$(date +%s)" --overwrite
kubectl -n gunio rollout restart deploy/irl-gunio-mcp
kubectl -n gunio rollout status deploy/irl-gunio-mcp --timeout=120s
echo "gunio-cookie-refresh: cookie pushed to Vault and deploy restarted"
