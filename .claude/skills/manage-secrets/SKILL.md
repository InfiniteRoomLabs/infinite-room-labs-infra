---
name: manage-secrets
description: >
  Manage secrets across Bitwarden, bw-sync-config.yaml, .envrc, .env.example, and .env.
  Covers create, rotate, edit, move, delete, and sync verification. Use whenever the user
  mentions credentials, passwords, API keys/tokens, ~/.secrets/, bitwarden, bw-sync,
  rotation policy, compromised passwords, decommissioning services that had credentials,
  or onboarding new services that need keys stored. Prefer triggering over not.
---

# Secrets Management

Manage the full lifecycle of secrets in the IRL infra repo. Secrets flow through a pipeline:
source file → Bitwarden → bw-sync-config.yaml → Ansible Vault and/or Kubernetes.
Some secrets also surface as environment variables via .envrc/.env for Terraform and other tools.

## Critical Rule

**NEVER read, cat, echo, print, head, tail, or display any portion of a secret value.**
Not even "the first 10 characters" to verify. Not even in a subshell. Use only existence
and length checks:

```bash
# GOOD - verify a secret exists without seeing it
test -n "$VAR_NAME" && echo "set" || echo "not set"
wc -c < ~/.secrets/.some-key
stat ~/.secrets/.some-key

# BAD - leaks the value
cat ~/.secrets/.some-key
echo $VAR_NAME
printenv VAR_NAME | head -c 10
```

When piping secrets into Bitwarden or files, construct the pipeline so the value never
appears in tool output. Use bash variable expansion in a single command, not intermediate
steps that surface in conversation.

## Project Files

| File | Purpose |
|------|---------|
| `scripts/bw-sync-config.yaml` | Maps BW items to Ansible vars and K8s secrets |
| `.envrc` | direnv config; loads .env, lists required env vars |
| `.env.example` | Template with empty placeholders (committed) |
| `.env` | Actual values (gitignored, loaded by direnv) |
| `scripts/bw-sync.sh` | Syncs BW → Ansible Vault and/or K8s |

## Bitwarden Folder Structure

Secrets live under the `IRL/` folder tree in Bitwarden. Common subfolders:

- `IRL/Services/{ServiceName}` -- SaaS/app credentials (SendGrid, Gitea, etc.)
- `IRL/Infrastructure/{Category}` -- Infra credentials (Cloudflare, PostgreSQL, etc.)
- `IRL/Cloud/{Provider}` -- Cloud provider credentials (DigitalOcean, Oracle, etc.)
- `IRL/Signing/{Type}` -- Signing keys (Ansible Vault, TLS, etc.)

Create new subfolders as needed to keep things organized.

## Operations

### Create a New Secret

Gather this information (ask the user for anything missing):

1. **Secret name** -- the `bw_item` identifier (e.g., `sendgrid-api-key`)
2. **Source** -- where the value lives (e.g., `~/.secrets/.sendgrid-api-key`)
3. **BW folder** -- where in the IRL tree it belongs (e.g., `IRL/Services/SendGrid`)
4. **Ansible var** -- the vault variable name (e.g., `vault_sendgrid_api_key`), or null if not needed
5. **K8s secret** -- the Secret name (e.g., `sendgrid-credentials`), or null if not needed
6. **K8s key** -- the key within the Secret (e.g., `api-key`), or null if not needed
7. **Env var** -- the environment variable name (e.g., `SENDGRID_API_KEY`), or null if not needed

Then execute:

1. **Check BW status** -- `bw status` must show `unlocked`. If not, tell the user to run `! bw unlock`.
2. **Create BW folder** if it doesn't exist:
   ```bash
   bw create folder "$(echo '{"name":"IRL/Services/FooBar"}' | bw encode)"
   ```
3. **Create BW Login item** -- pipe the secret value as the password field (bw-sync.sh reads `.login.password`):
   ```bash
   FOLDER_ID="<id>" && VAL=$(cat ~/.secrets/.the-key) && \
   jq -n --arg name "<bw_item>" --arg pw "$VAL" --arg folder "$FOLDER_ID" \
     '{type:1, name:$name, folderId:$folder, login:{password:$pw, uris:[]}}' \
   | bw encode | bw create item 2>/dev/null \
   | jq -r '"Created: \(.name) | ID: \(.id)"'
   ```
4. **Add to bw-sync-config.yaml** -- append a new entry under `secrets:` with the appropriate mappings.
   Use a comment header for the service section (e.g., `# ── SendGrid (transactional email) ──`).
   If ansible_var or k8s_secret is not needed, set them to `null`.
