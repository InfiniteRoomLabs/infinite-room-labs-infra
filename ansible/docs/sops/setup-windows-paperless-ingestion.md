# SOP: Setting Up a Windows Machine for Paperless Ingestion

Walks through configuring a Windows 10/11 machine to mount the homelab's
`paperless-consume` SMB share as a network drive so that scanning software
(HP Smart, Brother iPrint&Scan, NAPS2, ScanSnap, etc.) can save scanned
PDFs directly into Paperless-ngx without manual file shuffling.

This is a one-time per-machine setup. After completion, scanned documents
appear in Paperless within ~3 minutes of being saved to the network drive.

## Prerequisites

- The Windows machine is on the same home LAN as the homelab (same Wi-Fi
  SSID, not a guest network or hotspot)
- The user has local admin rights on the Windows machine (needed for the
  one-time registry tweak)
- Samba is deployed on the homelab (`ansible-playbook playbooks/samba.yml --tags samba`)
- Port 445/tcp is open in the homelab firewall (`445` in `irl_firewall_allowed_tcp_ports`)
- Verified: `nc -zv 192.168.2.2 445` succeeds from somewhere on the LAN

## Why the registry tweak is needed

The homelab Samba share is **intentionally unauthenticated** (guest mode)
during the initial-rollout phase to keep ingestion friction at zero. The
security boundary is the home LAN topology + the smb.conf `hosts allow`
list, not user passwords.

Modern Windows (10 since v1709, all 11 builds) blocks unauthenticated
guest SMB connections by default with the message:

> You can't access this shared folder because your organization's
> security policies block unauthenticated guest access.

Windows 11 24H2+ also enables `RequireSecuritySignature` by default, which
blocks any connection that can't sign messages -- guest sessions can't sign,
so they're refused even with `AllowInsecureGuestAuth` enabled.

Both are reversible client-side settings. They lower the security posture
of the Windows machine *for SMB only* (other protocols are unaffected).

When the homelab Samba share is hardened later (see
`samba-add-auth.md`), revert these client tweaks and supply credentials
instead.

## Steps

### 1. Open an Admin Terminal

Right-click the Start button -> **Terminal (Admin)** -> click Yes on the
UAC prompt. On older Windows builds the menu item may be **Windows
PowerShell (Admin)** -- either works.

### 2. Allow guest SMB and disable required signing

Paste both lines, hit Enter:

```powershell
reg add HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters /v AllowInsecureGuestAuth /t REG_DWORD /d 1 /f
Set-SmbClientConfiguration -RequireSecuritySignature $false -Force
```

Expected output:
- `The operation completed successfully.` from `reg add`
- A confirmation prompt from `Set-SmbClientConfiguration` -- type `Y` and
  Enter, or use `-Force` to skip the prompt (already in the command above)

Then restart the Workstation service so the changes take effect without
a reboot:

```powershell
Restart-Service LanmanWorkstation -Force
```

If `Restart-Service` complains that other services depend on it, accept
the restart of dependents (`-Force` should handle this automatically).

### 3. Map the network drive

#### Option A: GUI (preferred for non-technical users)

1. Open **File Explorer**
2. Click **This PC** in the left sidebar
3. Click the **`...`** menu in the toolbar -> **Map network drive**
   - On Windows 10 the menu item is in the ribbon under the **Computer**
     tab as **Map network drive**
4. **Drive letter**: pick `Z:` (or any free letter)
5. **Folder**: `\\192.168.2.2\paperless-consume`
6. Check **Reconnect at sign-in**
7. **Uncheck** "Connect using different credentials" (leave it as guest)
8. Click **Finish**

The folder should open in a new window. If Windows prompts for
credentials, leave both username and password blank and click OK.

#### Option B: Single command (faster, same admin terminal)

```powershell
net use Z: \\192.168.2.2\paperless-consume /persistent:yes
```

Expected output: `The command completed successfully.`

### 4. Verify the mount

```powershell
dir Z:\
```

Should list the contents of the share (likely empty on a fresh setup).

Drop a test file:

```powershell
"smb-probe-$(Get-Date -Format 'yyyyMMdd-HHmmss')" | Out-File Z:\smb-probe.txt
dir Z:\smb-probe.txt
```

The file should appear with the expected size. Then SSH into the homelab
(or ask whoever has SSH access to the homelab) and confirm:

```bash
sudo stat /media/root/storage1/nfs-share/paperless-consume/smb-probe.txt
```

The output should show `Uid: ( 1000/dataplicity)` and `Gid: ( 1000/dataplicity)`.
That confirms the SMB write went through and the `force user/group` mapping
is intact -- which is what Paperless needs to read the file back through
its hostPath mount.

Clean up the probe file:

```powershell
del Z:\smb-probe.txt
```

### 5. Configure the scanning software

The exact steps depend on the scanner software, but the pattern is the
same: tell the app to save its output to the mapped drive.

