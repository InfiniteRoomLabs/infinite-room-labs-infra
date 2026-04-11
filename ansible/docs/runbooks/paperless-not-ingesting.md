# Runbook: Paperless Not Ingesting Documents

## Severity: MEDIUM

Files are landing in the `paperless-consume` directory but not appearing
in the Paperless UI within the expected ~3 minute window. This is the
most common Paperless failure mode because the ingestion path crosses
multiple boundaries: SMB/NFS write -> filesystem -> hostPath PV -> pod
-> polling consumer -> OCR pipeline -> Postgres + media PVC.

If Paperless itself is *down* (UI unreachable, pods crashing), use the
generic `service-down.md` runbook first and come back here once the pods
are stable.

## Detection

- User report: "I scanned a document and it never showed up"
- Files visible in `/mnt/homelab-nfs/paperless-consume/` from a client
  but not in the Paperless inbox after 5+ minutes
- Backlog of files in `/usr/src/paperless/consume/` inside the pod
- Grafana alert (if added): `paperless_consume_dir_file_count > 5 for 10m`

## Assessment

Run these in order. The first one that returns abnormal output points
at the failing layer.

```bash
# 1. Pod health -- are the workers running at all?
kubectl get pods -n irl -l app.kubernetes.io/instance=paperless

# 2. Recent log activity -- is the consumer doing ANYTHING?
kubectl logs -n irl deploy/paperless --tail=50 \
  | grep -iE "consum|task|received|ocr|fail|error"

# 3. What's actually in the consume dir from the pod's view?
kubectl exec -n irl deploy/paperless -- ls -la /usr/src/paperless/consume/

# 4. What's in the consume dir from the host's view?
ssh homelab "sudo ls -la /media/root/storage1/nfs-share/paperless-consume/"

# 5. Are the views consistent?
# If host shows files that pod doesn't see (or vice versa), it's a
# hostPath / filesystem issue. If both see the same files, it's a
# consumer logic issue.

# 6. Celery worker status
kubectl exec -n irl deploy/paperless -- celery -A paperless inspect ping 2>&1 | head -5
```

## Common Causes and Fixes

### File ownership wrong (UID mismatch)

**Symptom**: files exist in the consume dir from both views, but the
consumer log shows `PermissionError` or silently ignores them.

```bash
# Check ownership of a stuck file
ssh homelab "sudo stat -c '%U:%G %u:%g %A %n' /media/root/storage1/nfs-share/paperless-consume/<filename>"
```

If the file is owned by `nobody:nogroup` (UID 65534) instead of
`dataplicity:dataplicity` (UID 1000), the NFS or SMB export lost its
`anonuid=1000` mapping. Re-run the credentials-rotation playbook:

```bash
cd ansible
direnv exec . uv run ansible-playbook playbooks/credentials-rotation.yml
```

For files already on disk with the wrong ownership, fix manually:

```bash
ssh homelab "sudo chown -R 1000:1000 /media/root/storage1/nfs-share/paperless-consume/"
```

### Consumer is stuck in the polling stability window

**Symptom**: file is visible to the pod, no errors, but no "Consuming X"
log line.

The polling consumer waits for the file to be unchanged for
`PAPERLESS_CONSUMER_POLLING_RETRY_COUNT` cycles before ingesting. With
the default settings (`POLLING=30, RETRY_COUNT=5`), that's a 2.5 minute
stability window. If a client is touching the file (e.g., a slow OCR
write or a still-running scan), the timer resets every poll.

```bash
# Check the file's mtime vs current time on the homelab
ssh homelab "sudo stat -c 'mtime=%Y now=$(date +%s)' /media/root/storage1/nfs-share/paperless-consume/<filename>"
```

If the mtime keeps changing, find the writer:

```bash
ssh homelab "sudo lsof /media/root/storage1/nfs-share/paperless-consume/<filename>"
```

If the file genuinely hasn't been touched in 5+ minutes and still isn't
ingested, the consumer's inotify state may be stale. Restart the pod:

```bash
kubectl rollout restart deploy/paperless -n irl
```

### File is a non-PDF format Paperless rejects

**Symptom**: log shows `WARNING`/`ERROR` mentioning the filename, with
words like `not supported`, `unknown format`, or `parser`.

Paperless accepts PDFs, plus images (PNG, JPG, TIFF, GIF, BMP, WEBP),
plus -- when Tika is enabled -- Office documents (DOCX, XLSX, PPTX, ODT,
ODS, ODP, RTF). Anything else gets rejected.

```bash
# Check the file extension and a few bytes of the actual content
ssh homelab "sudo file /media/root/storage1/nfs-share/paperless-consume/<filename>"
```

If the file is wrong, delete it from the consume dir and re-scan with the
correct format. If the file SHOULD be accepted but isn't, check whether
Tika and Gotenberg are healthy:

```bash
kubectl get pods -n irl -l app.kubernetes.io/component=tika
kubectl get pods -n irl -l app.kubernetes.io/component=gotenberg
kubectl logs -n irl deploy/paperless-tika --tail=20
```

