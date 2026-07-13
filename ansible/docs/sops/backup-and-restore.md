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
