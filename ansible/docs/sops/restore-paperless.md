# SOP: Restore Paperless-ngx From Backup

Recovers a Paperless-ngx deployment from a `document_exporter` tarball
stored in the Garage S3 `paperless-backups` bucket. Use this when:

- The paperless PVCs are lost (ZFS pool failure, accidental deletion)
- The CNPG `paperless` database is corrupted or rolled back to an empty state
- Migrating to a new cluster
- Testing the backup pipeline (do this at least once per quarter)

The Paperless `document_exporter` produces a self-contained zip with the
document originals, OCR'd archive PDFs, thumbnails, metadata JSON, and
the database contents. `document_importer` reverses the process.

## Prerequisites

- Paperless-ngx is deployed in the cluster (helm release `paperless` in
  `irl` namespace) -- if it's missing entirely, run the deploy SOP first
- The CNPG `paperless` database exists and is empty (or has data you're
  willing to overwrite -- importer is destructive)
- Access to the Garage admin API or `mc`/`aws-cli` configured against the
  Garage S3 endpoint
- The `paperless-backup-s3` Bitwarden item or equivalent S3 credentials

## Identify the backup to restore

```bash
# Via aws-cli (preferred -- credentials in env)
export AWS_ACCESS_KEY_ID=$(bw get password paperless-backup-s3-access-key)
export AWS_SECRET_ACCESS_KEY=$(bw get password paperless-backup-s3-secret-key)
aws --endpoint-url=https://s3.internal.lab.infiniteroomlabs.cloud \
  s3 ls s3://paperless-backups/ \
  | sort -k1,2  # newest at bottom
```

Pick the backup. Filenames look like `paperless-export-YYYYMMDD-HHMMSS.zip`.
The most recent backup that predates the corruption is usually the right one.

## Download the backup

```bash
BACKUP_NAME="paperless-export-20260410-070000.zip"   # adjust
mkdir -p /tmp/paperless-restore
aws --endpoint-url=https://s3.internal.lab.infiniteroomlabs.cloud \
  s3 cp s3://paperless-backups/${BACKUP_NAME} /tmp/paperless-restore/
ls -lh /tmp/paperless-restore/
```

## Stage the backup inside the paperless export PVC

The `document_importer` runs INSIDE the paperless container and reads
from `/usr/src/paperless/export/`. Copy the zip there:

```bash
PAPERLESS_POD=$(kubectl get pod -n irl -l app.kubernetes.io/instance=paperless \
  -o jsonpath='{.items[0].metadata.name}' \
  | head -1)
kubectl cp /tmp/paperless-restore/${BACKUP_NAME} \
  irl/${PAPERLESS_POD}:/usr/src/paperless/export/${BACKUP_NAME}
```

## Stop the paperless workers

The Celery workers process polling-consume tasks and webhooks; let them
drain before importing so they don't compete with the import for DB
locks.

```bash
kubectl scale deploy/paperless -n irl --replicas=0
# Wait for the pod to terminate fully
kubectl wait --for=delete pod -l app.kubernetes.io/instance=paperless,app.kubernetes.io/component!=tika,app.kubernetes.io/component!=gotenberg -n irl --timeout=2m
```

Then bring it back to 1 with the workers paused -- we need a pod to exec
into for the importer step. Easier path: scale to 1 and exec into it
without waiting for full readiness.

```bash
kubectl scale deploy/paperless -n irl --replicas=1
# Wait for the pod to be Running (not necessarily Ready)
kubectl wait --for=condition=ContainersReady=false pod -l app.kubernetes.io/instance=paperless,app.kubernetes.io/component!=tika,app.kubernetes.io/component!=gotenberg -n irl --timeout=2m
```

If the rolling pod restart confuses the kubectl-cp path, an alternative
is to use a one-shot Job that mounts the same PVCs and runs the importer.
Spec is at the bottom of this doc.

## Truncate the existing paperless DB tables

The importer expects an empty database. Truncate the document tables
(do NOT drop the schema -- migrations live there).

```bash
PG_PASSWORD=$(kubectl get secret -n irl postgres-paperless -o jsonpath='{.data.password}' | base64 -d)
kubectl exec -n irl postgresql-1 -c postgres -- bash -c "
  PGPASSWORD='${PG_PASSWORD}' psql -U paperless -d paperless <<'SQL'
TRUNCATE TABLE
  documents_document,
  documents_correspondent,
  documents_documenttype,
  documents_tag,
  documents_storagepath,
  documents_savedview,
  documents_savedviewfilterrule,
  documents_uisettings,
  documents_paperlesstask,
  documents_workflow,
  documents_workflowtrigger,
  documents_workflowaction,
  documents_customfield,
  documents_customfieldinstance,
  documents_share_link,
  documents_note
RESTART IDENTITY CASCADE;
SQL
"
```

