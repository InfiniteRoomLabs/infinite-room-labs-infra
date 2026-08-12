# Vault policy: eso-gunio-mcp
# ============================
# Read-only grant for External Secrets Operator over the gunio-mcp workload
# secrets, and NOTHING else. KV v2 splits every logical path into data/ (the
# secret payload) and metadata/ (versions, custom metadata) -- ESO reads both.
#
# LEAST PRIVILEGE, BY DESIGN: future workloads get their own policy file next
# to this one and their own `vault policy write`, attached to the same
# `external-secrets` AppRole via token_policies. Do NOT widen these globs to
# `irl/data/*`.
#
# Uploaded by scripts/vault-bootstrap-eso.sh (operator-run); not consumed by
# Ansible directly. Static file (no Jinja), colocated with the other Vault
# config assets.

path "irl/data/gunio-mcp/*" {
  capabilities = ["read"]
}

path "irl/metadata/gunio-mcp/*" {
  capabilities = ["read"]
}
