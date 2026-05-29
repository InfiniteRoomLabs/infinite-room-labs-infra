# Runbook: Diagnosing bw-sync.sh Issues

## Severity: MEDIUM (depends on which secrets are affected)

`bw-sync.sh` is the only authorized write path between Bitwarden and the
two downstream targets (`ansible/inventory/group_vars/all/vault.yml` and
Kubernetes Secrets in the `irl` namespace). When it fails or silently
does the wrong thing, services break in confusing ways: pods crash on
auth errors, Helm releases come up with placeholder values, or the
ansible vault refuses to decrypt.

This runbook covers known failure modes plus general diagnostics. Two
real bugs were caught and fixed during the paperless-ngx bringup --
both are described here so future failures in the same class can be
identified faster.

## Detection

- `bw-sync.sh` exit code is non-zero
- `[error]` lines appear in the sync output
- A new K8s Secret is missing from the `irl` namespace despite a clean
  sync run
- An ansible playbook fails with "vault var X is not defined"
- A pod crashes with auth errors despite the operator believing the
  credential was rotated and synced

## First-pass diagnostics

```bash
# 1. Bitwarden status -- is the CLI session even alive?
bw status
# Expected: {"status":"unlocked", ...}
# If "locked" or "unauthenticated": run `bw unlock` and re-export BW_SESSION

# 2. Dry run with verbose output
./scripts/bw-sync.sh --dry-run --target both 2>&1 | tee /tmp/bw-sync-dry.log

# 3. Filter for the secret you care about
grep -iE "<bw_item_name>|error|fail" /tmp/bw-sync-dry.log
```

The dry run NEVER writes to vault.yml or k8s. It's safe to run as
many times as needed during diagnostics.

## Known issues (historical, both fixed)

These bugs were caught during the paperless-ngx bringup. They're
documented here so the same SYMPTOMS will be recognized faster if a
similar bug appears in a different code path.

### Issue 1: yq lexer error on JSON values (fixed in commit 117ed15)

**Symptom**: a particular BW item containing a JSON blob (or any value
with embedded double quotes) fails the ansible sync with:

```
Error: 1:52: lexer: invalid input text "openid_connect\":..."
```

The summary line still reports `0 errors` because the script's
error counter doesn't catch yq lexer failures. The vault.yml gets
written, but the offending key is missing or contains a corrupted value.

**Root cause**: `bw-sync.sh` was shell-interpolating the value into the
yq expression as a quoted literal:

```bash
yq e -i ".${ansible_var} = \"${value}\"" "$ANSIBLE_PLAIN_FILE"
```

Any value containing double quotes broke the lexer. The fix was to use
yq's `strenv()` function and pass the value via an environment variable:

```bash
YQ_VALUE="$value" yq e -i ".${ansible_var} = strenv(YQ_VALUE)" "$ANSIBLE_PLAIN_FILE"
```

**Recognition pattern**: any future "lexer error" or "syntax error" from
yq during sync is almost certainly a value-quoting issue. The fix
template is the same -- pass it through env, never inline.

### Issue 2: state file collision between ansible and k8s sync (fixed in commit ac7e442)

**Symptom**: `bw-sync.sh --target both` reports a successful sync with
`updated` lines for new BW items, but the corresponding K8s Secrets do
not exist in the cluster afterward. Specifically, the k8s sync section
of the output shows `[unchanged]` for the new secrets even though they
were never created in K8s.

```
[updated]   pg-paperless -> vault_pg_passwords.paperless     <-- ansible sync
...
[unchanged] postgres-paperless                                 <-- k8s sync (WRONG)
K8s sync complete: 0 updated, 19 unchanged, 0 errors          <-- LIE
```

**Root cause**: the script's checksum-tracking state file
(`~/.local/share/irl/bw-sync-state.json`) was a flat
`{item_name -> checksum}` map. After a successful ansible sync, the
script called `save_checksum()` for every item -- which by side-effect
set the checksum for items that the k8s sync also tracks. When the k8s
sync ran in the same `--target both` invocation, it saw matching
checksums in the state file and short-circuited the `kubectl apply`,
even though the K8s Secret had never been created.

