# SOP: Rotate Secrets

Secrets are stored in Bitwarden (`IRL/` folder tree) and synced to Ansible Vault and
Kubernetes via `scripts/bw-sync.sh`. Do not edit `vault.yml` directly -- Bitwarden is
the source of truth.

## Rotation Policy

| Secret type | Max age | Examples |
|-------------|---------|---------|
| Infra | 180 days | database passwords, API keys for infra tooling |
| Service | 365 days | third-party service credentials, webhook tokens |

Run `bw-sync.sh --check-rotation` at any time to see what is overdue.

## Rotate a Single Secret

1. Open Bitwarden and find the item under the `IRL/` folder.
2. Update the password or key value and save.
3. Sync to both targets:
   ```bash
   ./scripts/bw-sync.sh --target both
   ```
4. Verify the sync landed correctly:
   ```bash
   ./scripts/bw-sync.sh --verify-k8s
   ```
5. Restart affected services if the secret is consumed at startup:
   ```bash
   cd /opt/irl/{stack} && sudo docker compose restart
   ```

## Rotate All Secrets for a Service

1. Find all overdue secrets for the service:
   ```bash
   ./scripts/bw-sync.sh --check-rotation
   ```
2. Update each overdue item in Bitwarden.
3. Sync and verify:
   ```bash
   ./scripts/bw-sync.sh --target both
   ./scripts/bw-sync.sh --verify-k8s
   ```
4. Re-run the affected Ansible playbook to propagate updated vars:
   ```bash
   ./run-ansible.sh playbook playbooks/{service}.yml
   ```

## Emergency Rotation (Compromised Credential)

Treat as P1. Skip dry-run. Move fast.

1. Revoke or regenerate the credential at the source (provider dashboard, database, etc.).
2. Update the item in Bitwarden immediately.
3. Sync without dry-run:
   ```bash
   ./scripts/bw-sync.sh --target both
   ```
4. Verify sync:
   ```bash
   ./scripts/bw-sync.sh --verify-k8s
   ```
5. Restart all pods/containers that hold the secret in memory:
   ```bash
   # Kubernetes
   kubectl rollout restart deployment/{name} -n {namespace}

   # Docker Compose (homelab)
   cd /opt/irl/{stack} && sudo docker compose restart
   ```
6. Confirm the old credential no longer works (e.g., attempt login with old value).
7. File an incident note in `docs/runbooks/` with timeline and affected systems.

## Database Passwords

After rotating a database password in Bitwarden and syncing:

```bash
# Update the PostgreSQL user directly
docker exec -it irl-postgres psql -U postgres -c \
  "ALTER USER {dbuser} PASSWORD '{new_password}';"
```

Then restart the consuming service.

## SSH Keys

1. Generate a new key:
   ```bash
   ssh-keygen -t ed25519 -C "wes@irl-infra"
   ```
2. Add the new public key to Bitwarden under `IRL/infra/ssh`.
3. Update `irl_admin_ssh_pubkey` in `inventory/group_vars/all/main.yml`.
4. Run the users playbook:
   ```bash
   ./run-ansible.sh playbook playbooks/users.yml
   ```
5. Test SSH access with the new key before removing the old one from `authorized_keys`.