5. **If an env var is needed:**
   - Add to the `env_vars_required` line in `.envrc`
   - Add a comment documenting the var in the `.envrc` comments block
   - Add a placeholder line to `.env.example` with a section comment
   - Append the actual value to `.env` (pipe from source file, never display)
6. **Verify** -- check the env var is loaded via direnv (existence check only):
   ```bash
   direnv allow . 2>&1 && direnv exec . bash -c 'test -n "$VAR_NAME" && echo "set" || echo "not set"'
   ```
7. **Offer to sync** -- ask the user if they want to run bw-sync.sh now:
   ```bash
   ./scripts/bw-sync.sh --target both
   ```
   Or `--target ansible` / `--target k8s` if only one target is relevant.
   Suggest `--dry-run` first if the user hasn't synced recently.

### Rotate a Secret

A rotation replaces the value of an existing secret without changing its plumbing.

1. Confirm which secret is being rotated and where the new value lives.
2. **Update BW item** -- get the item ID, then update the notes field:
   ```bash
   ITEM_ID=$(bw list items --search "<bw_item>" 2>/dev/null | jq -r '.[0].id') && \
   NEW_VAL=$(cat ~/.secrets/.new-key) && \
   bw get item "$ITEM_ID" 2>/dev/null \
   | jq --arg val "$NEW_VAL" '.notes = $val' \
   | bw encode | bw edit item "$ITEM_ID" 2>/dev/null \
   | jq -r '"Updated: \(.name)"'
   ```
3. **Update .env** if the secret has an env var -- replace the existing line (don't append a duplicate).
4. **Verify** the env var is still loaded (existence check only).
5. **Offer to sync** -- `./scripts/bw-sync.sh --target both` to push the new value to Ansible/K8s.

### Edit Secret Metadata

Change the mappings (ansible_var, k8s_secret, k8s_key) or env var name without changing the secret value.

1. Edit the entry in `bw-sync-config.yaml`.
2. If the env var name changed: update `.envrc`, `.env.example`, and `.env` (rename the variable).
3. If the BW item name changed: update `bw_item` in the config and rename the item in BW:
   ```bash
   bw get item "<id>" 2>/dev/null \
   | jq --arg name "new-name" '.name = $name' \
   | bw encode | bw edit item "<id>" 2>/dev/null \
   | jq -r '"Renamed to: \(.name)"'
   ```
4. Offer to sync.

### Move a Secret

Move a BW item to a different folder (e.g., reorganizing from `IRL/Services` to `IRL/Infrastructure`).

1. Find the item ID and the target folder ID.
2. Update the item's folderId:
   ```bash
   bw get item "<id>" 2>/dev/null \
   | jq --arg fid "<new_folder_id>" '.folderId = $fid' \
   | bw encode | bw edit item "<id>" 2>/dev/null \
   | jq -r '"Moved: \(.name)"'
   ```
3. No sync needed -- BW folder structure doesn't affect Ansible/K8s.

### Delete a Secret

Removes a secret from everywhere. **Always confirm with the user before deleting.**

1. **Remove from bw-sync-config.yaml** -- delete the entry.
2. **Remove from .envrc** -- remove from `env_vars_required` and the comment.
3. **Remove from .env.example** -- delete the placeholder line and section comment.
4. **Remove from .env** -- delete the line with the actual value.
5. **Delete from BW** -- only after user confirms:
   ```bash
   bw delete item "<id>"
   ```
6. **Offer to sync** -- to remove the K8s secret / Ansible var from targets.
7. **Clean up source file** if it exists in `~/.secrets/`:
   ```bash
   rm ~/.secrets/.the-key
   ```
   Ask the user before deleting the source file.

## Sync Targets

The `bw-sync.sh` script pushes secrets from Bitwarden to downstream targets:

| Target | Flag | What it does |
|--------|------|--------------|
| Ansible Vault | `--target ansible` | Encrypts values into `ansible/inventory/group_vars/all/vault.yml` |
| Kubernetes | `--target k8s` | Creates/updates Secrets in the `irl` namespace |
| Both | `--target both` | Does both of the above |
| Dry run | `--dry-run` | Preview changes without writing (combine with any target) |
| Verify | `--verify-k8s` | Diff K8s secrets against Bitwarden |
| Rotation check | `--check-rotation` | Report secrets overdue for rotation |

## Notes

- BW type `1` = Login. Always use this for secrets (bw-sync.sh reads `.login.password`).
- `bw encode` takes JSON on stdin and base64-encodes it for the BW CLI.
- After any BW write, run `bw sync` if you need to ensure other BW clients see the change.
- The `.env` file is gitignored. The `.env.example` file is committed.
- Rotation policy: 180 days for infra secrets, 365 days for service secrets.
- Full rotation SOP: `ansible/docs/sops/rotate-secrets.md`.