**Recognition pattern**: if you ever see a sync run report
"X updated, Y unchanged, 0 errors" but a `kubectl get secret -n irl`
disagrees, this is the failure mode. You can confirm by looking at
the state file:

```bash
jq 'keys[] | select(startswith("ansible:") or startswith("k8s:") | not)' \
  ~/.local/share/irl/bw-sync-state.json
```

Any unscoped keys (without an `ansible:` or `k8s:` prefix) are leftovers
from before the fix. The script's `get_stored_checksum` falls back to
unscoped keys for backward compatibility, but new writes always use
the scoped form.

**Fix template**: target keys should be namespaced with the target
name. The fix wrapped both `get_stored_checksum` and `save_checksum`
to take an optional `target` argument and use a `${target}:${item_name}`
key. All four call sites in the script were updated to pass `"ansible"`
or `"k8s"` accordingly.

**Recovery if this hits you on a stale state file**:

```bash
# Clear specific entries (e.g., paperless)
jq 'with_entries(select(.key | startswith("paperless") | not) | select(.key != "pg-paperless"))' \
  ~/.local/share/irl/bw-sync-state.json > /tmp/state-new.json
mv /tmp/state-new.json ~/.local/share/irl/bw-sync-state.json

# Or nuke the whole state file (forces a full re-sync of every item)
mv ~/.local/share/irl/bw-sync-state.json ~/.local/share/irl/bw-sync-state.json.bak
./scripts/bw-sync.sh --target both
```

## Generic failure modes

### "BW_SESSION is not set or expired"

```bash
# Re-unlock
export BW_SESSION=$(bw unlock --raw)
# Then re-run sync
./scripts/bw-sync.sh --target both
```

If your shell doesn't have `BW_SESSION` set in its env, the script
resolves it from fnox (`fnox get BW_SESSION`, age-encrypted), then falls
back to the fish `bw-unlock` cache at `~/.bw_session`. If the session is
stale (BW vault re-locked since), run `bw-unlock` and re-seed fnox:
`fnox set BW_SESSION --provider age -g`. Easiest: run via
`mise run secrets:sync`, which wraps the script in `fnox exec`.

### "ansible-vault: ERROR! The vault password file was not provided"

The `bw-sync.sh` ansible target needs ansible-vault available and
configured. Check:

```bash
which ansible-vault
echo "$ANSIBLE_VAULT_PASSWORD_FILE"
ls -la "$ANSIBLE_VAULT_PASSWORD_FILE"
```

The vault password now comes from fnox via `ansible.cfg`
(`vault_password_file = ../scripts/vault-pass.sh`). `bw-sync.sh` itself
calls `ansible-vault` and resolves the password the same way. Ensure
fnox can resolve it and `BW_SESSION` is available:

```bash
cd ~/projects/infinite-room-labs/infinite-room-labs-infra
BW_SESSION="$(fnox get BW_SESSION)" fnox get ANSIBLE_VAULT_PASSWORD >/dev/null && echo OK
mise run secrets:sync   # wraps bw-sync.sh in fnox exec
```

### "kubectl: command not found" during k8s sync

The script's k8s sync target needs `kubectl` and a working kubeconfig
pointing at the homelab. Check:

```bash
which kubectl
kubectl --kubeconfig ~/.kube/homelab.yaml get ns irl
```

The kubeconfig path is configurable via `targets.kubernetes.kubeconfig`
in `bw-sync-config.yaml` (default: `~/.kube/homelab.yaml`).

### Item exists in BW but the script reports "no password found"

The script reads `.login.password` from the BW item JSON. If the BW
item is a Secure Note (`type: 2`) instead of a Login (`type: 1`), or
the password field is empty, the read returns null and the script
errors out for that item.

```bash
# Inspect the item
bw get item <bw_item_name> 2>/dev/null | jq '{name, type, hasPassword: (.login.password != null)}'
```

