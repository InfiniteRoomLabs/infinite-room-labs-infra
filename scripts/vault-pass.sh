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

if [[ -z "${BW_SESSION:-}" ]]; then
  BW_SESSION="$(fnox get BW_SESSION 2>/dev/null || true)"
fi
if [[ -z "${BW_SESSION:-}" && -f "$HOME/.bw_session" ]]; then
  BW_SESSION="$(cat "$HOME/.bw_session")"
fi
export BW_SESSION

exec fnox get ANSIBLE_VAULT_PASSWORD
