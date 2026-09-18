# Runbook: WordPress (journal) Down / Degraded

## Severity: LOW (single-author blog, no downstream dependents)

WordPress runs in the `irl` namespace as two workloads from the `irl-wordpress` chart: `wordpress` (Deployment, official `wordpress:*-apache` image, PVC `wordpress-content` mounted at `/var/www/html`) and `wordpress-mariadb` (StatefulSet, PVC `wordpress-db` at `/var/lib/mysql`). Both PVCs are ZFS-backed hostPath PVs pinned to the `irl.dev/tier: data` node. The only way in is `https://journal.lab.infiniteroomlabs.cloud` -> Traefik `websecure` -> the chart's IngressRoute -> Service `wordpress:80`, and the name resolves only inside the tailnet (internal CoreDNS + Tailscale Split DNS).

Credentials: `wordpress-secrets` (`MARIADB_ROOT_PASSWORD`, `MARIADB_PASSWORD`), synced from Bitwarden by `scripts/bw-sync.sh`. The WordPress admin login is not in that Secret -- it lives in the database, created at install time.

## Detection

- `https://journal.lab.infiniteroomlabs.cloud` times out or returns 502/504: pod down, or Traefik has no healthy backend
- Page renders "Error establishing a database connection": MariaDB is down or the password no longer matches
- Redirect loop, or the site serves `http://` links: `WP_HOME`/`WP_SITEURL` are wrong (see below)
- `kubectl get pods -n irl -l app.kubernetes.io/instance=wordpress` shows something not Running

## Assessment

```bash
kubectl get pods -n irl -l app.kubernetes.io/instance=wordpress
kubectl logs -n irl deploy/wordpress --tail=50
kubectl logs -n irl sts/wordpress-mariadb --tail=50
kubectl get pvc -n irl wordpress-content wordpress-db          # both Bound
kubectl get ingressroute -n irl wordpress-http -o yaml | grep -A3 routes
curl -sI --resolve journal.lab.infiniteroomlabs.cloud:443:100.86.213.22 \
  https://journal.lab.infiniteroomlabs.cloud/                  # 302 -> install.php or 200
ssh homelab-ts "zfs list main/wordpress-content main/wordpress-db"   # quota headroom
```

## Common Causes and Fixes

### Pod stuck in Init (`wait-for-db`)
Expected while MariaDB starts; the initContainer polls `mariadb-admin ping` every 5s. If it never clears, MariaDB is the problem -- look there first. On first boot MariaDB initializes its datadir behind a startup probe with a 10-minute budget; do not kill the pod mid-init, a half-written `/var/lib/mysql` refuses every later start.

### "Error establishing a database connection"
The app password and the password stored inside MariaDB have diverged. `MARIADB_USER`/`MARIADB_PASSWORD` are only honoured on an **empty** datadir, so rotating the Bitwarden item and re-syncing does NOT change the DB. Either restore the old value, or change it in MariaDB to match:

```bash
kubectl exec -n irl wordpress-mariadb-0 -- bash -c \
  'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "ALTER USER '"'"'wordpress'"'"'@'"'"'%'"'"' IDENTIFIED BY '"'"'<new>'"'"'; FLUSH PRIVILEGES;"'
kubectl rollout restart -n irl deploy/wordpress
```

### Redirect loop or mixed http:// links
`WP_HOME`/`WP_SITEURL` come from `wordpress.siteUrl` in `ansible/helm/wordpress/values.yaml` via `WORDPRESS_CONFIG_EXTRA`, which the image eval()s per request -- fix the value and redeploy, no database surgery needed. If the site was reached once over plain http and WordPress wrote the wrong value into the `options` table, the config constants still win.

### 404 from Traefik / no route
```bash
kubectl get ingressroute -n irl wordpress-http
kubectl logs -n irl deploy/traefik --tail=50 | grep -i journal
```
The route is chart-owned; a failed `helm upgrade` is the usual cause. Redeploy (below).

### Uploads or plugin installs fail with a permissions error
`/var/www/html` must be writable by www-data (uid 33). The dataset is chowned by `zfs.yml`:

```bash
ansible-playbook playbooks/zfs.yml --tags wordpress    # re-applies the chown
```

### Plugin/theme installs hang or "could not connect"
The pod needs egress to the internet for wordpress.org. That is the namespace-wide `allow-egress-internet` NetworkPolicy:

```bash
kubectl get networkpolicy -n irl allow-egress-internet
```

### Nightly backup job failing
```bash
kubectl get jobs -n irl | grep wordpress-backup
kubectl logs -n irl job/wordpress-backup-<id> -c db-dump   # dump stage
kubectl logs -n irl job/wordpress-backup-<id> -c uploader   # S3 stage
```
The pod is deleted once the backoff limit is hit (restartPolicy OnFailure), so
grab logs while it runs, or re-create the job by hand and watch it. Common
causes: the `wordpress-backup-s3` Secret missing (bw-sync not run), the Garage
key losing its bucket grant, or the bucket hitting its 50GiB quota.