**HP Smart (most HP scanners)**:
1. Open HP Smart
2. Click the scanner tile
3. Click **Settings** (gear icon)
4. **File save location** -> **Browse** -> select `Z:\` (or whatever
   drive letter you used)
5. Save the setting as a preset if the app supports it

If HP Smart refuses to accept a network drive (some older versions do
this), use the UNC path directly:

`\\192.168.2.2\paperless-consume\`

Or have it save locally and use a Windows scheduled task to move files
into the share -- but this is rare; most modern scanner software handles
network drives natively.

**Brother iPrint&Scan**: Settings -> Save to file -> change destination
folder to `Z:\`

**NAPS2**: File -> Settings -> Save -> Save Path -> `Z:\$(YYYY)-$(MM)-$(DD)_$(hh)$(mm)$(ss).pdf`

**ScanSnap Home**: ScanSnap Home -> Settings -> Manage Profiles -> select
profile -> Save tab -> change "Save to" path

### 6. Test end-to-end

1. Scan a real document via the scanning software
2. After it saves, check Paperless at https://archives.lab.infiniteroomlabs.cloud
3. Within ~3 minutes the document should appear in the inbox
4. The Paperless polling consumer waits for the file to be stable for
   ~2.5 minutes (30s polling interval x 5 retries) before ingesting,
   so don't expect instant appearance

If the file is still in `Z:\` after 5+ minutes, check the Paperless
consumer logs (see Troubleshooting below).

## Troubleshooting

### "You can't access this shared folder because of organization security policies"

The registry tweak from step 2 didn't take effect. Try in order:

1. Confirm the reg add ran without errors:
   ```powershell
   reg query HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters /v AllowInsecureGuestAuth
   ```
   Expected: `AllowInsecureGuestAuth    REG_DWORD    0x1`
2. Reboot the Windows machine. Some Windows builds don't pick up the
   change until reboot even after restarting LanmanWorkstation.
3. If the machine is joined to a domain (work laptop), Group Policy
   may be re-locking the setting. Check `gpresult /h gpresult.html`
   for any policy enforcing `LanmanWorkstation\Parameters\AllowInsecureGuestAuth = 0`.

### "The network path was not found"

The Windows machine can't reach `192.168.2.2:445`. Check:

1. The machine is on the home Wi-Fi, not a guest network or mobile hotspot:
   ```powershell
   ipconfig | findstr IPv4
   ```
   Expected: an IP in `192.168.2.x`. If you see `192.168.4.x` or similar,
   you're on the wrong SSID.
2. The homelab is up: ping `192.168.2.2` from the Windows machine
3. Port 445 is reachable:
   ```powershell
   Test-NetConnection -ComputerName 192.168.2.2 -Port 445
   ```
   Expected: `TcpTestSucceeded : True`. If False, the homelab firewall
   doesn't have 445 open -- run `ansible-playbook playbooks/security-hardening.yml --tags security` from the infra repo.

### "Access is denied" when writing to the drive

Probably an issue on the homelab side, not Windows. Check:

```bash
sudo testparm -s 2>/dev/null | grep -E "force user|guest|read only"
```

The `paperless-consume` share should show `force user = dataplicity`,
`force group = dataplicity`, `guest ok = Yes`, `read only = No`. If
`force user = 1000` (the literal string), it'll fail with NT_STATUS
errors -- Samba expects a username, not a UID. Re-run the samba
playbook to fix.

### Scanned files appear on the share but not in Paperless

The Paperless consumer is probably either down or has the file stuck
in a polling-retry loop:

```bash
kubectl logs -n irl deploy/paperless | grep -iE "consume|new doc|fail"
```

Common causes:
- File is still being written when Paperless polls. Wait the full
  2.5-minute stability window and check again.
- File is a non-PDF format Paperless can't process. Check the file
  extension matches one Paperless accepts (.pdf, .png, .jpg, .tiff).
- File is 0 bytes. Some scanner apps create the destination file
  before writing data -- if the scan failed mid-way, an empty file
  may sit on the share. Delete it and re-scan.

### Drive letter shows as disconnected (red X) after reboot

The "Reconnect at sign-in" checkbox didn't take. Re-map:

```powershell
net use Z: \\192.168.2.2\paperless-consume /persistent:yes
```

Or use Task Scheduler to run `net use` at logon -- some Windows builds
have a known bug where mapped drives don't reconnect on Wi-Fi-only machines
because the network isn't ready when the user signs in. The Microsoft
KB article `KB2980427` documents the workaround.

## Rollback / Cleanup

To remove the SMB mount and revert the registry tweaks on a Windows
machine that no longer needs the share:

```powershell
# Unmap the drive
net use Z: /delete

# Revert registry changes (Admin terminal)
reg add HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters /v AllowInsecureGuestAuth /t REG_DWORD /d 0 /f
Set-SmbClientConfiguration -RequireSecuritySignature $true -Force
Restart-Service LanmanWorkstation -Force
```

This restores the Windows defaults and removes the Paperless drive mapping.

## See Also

- `ansible/playbooks/samba.yml` -- the Samba server config that exposes the share
- `ansible/templates/smb.conf.j2` -- smb.conf template
- `samba-add-auth.md` -- future hardening: replace guest mode with auth
- `restore-paperless.md` -- DR procedure if Paperless data is lost
