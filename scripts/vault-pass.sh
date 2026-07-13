#!/usr/bin/env bash
set -euo pipefail

# scripts/vault-pass.sh
# Ansible vault-password client. Ansible runs this executable (configured via
# ansible.cfg `vault_password_file`) and reads the vault password from stdout.
# The password comes from fnox (global secret ANSIBLE_VAULT_PASSWORD, backed by
# the Bitwarden item ansible-vault-password). No static .vault-password file and
# no ambient env var -- the secret is fetched on demand and printed only to the
# pipe ansible reads.
#
# Needs BW_SESSION (the secret is Bitwarden-backed). Resolve it the same way as
# scripts/with-secrets.sh: env -> fnox age -> ~/.bw_session cache.

# A candidate is only trusted if bw accepts it -- an inherited env BW_SESSION
# can be stale (e.g. a long-lived agent shell started before a re-unlock).
session_ok() { [[ -n "$1" ]] && BW_SESSION="$1" bw status 2>/dev/null | grep -q '"status":"unlocked"'; }

for candidate in "${BW_SESSION:-}" "$(fnox get BW_SESSION 2>/dev/null || true)" "$(cat "$HOME/.bw_session" 2>/dev/null || true)"; do
  if session_ok "$candidate"; then
    export BW_SESSION="$candidate"
    exec fnox get ANSIBLE_VAULT_PASSWORD
  fi
done

echo "vault-pass.sh: no valid BW_SESSION -- run scripts/bw-unlock-prompt.sh, then retry" >&2
exit 1