### Disk full
`main/wordpress-content` has a 20G quota (uploads) and `main/wordpress-db` 10G. Raise the quota in `irl_zfs_datasets` (`group_vars/all/main.yml`) and re-run `ansible-playbook playbooks/zfs.yml --tags datasets`.

## Backups and Restore

Two independent layers:

- **sanoid ZFS snapshots** of `main/wordpress-content` and `main/wordpress-db`
  (hourly 24 / daily 30 / weekly 4 / monthly 6). Fast, local, and useless if
  the pool dies. DB snapshots are crash-consistent, not quiesced -- InnoDB
  replays its redo log on restore.
- **Nightly CronJob `wordpress-backup`** into the Garage bucket
  `wordpress-backups` (IAM key `wordpress-backup`, read+write, 50GiB quota).
  `db/wordpress-db-<stamp>.sql.gz` is a point-in-time `mariadb-dump` pruned
  after 30 days; `wp-content/` is an incremental `aws s3 sync` mirror with no
  `--delete`, so it is never pruned and keeps files the live site dropped.

Check the last run:

```bash
kubectl get cronjob -n irl wordpress-backup
kubectl get jobs -n irl | grep wordpress-backup
kubectl logs -n irl job/wordpress-backup-<id> -c uploader
```

Run one on demand:

```bash
kubectl create job -n irl --from=cronjob/wordpress-backup wordpress-backup-manual
```

### List what is in the bucket

Everything below runs aws-cli in-cluster, because the Garage S3 API is
ClusterIP-only and the credentials live in a Secret:

```bash
kubectl run -n irl aws-shell --rm -it --restart=Never \
  --image=amazon/aws-cli:2.36.38 \
  --overrides='{"spec":{"containers":[{"name":"aws-shell","image":"amazon/aws-cli:2.36.38","stdin":true,"tty":true,"command":["/bin/sh"],"envFrom":[{"secretRef":{"name":"wordpress-backup-s3"}}],"env":[{"name":"AWS_REQUEST_CHECKSUM_CALCULATION","value":"when_required"},{"name":"AWS_RESPONSE_CHECKSUM_VALIDATION","value":"when_required"}]}]}}'

# inside:
aws --endpoint-url=http://garage:3900 s3 ls s3://wordpress-backups/db/
aws --endpoint-url=http://garage:3900 s3 ls --recursive --human-readable --summarize s3://wordpress-backups/wp-content/ | tail -3
```

### Restore the database

```bash
# 1. In the aws-shell pod above, pull the dump onto the shared bucket path you
#    can reach from the mariadb pod -- simplest is to stream it straight in:
kubectl exec -n irl -i sts/wordpress-mariadb -- bash -c \
  'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" wordpress' < ./wordpress-db-<stamp>.sql
```

If the dump is still gzipped, `gunzip -c dump.sql.gz | kubectl exec -i ...`.
Take a snapshot first (`zfs snapshot main/wordpress-db@pre-restore-$(date +%F)`);
the import overwrites tables in place and there is no undo.

### Restore wp-content

```bash
# From the aws-shell pod, with the content claim mounted (easiest: scale the
# app to 0, then run a one-off pod that mounts wordpress-content):
aws --endpoint-url=http://garage:3900 s3 sync \
  s3://wordpress-backups/wp-content/ /var/www/html/wp-content/
chown -R 33:33 /var/www/html/wp-content
```

Because the mirror has no `--delete`, a sync back can restore files the live
site removed -- that is the point, but it also means the restored tree is a
union, not a snapshot. For an exact point in time, use the ZFS snapshot.

### Full rebuild from scratch

`wp-config.php` is NOT in the S3 backup (only `wp-content/` and the database).
That is deliberate: the image regenerates it on first boot and the only thing
lost is the salt set, which just logs everyone out. Rebuild order: run the
deploy, let the pod create a fresh install, then restore the database, then
sync `wp-content` back.
## Recovery

```bash
ansible-playbook playbooks/helm-deploy.yml --tags wordpress   # redeploy (from ansible/)
kubectl rollout restart -n irl deploy/wordpress               # restart the app only
kubectl rollout restart -n irl sts/wordpress-mariadb          # restart the database
```

Posts live in `main/wordpress-db`, uploads and `wp-config.php` (which holds the auth salts) in `main/wordpress-content`. Both are snapshotted hourly by sanoid. Snapshot before anything destructive:

```bash
ssh homelab-ts "sudo zfs snapshot main/wordpress-db@pre-$(date +%F) main/wordpress-content@pre-$(date +%F)"
```

Losing `wp-config.php` is survivable (the entrypoint regenerates it, new salts just log everyone out); losing the database is not.
