# SOP: Backup and Restore

## Automated Backups

ZFS snapshots are managed by sanoid:
- **Service data**: hourly (24 kept), daily (30), weekly (4), monthly (6)
- **Sacred data**: daily (30), weekly (8), monthly (12), yearly (2)
- **Logs**: daily (14), weekly (4)

## Manual ZFS Snapshot

```bash
# Create a manual snapshot
sudo zfs snapshot main/backups@manual-$(date +%Y%m%d-%H%M)

# List snapshots
sudo zfs list -t snapshot

# Rollback (DESTRUCTIVE -- rolls back to snapshot state)
sudo zfs rollback main/backups@snapshot-name
```

## PostgreSQL Backup

```bash
# Dump all databases
docker exec irl-postgres pg_dumpall -U postgres > /opt/irl/backups/pg-dump-$(date +%Y%m%d).sql

# Restore
cat pg-dump-YYYYMMDD.sql | docker exec -i irl-postgres psql -U postgres
```

## Full Service Backup

```bash
# Stop stack, snapshot ZFS, restart
cd /opt/irl/{stack}
sudo docker compose stop
sudo zfs snapshot main/backups@{stack}-$(date +%Y%m%d)
sudo docker compose start
```

## Karakeep

Two datasets, different value:
- `main/karakeep-data` -- **authoritative** (SQLite DB + archived pages +
  screenshots). Sanoid `service_data` template.
- `main/karakeep-meilisearch` -- rebuildable search index. Sanoid
  `large_assets` template (minimal retention); never restore-critical.

Restore bookmark data from a snapshot (k8s workload, not compose):

```bash
# Scale the app down so SQLite isn't written mid-rollback
kubectl scale -n irl deploy/karakeep --replicas=0

ssh homelab-ts "sudo zfs list -t snapshot main/karakeep-data | tail"
ssh homelab-ts "sudo zfs rollback main/karakeep-data@<snapshot>"  # DESTRUCTIVE

kubectl scale -n irl deploy/karakeep --replicas=1
```

After a data restore, rebuild search: karakeep UI -> Admin Settings ->
Background Jobs -> Reindex (or restart `statefulset/karakeep-meilisearch`
and reindex). Do NOT bother restoring the meilisearch dataset.

## Satisfactory

One dataset, `main/satisfactory-config` (sanoid `service_data`: hourly x24,
daily x30, weekly x4, monthly x6). Layout on the dataset:

- `saved/server/` -- **the only irreplaceable data**: session save + rotating
  autosaves (`AUTOSAVENUM: 5`) + `ServerSettings.*` (claim/admin password)
- `gamefiles/` -- ~10Gi, fully redownloadable via SteamCMD; never worth restoring
- `backups/`, `logs/` -- incidental

### Recover a save from backup (the common case)

Prefer pulling individual files out of a snapshot over `zfs rollback` -- a
rollback drags the 10Gi gamefiles back in time too and forces a SteamCMD
re-verify for nothing.

```bash
# Stop the server so it doesn't autosave over what you're restoring
kubectl scale -n irl deploy/satisfactory --replicas=0

# Pick a snapshot (hourly granularity)
ssh homelab-ts "sudo zfs list -t snapshot -o name,creation main/satisfactory-config | tail -30"

# Snapshots are browsable as read-only directories -- copy the save back
ssh homelab-ts "sudo ls /media/root/storage1/satisfactory-config/.zfs/snapshot/<snap>/saved/server/"
ssh homelab-ts "sudo cp /media/root/storage1/satisfactory-config/.zfs/snapshot/<snap>/saved/server/<file>.sav \
  /media/root/storage1/satisfactory-config/saved/server/ && \
  sudo chown 1000:1000 /media/root/storage1/satisfactory-config/saved/server/<file>.sav"

kubectl scale -n irl deploy/satisfactory --replicas=1
```

Then in-game: Server Manager -> Manage Saves -> load the restored save (and
re-set it as the Auto-Load Session if the name changed).

### Full-dataset rollback (config corruption, unknown blast radius)

```bash
kubectl scale -n irl deploy/satisfactory --replicas=0
ssh homelab-ts "sudo zfs rollback main/satisfactory-config@<snapshot>"  # DESTRUCTIVE
kubectl scale -n irl deploy/satisfactory --replicas=1
```

### Disaster recovery (dataset/pool lost)

Snapshots live on the same RAIDZ1 pool as the data -- a pool loss takes both.
Off-pool copies are manual for now (no Garage S3 CronJob yet): after
significant play sessions, pull a copy of the save off the box:

```bash
kubectl -n irl cp \
  $(kubectl get pod -n irl -l app.kubernetes.io/name=irl-satisfactory -o name | cut -d/ -f2):/config/saved/server \
  ./satisfactory-saves-$(date +%Y%m%d)
```

Rebuild from nothing:

1. `uv run ansible-playbook playbooks/zfs.yml --tags satisfactory` (dataset + chown)
2. `uv run ansible-playbook playbooks/k3s.yml` PV task (or apply `pv-satisfactory-config` manually)
3. `uv run ansible-playbook playbooks/helm-deploy.yml --tags satisfactory` (PVC + release)
4. First boot re-runs the SteamCMD pull (~10Gi, 10-30 min)
5. Copy saves back in (`kubectl cp <dir>/. <pod>:/config/saved/server/`), chown
   1000:1000 if needed, claim the server in-game, set admin password, load the
   save, re-set Auto-Load Session

The claim state (`ServerSettings.*`) rides along with `saved/` -- if it was
restored, no re-claim is needed.