Fix: re-create the BW item as a Login (`type: 1`) with the value in
the password field. The skill `manage-secrets` has the canonical
creation pattern.

### A new BW item is in the config but bw-sync skips it silently

Check that the item exists with the EXACT name in the config:

```bash
# What bw-sync expects
yq '.secrets[] | select(.bw_item == "<your_item>")' scripts/bw-sync-config.yaml

# What's actually in BW
bw list items --search "<your_item>" 2>/dev/null | jq '.[] | {name, id}'
```

A common mistake is having `paperless-admin` in BW but
`paperless-admin-password` in the config (or vice versa). Both must
match exactly.

### Vault decrypt fails after a sync

```
ERROR! Decryption failed (no vault secrets were found that could decrypt) on vault.yml
```

The sync wrote a fresh vault.yml with a different vault password than
the one your ansible config expects. Check:

```bash
# What the sync used
bw get password ansible-vault-password | wc -c

# What ansible expects
cat "$ANSIBLE_VAULT_PASSWORD_FILE" | wc -c
```

If these differ, either:
- The `ansible-vault-password` BW item was rotated, but the local
  `~/.secrets/ansible-vault-password` (or wherever ANSIBLE_VAULT_PASSWORD_FILE
  points) wasn't updated
- The local password file was edited manually and now disagrees with BW

Fix: copy the BW value to the local file:

```bash
bw get password ansible-vault-password > ~/.secrets/ansible-vault-password
chmod 600 ~/.secrets/ansible-vault-password
```

Then re-run the sync.

## General debugging tips

### Always start with a dry run

`--dry-run` is fast, safe, and shows you what the real run would do.
Never debug bw-sync issues by running the real sync first.

### Compare state file scoping

Healthy state files have keys prefixed with `ansible:` or `k8s:`:

```bash
jq 'keys' ~/.local/share/irl/bw-sync-state.json | head -20
```

Mixed unscoped + scoped means you have leftover state from before the
namespace fix. Not necessarily broken, but worth being aware of when
debugging "unchanged" reports.

### Use --verify-k8s for read-only confirmation

```bash
./scripts/bw-sync.sh --verify-k8s
```

This is the only sync mode that READS from K8s and compares against
BW. Use it after a rotation to confirm everything actually landed.

### Sync metrics

The script writes Prometheus metrics to
`~/.local/share/irl/irl_secrets.prom` (or `/var/lib/prometheus/node-exporter/`
if writable). The metrics include rotation age per item and pass/fail
counts per sync. Useful for hooking into Grafana alerts:

```bash
cat ~/.local/share/irl/irl_secrets.prom
```

## Escalation

If a sync is failing and the above doesn't help, capture the full state:

```bash
mkdir -p /tmp/bw-sync-debug
./scripts/bw-sync.sh --dry-run --target both 2>&1 > /tmp/bw-sync-debug/dryrun.log
cp ~/.local/share/irl/bw-sync-state.json /tmp/bw-sync-debug/state.json
cp scripts/bw-sync-config.yaml /tmp/bw-sync-debug/config.yaml
bw status > /tmp/bw-sync-debug/bw-status.json
ls -la "$ANSIBLE_VAULT_PASSWORD_FILE" >> /tmp/bw-sync-debug/env.txt
echo "ANSIBLE_VAULT_PASSWORD_FILE=$ANSIBLE_VAULT_PASSWORD_FILE" >> /tmp/bw-sync-debug/env.txt
```

Then read `/tmp/bw-sync-debug/dryrun.log` carefully for any non-`unchanged`
status on items that should be updating, and check the state.json for
unscoped or stale entries.

## See Also

- `scripts/bw-sync.sh` -- the script source (read it; it's well-commented)
- `scripts/bw-sync-config.yaml` -- the secret-to-target mapping
- `rotate-secrets.md` -- how to rotate a secret end-to-end
- The `manage-secrets` skill in `.claude/skills/manage-secrets/SKILL.md`
