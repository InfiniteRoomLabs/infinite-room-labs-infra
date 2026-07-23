---
name: manage-secrets
description: >
  Manage secrets across Bitwarden, bw-sync-config.yaml, and fnox.toml.
  Covers create, rotate, edit, move, delete, and sync verification. Use whenever the user
  mentions credentials, passwords, API keys/tokens, bitwarden, bw-sync, fnox,
  rotation policy, compromised passwords, decommissioning services that had credentials,
  or onboarding new services that need keys stored. Prefer triggering over not.
---

# Secrets Management

Manage the full lifecycle of secrets in the IRL infra repo. Bitwarden is the single source
of truth. Secrets reach consumers two ways:

- **Cluster secrets**: Bitwarden -> `bw-sync-config.yaml` -> `bw-sync.sh` -> Ansible Vault
  and/or Kubernetes Secrets.
- **Env-var secrets** (Terraform/CLI tokens): declared in `fnox.toml`, fetched LIVE from
  Bitwarden by fnox and injected per-command via `fnox exec` / `scripts/with-secrets.sh`.
  There is no `.env` or `.envrc` -- nothing loads ambiently. Because fnox reads Bitwarden
  live, rotating an env-var secret needs no separate sync step.

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
| `scripts/bw-sync-config.yaml` | Maps BW items to Ansible vars and K8s secrets (cluster secrets) |
| `fnox.toml` | Declares env-var secrets and maps each to a BW item/field (committed; no values) |
| `~/.config/fnox/config.toml` | Global fnox providers (bitwarden, age) + age-encrypted BW_SESSION |
| `scripts/with-secrets.sh` | Wraps a command in `fnox exec` (also seeds BW_SESSION) |
| `mise.toml` | Tool versions, task runner, and non-secret `[env]` identifiers |
| `scripts/bw-sync.sh` | Syncs BW -> Ansible Vault and/or K8s |
| `.env.example` | Deprecated reference list of variable names (committed) |

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

1. **Check BW status** -- `bw status` must show `unlocked`. If not (or any fnox/bw-sync command reports a locked/stale session), run `./scripts/bw-unlock-prompt.sh`: it spawns a front-and-center terminal where the user unlocks Bitwarden, refreshes both `~/.bw_session` and fnox's age-stored `BW_SESSION` (which shadows the file), then detaches. Tell the user it's waiting, then poll `bw status` and retry.
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
5. **If an env var is needed (Terraform/CLI token):** declare it in `fnox.toml` under
   `[secrets]`, mapping to the BW item. Use `value = "<bw_item>"` for a Login item
   (password field) or `value = "<bw_item>/notes"` for a secure note. No `.env`/`.envrc`
   edits -- fnox fetches from Bitwarden live. (If it is a non-secret identifier, add it to
   `mise.toml [env]` instead.)
   ```toml
   [secrets]
   MY_TOKEN = { provider = "bitwarden", value = "<bw_item>", description = "..." }
   ```
6. **Verify** -- fnox resolves it (length/existence only, never the value):
   ```bash
   fnox check                                   # config + provider validity
   BW_SESSION="$(fnox get BW_SESSION)" bash -c 'v="$(fnox get MY_TOKEN)"; echo "len=${#v}"'
   ```
7. **Offer to sync** (cluster secrets only) -- env-var secrets need no sync. For cluster
   secrets, ask if the user wants to run bw-sync.sh now:
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
3. **Env-var secrets need no further action** -- fnox reads the BW value live, so the new
   value is picked up on the next `fnox exec`. Verify (length only):
   `BW_SESSION="$(fnox get BW_SESSION)" bash -c 'v="$(fnox get VAR_NAME)"; echo len=${#v}'`.
4. **Cluster secrets** -- offer to sync: `./scripts/bw-sync.sh --target both` (or
   `mise run secrets:sync`) to push the new value into Ansible Vault / K8s.

### Edit Secret Metadata

Change the mappings (ansible_var, k8s_secret, k8s_key) or env var name without changing the secret value.

1. Edit the entry in `bw-sync-config.yaml` (cluster secrets) and/or `fnox.toml` (env-var secrets).
2. If an env var name changed: rename the key in `fnox.toml [secrets]`.
3. If the BW item name changed: update `bw_item` in `bw-sync-config.yaml` and/or the `value`
   in `fnox.toml`, then rename the item in BW:
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

1. **Remove from bw-sync-config.yaml** -- delete the entry (cluster secrets).
2. **Remove from fnox.toml** -- delete the `[secrets]` entry (env-var secrets). If it was a
   non-secret identifier, remove it from `mise.toml [env]` instead.
3. **Delete from BW** -- only after user confirms:
   ```bash
   bw delete item "<id>"
   ```
4. **Offer to sync** -- for cluster secrets, run bw-sync to remove the K8s secret / Ansible
   var from targets. Env-var secrets need no sync.

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
- `fnox.toml` is committed (only BW references, no values); `fnox.local.toml` is gitignored.
  The legacy `.env` is gitignored and deprecated; `.env.example` is a committed reference list.
- Rotation policy: 180 days for infra secrets, 365 days for service secrets.
- Full rotation SOP: `ansible/docs/sops/rotate-secrets.md`.
