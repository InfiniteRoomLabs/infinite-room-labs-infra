# Runbook: Satisfactory Server Down / Degraded

## Severity: LOW (game server, no downstream dependents)

Satisfactory runs in the `irl` namespace as a single Deployment
(`satisfactory`, wolveix/satisfactory-server) on the `satisfactory-data-pvc`
ZFS PVC. Players connect from the LAN at `192.168.2.2:30777` (Steam Deck, no
Tailscale) or the tailnet at `100.86.213.22:30777`. There is no HTTP route --
game traffic only, via NodePorts 30777 (tcp+udp) and 30888 (tcp).

## Detection

- Game client "Server offline" / connection timeout in Server Manager
- `nc -vz 192.168.2.2 30888` fails (messaging port is the honest liveness signal)
- Pod not Ready: `kubectl get pods -n irl -l app.kubernetes.io/name=irl-satisfactory`

## Assessment

```bash
kubectl get pods -n irl -l app.kubernetes.io/name=irl-satisfactory
kubectl logs -n irl deploy/satisfactory --tail=50
kubectl get pvc -n irl satisfactory-data-pvc   # must be Bound
kubectl get svc -n irl satisfactory -o wide     # NodePorts 30777/30888
```

## Common Causes and Fixes

### Pod stuck in startup for a long time
Normal after image bump or cold volume: SteamCMD pulls ~10Gi before anything
listens, and the startupProbe budget is 30 minutes. Watch progress:

```bash
kubectl logs -n irl deploy/satisfactory -f
```

Only intervene if logs show SteamCMD erroring/looping (disk full, Steam CDN
issues). Check space: `ssh homelab-ts "zfs list main/satisfactory-config"`.

### Game updated on clients, server still on old version
Clients auto-update; the server image is pinned. Symptom: version mismatch on
join. Fix: bump `image.tag` in `ansible/helm/satisfactory/values.yaml` (check
https://hub.docker.com/r/wolveix/satisfactory-server/tags) and redeploy.

### Reachable on tailnet but not from LAN
nftables allowlist regressed (default-drop for LAN, `tailscale0` is accepted
unconditionally). Verify 30777 tcp+udp and 30888 tcp are in
`irl_firewall_allowed_tcp_ports` / `_udp_ports`
(`ansible/inventory/group_vars/homelab/main.yml`) and re-run the security
playbook. WARNING: re-applying nftables flushes libvirt NAT rules -- restart
libvirt networks after if VMs lose connectivity.

### Permission denied on /config
Dataset ownership regressed (must be 1000:1000; fsGroup does not apply to
hostPath PVs): re-run `playbooks/zfs.yml --tags satisfactory`.

### Save corruption / lost progress
The server keeps rotating autosaves (`AUTOSAVENUM: 5`) in
`/config/saved/server/`. Copy a known-good autosave over, or recover from a
ZFS snapshot of `main/satisfactory-config`.

## Full Redeploy

```bash
./ansible/run-ansible.sh playbook playbooks/helm-deploy.yml --tags satisfactory
```

Chart is pinned (`irl/irl-satisfactory` 0.1.0) and data lives on a retained
static PV (`pv-satisfactory-config`), so a redeploy or full release
delete/reinstall does not touch the save. First boot after reinstall re-runs
the SteamCMD pull only if gamefiles are missing.

## Data Recovery

Saves live at `/config/saved/server/` on the `main/satisfactory-config`
dataset. Recover via ZFS snapshot (`zfs list -t snapshot | grep satisfactory`)
or re-upload a local `.sav` with:

```bash
kubectl -n irl cp ./MySave.sav <pod>:/config/saved/server/MySave.sav
```

The Session Name is baked inside the `.sav` -- renaming the file changes
nothing. The server must be re-claimed (admin password) only if
`/config/saved` itself was wiped.
