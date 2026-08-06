# Runbook: Palworld Server Down / Degraded

## Severity: LOW (game server, no downstream dependents)

Palworld runs in the `irl` namespace as a single Deployment (`palworld`,
thijsvanloef/palworld-server-docker) on the `palworld-data-pvc` ZFS PVC.
Players connect from the LAN at `192.168.2.2:30211` (Steam Deck, no Tailscale)
or the tailnet at `100.86.213.22:30211`. Game traffic is UDP-only via NodePort
30211; RCON (25575) and the REST API (8212) are pod-internal, never exposed.

## Detection

- Game client cannot direct-connect / connection timeout
- Pod not Ready: `kubectl get pods -n irl -l app.kubernetes.io/name=irl-palworld`
- The game port is UDP, so `nc -vz` is useless; the pod's readiness (REST API
  TCP 8212) is the honest liveness signal

## Assessment

```bash
kubectl get pods -n irl -l app.kubernetes.io/name=irl-palworld
kubectl logs -n irl deploy/palworld --tail=50
kubectl get pvc -n irl palworld-data-pvc   # must be Bound
kubectl get svc -n irl palworld -o wide     # NodePort 30211/udp
kubectl top pod -n irl -l app.kubernetes.io/name=irl-palworld  # memory leak check
```

## Common Causes and Fixes

### Pod stuck in startup for a long time
Normal after image bump or cold volume: SteamCMD pulls the multi-Gi server
install before anything listens, and the startupProbe budget is 30 minutes.
Watch progress:

```bash
kubectl logs -n irl deploy/palworld -f
```

Only intervene if logs show SteamCMD erroring/looping (disk full, Steam CDN
issues). Check space: `ssh homelab-ts "zfs list main/palworld-data"`.

### OOMKilled / creeping memory
Palworld's server has a well-known memory leak. Mitigations already in place:
daily 5 AM ET auto-reboot (RCON broadcast + save first; skipped if players are
online) and a 16Gi limit. If it OOMs mid-day anyway, a pod restart is safe --
RCON-enabled shutdown saves first:

```bash
kubectl rollout restart -n irl deploy/palworld
```

If OOMs become routine, raise the limit in `ansible/helm/palworld/values.yaml`
or set `AUTO_REBOOT_EVEN_IF_PLAYERS_ONLINE: "true"` via `extraEnv`.

### Game updated on clients, server still on old version
Clients auto-update; the server updates on boot (`UPDATE_ON_BOOT=true`), so a
restart usually fixes version-mismatch joins. The *image* is pinned separately:
bump `image.tag` in `ansible/helm/palworld/values.yaml` (check
https://hub.docker.com/r/thijsvanloef/palworld-server-docker/tags) when the
wrapper itself needs updating.

### Reachable on tailnet but not from LAN
Two layers must both allow LAN traffic; check both:

1. **nftables allowlist** (default-drop for LAN; `tailscale0` is accepted
   unconditionally): 30211 in `irl_firewall_allowed_udp_ports`
   (`ansible/inventory/group_vars/homelab/main.yml`); re-run the security
   playbook. WARNING: re-applying nftables flushes libvirt NAT rules --
   restart libvirt networks after if VMs lose connectivity.
2. **NetworkPolicy** `allow-palworld-game-lan` (k3s.yml, kube-router
   enforced). The namespace is default-deny + allow-ingress-tailscale;
   NodePort traffic hits netpol with its ORIGINAL LAN source IP (masquerade
   happens post-filter), so without this policy LAN clients time out while
   tailnet clients work -- exactly this signature. Reapply:
   `uv run ansible-playbook playbooks/k3s.yml --tags palworld`.

### Permission denied on /palworld
Dataset ownership regressed (must be 1000:1000; fsGroup does not apply to
hostPath PVs): re-run `playbooks/zfs.yml --tags palworld`.

### RCON / graceful save not working
`ADMIN_PASSWORD` comes from Secret `palworld-secrets` (bw-sync item
`palworld-admin-password`). Env vars inject at container start only -- after
rotating the secret, restart the pod. Test RCON:

```bash
kubectl -n irl exec deploy/palworld -- rcon-cli ShowPlayers
```

## Full Redeploy

```bash
cd ansible/
uv run ansible-playbook playbooks/helm-deploy.yml --tags palworld
```

Chart is pinned (`irl/irl-palworld` 0.1.0) and data lives on a retained static
PV (`pv-palworld-data`), so a redeploy or full release delete/reinstall does
not touch the saves. First boot after reinstall re-runs the SteamCMD pull only
if the server install is missing.

## Data Recovery

Saves live at `/palworld/Pal/Saved/` on the `main/palworld-data` dataset,
snapshotted hourly by sanoid (`service_data` template). The image also keeps
its own tar backups in `/palworld/backups/` (daily, 30-day retention).

Quick version: scale to 0, copy the save directory out of
`/media/root/storage1/palworld-data/.zfs/snapshot/<snap>/Pal/Saved/`, chown
1000:1000, scale back to 1. Or untar one of the image's own backups from
`/palworld/backups/`.

## Disaster Recovery (pool or node loss)

Sanoid snapshots live on the same RAIDZ1 pool -- they do not survive pool
loss. Until an off-box backup CronJob exists, periodically pull saves off the
box. Rebuild order from a clean slate:

```bash
cd ansible/
uv run ansible-playbook playbooks/zfs.yml --tags palworld       # dataset + chown
uv run ansible-playbook playbooks/k3s.yml                       # PV + netpol
uv run ansible-playbook playbooks/security-hardening.yml        # nftables 30211/udp
mise run secrets:sync                                           # palworld-secrets
uv run ansible-playbook playbooks/helm-deploy.yml --tags palworld
```

Then restore saves per above. NOTE: security-hardening flushes libvirt NAT
rules -- restart the `irl-vms` network afterwards if VMs lose connectivity.
