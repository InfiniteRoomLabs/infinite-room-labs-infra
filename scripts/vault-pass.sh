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
# Needs a valid BW_SESSION (the secret is Bitwarden-backed) -- resolved and
# validated by the shared resolver (see includes/bw-session.sh).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=includes/bw-session.sh
source "$SCRIPT_DIR/includes/bw-session.sh"
resolve_bw_session || exit 1

exec fnox get ANSIBLE_VAULT_PASSWORD
