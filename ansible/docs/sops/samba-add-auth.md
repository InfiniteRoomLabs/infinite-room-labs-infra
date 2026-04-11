# SOP: Hardening Samba From Guest Mode to Authenticated

The initial Samba deployment for the `paperless-consume` share is
intentionally unauthenticated (`guest ok = yes`, `guest only = yes`) to
keep onboarding friction at zero during the first wave of doc migration.
This SOP walks through replacing the guest model with a single dedicated
user + password, stored in Bitwarden and synced via the existing
bw-sync.sh pipeline.

The hardening is referenced inline as a TODO in:
- `ansible/inventory/group_vars/homelab/main.yml` (in the `irl_samba_shares` comment block)
- `ansible/templates/smb.conf.j2` (in the global section comment)

Run this once the initial document backlog is migrated and any future
client setups can afford the extra "enter the password once" step.

## Prerequisites

- Samba is currently running in guest mode (verify: `testparm -s 2>/dev/null | grep guest`)
- Bitwarden CLI is unlocked (`bw status` shows `unlocked`)
- bw-sync.sh works (verify with `--dry-run --target ansible`)
- All SMB clients (e.g. Windows machines configured per
  `setup-windows-paperless-ingestion.md`) can be touched to update their
  cached credentials

## Step 1: Create the Bitwarden item

```bash
FOLDER_ID=$(bw list folders 2>/dev/null \
  | jq -r '.[] | select(.name == "IRL/Services/Paperless") | .id')

# Generate a strong password (32 chars, no special chars that confuse Windows)
PW=$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)

jq -n --arg name "samba-paperless-scan" --arg pw "$PW" --arg folder "$FOLDER_ID" \
  '{type:1, name:$name, folderId:$folder,
    notes:"Samba password for the paperlessscan system user. Used by Windows clients to mount \\\\192.168.2.2\\paperless-consume. Consumed via bw-sync -> vault_samba_paperless_password (host-only, k8s_secret null).",
    login:{username:"paperlessscan", password:$pw, uris:[]}}' \
| bw encode | bw create item 2>/dev/null \
| jq -r '"Created: \(.name) | ID: \(.id) | length: \(.login.password | length) chars"'

unset PW
bw sync 2>&1 | tail -1
```

## Step 2: Add the bw-sync mapping

Append to `scripts/bw-sync-config.yaml` in the paperless section:

```yaml
  - bw_item: "samba-paperless-scan"
    ansible_var: "vault_samba_paperless_password"
    k8s_secret: null
    k8s_key: null
```

`k8s_secret: null` because the Samba password stays host-only -- it
never needs to reach the cluster. Same pattern as `tailscale-api-key`
and `ansible-vault-password`.

Dry-run + sync:

```bash
./scripts/bw-sync.sh --dry-run --target ansible
./scripts/bw-sync.sh --target ansible
```

The k8s sync target doesn't need to run since this secret has no k8s
target. But running `--target both` is harmless.

## Step 3: Update the playbook to manage the system user + smbpasswd

Edit `ansible/playbooks/samba.yml` and add these tasks AFTER the
"Ensure paperless-consume directory exists" task and BEFORE the
"Template /etc/samba/smb.conf" task:

```yaml
    - name: Create paperlessscan system user
      ansible.builtin.user:
        name: "{{ irl_samba_user }}"
        system: true
        shell: /usr/sbin/nologin
        create_home: false
        state: present

    - name: Check if Samba user is in tdbsam
      ansible.builtin.command: "pdbedit -L -u {{ irl_samba_user }}"
      register: pdbedit_result
      changed_when: false
      failed_when: false

    - name: Set Samba password (initial provisioning)
      ansible.builtin.shell:
        cmd: |
          set -e
          ( echo "{{ vault_samba_paperless_password }}";
            echo "{{ vault_samba_paperless_password }}" ) \
          | smbpasswd -a -s "{{ irl_samba_user }}"
      when: pdbedit_result.rc != 0 or (irl_samba_force_password_reset | default(false))
      no_log: true
      changed_when: true
```