### File is 0 bytes

**Symptom**: file exists but has size 0. Some scanner software creates
the destination file before writing data; if the scan failed mid-way,
an empty file sits on the share and Paperless can't process it.

```bash
ssh homelab "sudo find /media/root/storage1/nfs-share/paperless-consume/ -size 0 -ls"
```

Delete the empty file and re-scan:

```bash
ssh homelab "sudo find /media/root/storage1/nfs-share/paperless-consume/ -size 0 -delete"
```

### Redis (Valkey) connection broken

**Symptom**: log shows `ConnectionError: Error 111 connecting to redis`,
`celery.exceptions.NotRegistered`, or the Celery worker doesn't appear
in the inspect ping output.

```bash
# Verify the redis-auth secret matches what valkey is configured with
kubectl get secret -n irl redis-auth -o jsonpath='{.data.redis-password}' | base64 -d | wc -c
kubectl exec -n irl deploy/paperless -- env | grep PAPERLESS_REDIS
```

The PAPERLESS_REDIS env var should look like
`redis://:<password>@valkey:6379/3`. If it shows `OVERRIDE-ME` as the
password, the helm-deploy.yml secrets-override task didn't run -- re-run:

```bash
cd ansible
direnv exec . uv run ansible-playbook playbooks/helm-deploy.yml --tags paperless
```

If the password is real but auth still fails, the redis-auth secret may
have been rotated without re-syncing paperless. Re-sync from BW:

```bash
./scripts/bw-sync.sh --target k8s
kubectl rollout restart deploy/paperless -n irl
```

### Postgres connection broken

**Symptom**: log shows `psycopg2.OperationalError`, `connection refused`,
`role "paperless" does not exist`, or `database "paperless" does not exist`.

```bash
# CNPG cluster health
kubectl get cluster -n irl postgresql

# Verify the paperless DB and role exist
kubectl exec -n irl postgresql-1 -c postgres -- psql -U postgres -l | grep paperless
kubectl exec -n irl postgresql-1 -c postgres -- psql -U postgres -c "\du" | grep paperless
```

If the role/DB are missing, re-run the postgres bootstrap:

```bash
cd ansible
direnv exec . uv run ansible-playbook playbooks/helm-deploy.yml --tags postgres
```

### OCR pipeline failing on every document

**Symptom**: every document fails ingestion with `ocrmypdf` errors,
`PdfReadError`, `PIL.UnidentifiedImageError`, or `Tesseract failed`.

```bash
# Look at the most recent failed task
kubectl logs -n irl deploy/paperless --tail=200 | grep -A5 -i "fail\|error" | tail -30
```

Common sub-causes:
- **OCR running on a re-OCR pass**: `PAPERLESS_OCR_MODE` should be `skip`
  (not `force`) so paperless doesn't retry OCR on docs that already have
  a text layer. Verify with `kubectl exec -n irl deploy/paperless -- env | grep OCR_MODE`.
- **Disk full**: `kubectl exec -n irl deploy/paperless -- df -h /usr/src/paperless/`
- **Tesseract language pack missing**: `PAPERLESS_OCR_LANGUAGE` references a
  language not installed. Check `PAPERLESS_OCR_LANGUAGES` for the install list.

### Disk full on the media or data PVC

**Symptom**: log shows `OSError: [Errno 28] No space left on device`.

```bash
# Per-PVC usage
kubectl exec -n irl deploy/paperless -- df -h /usr/src/paperless/
ssh homelab "sudo zfs list main/paperless-media main/paperless-data"
```

If `paperless-media` is full, increase the quota and the PVC:

```bash
ssh homelab "sudo zfs set quota=1T main/paperless-media"
kubectl edit pv pv-paperless-media   # bump capacity
kubectl edit pvc paperless-media-pvc -n irl   # bump request
```

CNPG postgres also has a quota -- if THAT's full, the underlying issue
is usually too many tasks accumulating in `documents_paperlesstask`. Run
`document_purge` from inside the pod, or truncate the table directly.

## Escalation

If the consumer is healthy and files still aren't ingesting after the
above checks, the issue is likely in paperless-ngx itself. Capture full
context for upstream:

```bash
kubectl logs -n irl deploy/paperless > /tmp/paperless-debug.log
kubectl describe pod -n irl -l app.kubernetes.io/instance=paperless > /tmp/paperless-pod.log
kubectl exec -n irl deploy/paperless -- env | grep PAPERLESS_ > /tmp/paperless-env.log
```

Open an issue at https://github.com/paperless-ngx/paperless-ngx/issues
with these attachments (redact env values that look secret).

## Prevention

- Run a smoke test once per quarter: drop a real PDF via the SMB share,
  confirm it appears in the UI within 3 minutes
- Monitor `paperless_consume_dir_file_count` and alert at >5 files
  pending for >10 minutes
- Test the backup CronJob's manual trigger after every chart upgrade
- Keep `PAPERLESS_CONSUMER_POLLING_RETRY_COUNT` set high enough that
  scanner software never wins the race against the polling window