Note: this list may need updating with future Paperless versions that
add new tables. If `document_importer` fails with an integrity error,
check the latest paperless docs for the canonical truncate list.

## Run document_importer

```bash
PAPERLESS_POD=$(kubectl get pod -n irl -l app.kubernetes.io/instance=paperless,app.kubernetes.io/component!=tika,app.kubernetes.io/component!=gotenberg \
  -o jsonpath='{.items[0].metadata.name}')

# Unzip the backup inside the export PVC
kubectl exec -n irl ${PAPERLESS_POD} -- \
  bash -c "cd /usr/src/paperless/export && unzip -o ${BACKUP_NAME}"

# Run the importer pointing at the unzipped directory
kubectl exec -n irl ${PAPERLESS_POD} -- \
  bash -c "cd /usr/src/paperless/src && \
    python manage.py document_importer --no-progress-bar /usr/src/paperless/export/"
```

Expect it to take 5-30 minutes depending on document count. The importer
re-encrypts encrypted fields with the current `PAPERLESS_SECRET_KEY`, so
make sure that secret hasn't been rotated since the backup was taken --
if it has, restore the old secret first or the documents will be unreadable.

## Restart the workers

```bash
kubectl rollout restart deploy/paperless -n irl
kubectl wait --for=condition=Available deploy/paperless -n irl --timeout=5m
```

## Verify

```bash
# Document count matches the backup
kubectl exec -n irl postgresql-1 -c postgres -- \
  psql -U paperless paperless -tc "SELECT count(*) FROM documents_document;"

# Sample a few documents in the UI
xdg-open https://archives.lab.infiniteroomlabs.cloud
```

Search for a known document (e.g., a tax form from a known year) and
confirm:
- The document opens
- The OCR text layer is searchable
- Tags + correspondents + custom fields all came across

## Clean up

```bash
# Remove the staged backup from the export PVC
kubectl exec -n irl ${PAPERLESS_POD} -- \
  rm -rf /usr/src/paperless/export/${BACKUP_NAME%.zip} /usr/src/paperless/export/${BACKUP_NAME}

# Remove the local download
rm -rf /tmp/paperless-restore

# Unset the credentials
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY PG_PASSWORD
```

## Alternative: One-shot restore Job

If kubectl-cp is unreliable (e.g., the paperless pod is in a crash loop),
spin up a dedicated Job that mounts the same PVCs and runs the importer
without needing the main deployment to be healthy. Save as
`paperless-restore-job.yaml`:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: paperless-restore
  namespace: irl
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
        - name: importer
          image: ghcr.io/paperless-ngx/paperless-ngx:2.14.7
          command: ["/bin/bash", "-c"]
          args:
            - |
              set -euo pipefail
              cd /usr/src/paperless/export
              unzip -o "${BACKUP_NAME}"
              UNZIPPED="${BACKUP_NAME%.zip}"
              cd /usr/src/paperless/src
              python manage.py document_importer --no-progress-bar "/usr/src/paperless/export/${UNZIPPED}"
          env:
            - name: BACKUP_NAME
              value: "paperless-export-20260410-070000.zip"
            - name: PAPERLESS_DBHOST
              value: "postgresql-rw"
            - name: PAPERLESS_DBNAME
              value: "paperless"
            - name: PAPERLESS_DBUSER
              value: "paperless"
            - name: PAPERLESS_DBPASS
              valueFrom:
                secretKeyRef:
                  name: postgres-paperless
                  key: password
          envFrom:
            - secretRef:
                name: paperless-secrets
          volumeMounts:
            - name: data
              mountPath: /usr/src/paperless/data
            - name: media
              mountPath: /usr/src/paperless/media
            - name: export
              mountPath: /usr/src/paperless/export
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: paperless-data-pvc
        - name: media
          persistentVolumeClaim:
            claimName: paperless-media-pvc
        - name: export
          persistentVolumeClaim:
            claimName: paperless-export-pvc
```

```bash
kubectl apply -f paperless-restore-job.yaml
kubectl logs -n irl job/paperless-restore -f
kubectl delete job/paperless-restore -n irl  # cleanup after success
```

## Rollback

There's no clean rollback from a partial import -- if the importer fails
midway, the database is in an inconsistent state. The recovery is to
truncate again and re-run with a known-good backup.

If you need to completely revert to the pre-restore state, you'd need a
CNPG point-in-time recovery from before the truncate. CNPG PITR is not
currently configured in this homelab (only daily exports). Add WAL
archiving + a Backup CR to enable PITR if this becomes important.

## See Also

- `helm-charts/charts/irl-paperless/templates/backup-cronjob.yaml` -- the
  CronJob that produces these backups nightly
- `ansible/playbooks/helm-deploy.yml` -- Phase 3 paperless install tasks
- `setup-windows-paperless-ingestion.md` -- end-user setup once restore is done
