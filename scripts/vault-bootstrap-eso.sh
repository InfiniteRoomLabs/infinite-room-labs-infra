#!/usr/bin/env -S usage bash
set -euo pipefail

#USAGE flag "--emit-secret-id" help="Generate AND PRINT an AppRole secret-id (sensitive!). Default is to print the command for the operator to run instead."

# scripts/vault-bootstrap-eso.sh
# Operator-run, idempotent bootstrap of the Vault side of the External Secrets
# Operator (ESO) integration -- first consumer: the gunio-mcp deployment.
#
# What it does (safe to re-run):
#   1. Enables the KV v2 secrets engine at mount `irl/` if not present.
#   2. Uploads policy `eso-gunio-mcp` (read-only on irl/{data,metadata}/gunio-mcp/*)
#      from ansible/templates/configs/vault/eso-gunio-mcp-policy.hcl.
#   3. Enables AppRole auth if not present and upserts role `external-secrets`
#      bound to that policy.
#   4. Prints the role-id (NOT secret) plus the exact next commands: generate
#      a secret-id, store both in the Bitwarden item `vault-eso-approle`
#      (username = role-id, password = secret-id), and seed the two gunio-mcp
#      KV paths.
#
# Auth comes from the ENVIRONMENT ONLY -- never arguments, never logged:
#   VAULT_ADDR   e.g. https://vault.lab.infiniteroomlabs.cloud (Traefik) or
#                http://127.0.0.1:8200 via `kubectl -n irl port-forward vault-0 8200:8200`
#   VAULT_TOKEN  a token with sys/mounts, sys/policies, and auth/approle write
#                (in practice: the root token, used interactively and revoked-
#                from-memory after; see docs/plans/2026-08-12-gunio-mcp-cloudflare-serving.md)
#
# This script NEVER prints a secret-id unless explicitly asked via
# --emit-secret-id, and never prints VAULT_TOKEN under any circumstances.
#
# Dependencies: vault, jq

MOUNT="irl"
POLICY_NAME="eso-gunio-mcp"
ROLE_NAME="external-secrets"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
POLICY_FILE="$REPO_ROOT/ansible/templates/configs/vault/eso-gunio-mcp-policy.hcl"

EMIT_SECRET_ID=false; [[ -n "${usage_emit_secret_id:-}" ]] && EMIT_SECRET_ID=true

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
for cmd in vault jq; do
  command -v "$cmd" &>/dev/null || { echo "Error: missing required command: $cmd" >&2; exit 1; }
done

if [[ -z "${VAULT_ADDR:-}" || -z "${VAULT_TOKEN:-}" ]]; then
  echo "Error: VAULT_ADDR and VAULT_TOKEN must be set in the environment." >&2
  echo "They are never accepted as arguments and never logged." >&2
  exit 1
fi

[[ -f "$POLICY_FILE" ]] || { echo "Error: policy file not found: $POLICY_FILE" >&2; exit 1; }

sealed=$(vault status -format=json 2>/dev/null | jq -r '.sealed' || echo "unreachable")
if [[ "$sealed" != "false" ]]; then
  echo "Error: Vault at VAULT_ADDR is sealed or unreachable (sealed=$sealed)." >&2
  echo "Unseal first: kubectl exec -n irl vault-0 -- vault operator unseal (3x)." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. KV v2 mount at irl/
# ---------------------------------------------------------------------------
if vault secrets list -format=json | jq -e --arg m "$MOUNT/" 'has($m)' >/dev/null; then
  mount_type=$(vault secrets list -format=json | jq -r --arg m "$MOUNT/" '.[$m].type')
  if [[ "$mount_type" != "kv" ]]; then
    echo "Error: mount $MOUNT/ exists but is type '$mount_type', not kv. Refusing to touch it." >&2
    exit 1
  fi
  echo "[ok]       KV mount $MOUNT/ already enabled"
else
  vault secrets enable -path="$MOUNT" -version=2 kv >/dev/null
  echo "[created]  KV v2 mount $MOUNT/"
fi

# ---------------------------------------------------------------------------
# 2. Policy (upsert -- vault policy write is idempotent)
# ---------------------------------------------------------------------------
vault policy write "$POLICY_NAME" "$POLICY_FILE" >/dev/null
echo "[applied]  policy $POLICY_NAME (from ${POLICY_FILE#"$REPO_ROOT"/})"

# ---------------------------------------------------------------------------
# 3. AppRole auth + role
# ---------------------------------------------------------------------------
if vault auth list -format=json | jq -e 'has("approle/")' >/dev/null; then
  echo "[ok]       approle auth already enabled"
else
  vault auth enable approle >/dev/null
  echo "[enabled]  approle auth"
fi

# Upsert the role. TTL rationale: ESO logs in per reconcile and holds tokens
# briefly -- short token TTLs limit blast radius. secret_id_ttl=0 (non-expiring)
# because the secret-id is delivered through the Bitwarden lane and rotated on
# the 180-day infra policy, not by Vault expiry (an expired secret-id would
# silently break every refresh).
vault write "auth/approle/role/$ROLE_NAME" \
  token_policies="$POLICY_NAME" \
  token_ttl=20m \
  token_max_ttl=1h \
  token_num_uses=0 \
  secret_id_ttl=0 \
  secret_id_num_uses=0 >/dev/null
echo "[applied]  approle role $ROLE_NAME (policies: $POLICY_NAME)"

ROLE_ID=$(vault read -field=role_id "auth/approle/role/$ROLE_NAME/role-id")

echo ""
echo "role-id (identifier, not a secret -- pairs with the secret-id):"
echo "  $ROLE_ID"

# ---------------------------------------------------------------------------
# 4. Operator next steps (nothing sensitive printed by default)
# ---------------------------------------------------------------------------
if [[ "$EMIT_SECRET_ID" == true ]]; then
  echo ""
  echo "!!! --emit-secret-id: the value below is a LIVE CREDENTIAL. !!!"
  echo "!!! Put it straight into Bitwarden and clear your terminal  !!!"
  echo "!!! scrollback. Anyone holding role-id + secret-id can read !!!"
  echo "!!! every secret the $POLICY_NAME policy grants.            !!!"
  echo ""
  vault write -f -field=secret_id "auth/approle/role/$ROLE_NAME/secret-id"
else
  cat <<EOF

Next steps (run yourself -- this script does not echo secret-ids):

  1. Generate a secret-id (prints to YOUR terminal only):
       vault write -f -field=secret_id auth/approle/role/$ROLE_NAME/secret-id

  2. Store it in Bitwarden as a Login item named 'vault-eso-approle' under
     the IRL folder tree:
       username = the role-id printed above
       password = the secret-id from step 1
     (bw-sync-config.yaml maps this one item to the k8s Secret
     external-secrets/vault-eso-approle with keys role-id + secret-id.)

  3. Sync it into the cluster:
       mise run secrets:sync

  4. Seed the gunio-mcp secrets (stdin style -- keeps values out of argv
     and shell history):
       scripts/lib/harvest-cookie.sh (gunio-mcp repo) | vault kv put $MOUNT/gunio-mcp/app GUNIO_COOKIE=-
       vault kv put $MOUNT/gunio-mcp/cloudflared token=-     # then paste the connector token + ctrl-d
EOF
fi