Add the `irl_samba_user` variable to
`ansible/inventory/group_vars/homelab/main.yml`:

```yaml
irl_samba_user: "paperlessscan"
```

To rotate the password later, run:
```bash
ansible-playbook playbooks/samba.yml --tags samba -e irl_samba_force_password_reset=true
```

## Step 4: Update smb.conf.j2 to require authentication

In `ansible/templates/smb.conf.j2`, change the `[global]` section:

```diff
-    map to guest = Bad User
-    guest account = nobody
+    map to guest = Never
```

And update the share-loop block:

```diff
 [{{ share.name }}]
     comment = {{ share.comment }}
     path = {{ share.path }}
-    guest ok = yes
-    guest only = yes
+    valid users = {{ irl_samba_user }}
+    write list = {{ irl_samba_user }}
     force user = {{ share.force_user }}
     force group = {{ share.force_group }}
```

## Step 5: Apply the changes

```bash
cd ansible
direnv exec . uv run ansible-playbook playbooks/samba.yml --tags samba
```

Expected output: handler restart of smbd + nmbd, no errors.

## Step 6: Verify with smbclient

```bash
SAMBA_PW=$(bw get password samba-paperless-scan)
smbclient -L //192.168.2.2/ -U paperlessscan%${SAMBA_PW}
smbclient //192.168.2.2/paperless-consume -U paperlessscan%${SAMBA_PW} -c "ls"
unset SAMBA_PW
```

Both should succeed. A guest connection should now FAIL:

```bash
smbclient -L //192.168.2.2/ -N
# Expected: NT_STATUS_LOGON_FAILURE or NT_STATUS_ACCESS_DENIED
```

## Step 7: Update Windows clients

Each Windows machine that previously mounted via guest needs to be
re-configured with the new credentials. On each machine:

```powershell
# Drop the old guest mapping
net use Z: /delete

# Optionally revert the AllowInsecureGuestAuth tweak (no longer needed with auth)
reg add HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters /v AllowInsecureGuestAuth /t REG_DWORD /d 0 /f
Set-SmbClientConfiguration -RequireSecuritySignature $true -Force
Restart-Service LanmanWorkstation -Force

# Re-mount with credentials
net use Z: \\192.168.2.2\paperless-consume /user:paperlessscan <password> /persistent:yes
```

Or via File Explorer's "Map network drive" wizard, this time CHECKING
"Connect using different credentials" and entering `paperlessscan` +
the password from BW.

For convenience, the password can be saved to Windows Credential
Manager so it doesn't need to be re-entered after a reboot:

```powershell
cmdkey /add:192.168.2.2 /user:paperlessscan /pass:<password>
```

## Optional: Tighten hosts_allow at the same time

While you're hardening anyway, consider narrowing the allowed networks
in `ansible/inventory/group_vars/homelab/main.yml`:

```yaml
irl_samba_shares:
  - name: "paperless-consume"
    # ... other fields ...
    hosts_allow:
      - "192.168.2.42"   # specific Windows laptop IP only
      - "127.0.0.1"
      # drop the broad 192.168.2.0/24 and 100.64.0.0/10 entries
```

The downside is that DHCP lease changes will lock clients out. Worth
it for a long-lived static-IP machine; not worth it for a laptop that
roams.

## Rollback

If something goes wrong and you need to fall back to guest mode quickly:

```bash
git revert <commit-sha-of-the-hardening-commit>
ansible-playbook playbooks/samba.yml --tags samba
```

Or manually edit `smb.conf.j2` back to the guest settings and re-run.
The Bitwarden item and bw-sync mapping can stay in place -- they don't
hurt anything.

## See Also

- `ansible/playbooks/samba.yml` -- the playbook this SOP modifies
- `ansible/templates/smb.conf.j2` -- the smb.conf template
- `scripts/bw-sync-config.yaml` -- secret mapping config
- `setup-windows-paperless-ingestion.md` -- the Windows-side end-user setup
- `rotate-secrets.md` -- general secret rotation pattern
