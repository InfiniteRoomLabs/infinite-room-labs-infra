# Runbook: WotLK (AzerothCore) Server Down / Degraded

## Severity: LOW (game server, no downstream dependents)

WotLK runs in the `irl` namespace as three workloads from the `irl-wotlk` chart: `wotlk-mysql` (StatefulSet, MySQL 8.4, PVC `wotlk-db-pvc`), `wotlk-authserver` (Deployment) and `wotlk-worldserver` (Deployment, mod-playerbots fork, PVC `wotlk-data-pvc` for client data). Players connect over the tailnet only: `realmlist.wtf` -> `wow.lab.infiniteroomlabs.cloud:30724`, then the authserver hands them `100.86.213.22:30085`. There is deliberately no LAN path (no nftables entry, no LAN NetworkPolicy).

Images are node-local: `irl/ac-wotlk-{authserver,worldserver,db-import,client-data}:<tag>` live only in the homelab's k3s containerd, imported by `scripts/wotlk-build-images.sh`.

## Detection

- Client shows "Unable to connect" at login: authserver (30724) unreachable
- Client lists the realm but hangs on "Connecting" / "Logging in to game server": worldserver (30085) unreachable or realmlist row wrong
- `kubectl get pods -n irl -l app.kubernetes.io/instance=wotlk` shows something not Running

## Assessment

```bash
kubectl get pods -n irl -l app.kubernetes.io/instance=wotlk
kubectl logs -n irl deploy/wotlk-worldserver --tail=50
kubectl logs -n irl deploy/wotlk-authserver --tail=50
kubectl get pvc -n irl wotlk-db-pvc wotlk-data-pvc      # both Bound
kubectl get svc -n irl wotlk-auth wotlk-world -o wide   # NodePorts 30724 / 30085
nc -zv 100.86.213.22 30724; nc -zv 100.86.213.22 30085  # from a tailnet host
kubectl top pod -n irl -l app.kubernetes.io/instance=wotlk
```

## Common Causes and Fixes

### Worldserver pod stuck in Init for a long time
Normal on first boot or after a data wipe: the `client-data` initContainer downloads ~15Gi and `db-import` applies the full world DB. Budget is 30-60 minutes. Watch:

```bash
kubectl logs -n irl deploy/wotlk-worldserver -c client-data -f
kubectl logs -n irl deploy/wotlk-worldserver -c db-import -f
```

Only intervene if a container is erroring or looping (disk full: `ssh homelab-ts "zfs list main/wotlk-data main/wotlk-db"`).

### ErrImageNeverPull / ImagePullBackOff
The node lost the imported images (k3s image GC, node rebuild). Re-import:

```bash
./scripts/wotlk-build-images.sh          # rebuild (cache is warm) + import
# or, if /var/lib/rancher/k3s/agent/images/ac-wotlk.tar still exists on the node:
ssh homelab-ts "sudo k3s ctr images import /var/lib/rancher/k3s/agent/images/ac-wotlk.tar"
```

Make sure the tag printed by the script matches `image.tag` in `ansible/helm/wotlk/values.yaml`.

### Realm listed but cannot enter world
`acore_auth.realmlist` must advertise the Tailscale IP and the worldserver NodePort. Check and fix:

```bash
kubectl exec -n irl wotlk-mysql-0 -- bash -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" acore_auth -e "SELECT id,name,address,port FROM realmlist"'
# expected: 1 | Infinite Room | 100.86.213.22 | 30085
```

The `db-import` initContainer re-stamps this row on every worldserver restart, so a `kubectl rollout restart deploy/wotlk-worldserver -n irl` also fixes it.

### Authserver CrashLooping / stuck in Init
Its `wait-for-auth-db` initContainer blocks until `acore_auth.realmlist` exists, i.e. until the worldserver pod's `db-import` finished. If mysql itself is down, fix that first (`kubectl logs -n irl wotlk-mysql-0`).

### OOMKilled worldserver
1600-2000 bots need ~8-10Gi. Limit is 16Gi. Lower `worldserver.bots.min/max` in `ansible/helm/wotlk/values.yaml` and redeploy, or raise the limit if the node has room (`kubectl top nodes`).

### Need to create or fix an account
The worldserver console is the only interface (SOAP is off):

```bash
./scripts/wotlk-console.sh        # wraps kubectl attach; Ctrl-] detaches, Ctrl-C is swallowed
account create <user> <password>
account set gmlevel <user> 3 -1
```

Never use bare `kubectl attach` + Ctrl-C: the worldserver treats SIGINT as "shut down the world".

## Recovery

```bash
mise run ansible -- playbook playbooks/helm-deploy.yml --tags wotlk   # redeploy
kubectl rollout restart -n irl deploy/wotlk-worldserver              # restart only
```

Characters live in `acore_characters` on `wotlk-db-pvc` (ZFS `main/wotlk-db`). Snapshot before anything destructive: `ssh homelab-ts "sudo zfs snapshot main/wotlk-db@pre-$(date +%F)"`.
