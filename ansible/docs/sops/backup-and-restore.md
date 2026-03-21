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
