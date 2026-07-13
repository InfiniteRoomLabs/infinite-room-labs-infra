# Runbook: Karakeep Down / Degraded

## Severity: LOW (single-user bookmark manager, no downstream dependents)

Karakeep (`bookmarks.lab.infiniteroomlabs.cloud`) runs in the `irl` namespace
as three workloads: the web app (`karakeep`, SQLite on the `karakeep-data`
PVC), a headless Chrome worker (`karakeep-chrome`, page capture), and
Meilisearch (`karakeep-meilisearch-0` StatefulSet, rebuildable search index).

## Detection

- `https://bookmarks.lab.infiniteroomlabs.cloud/api/health` not returning
  `{"status":"ok"}` (smoke test `test_health.py` covers this)
- Bookmarks save but never get a title/screenshot (chrome worker down)
- Search returns nothing for known bookmarks (meilisearch down/empty)

## Assessment

```bash
kubectl get pods -n irl -l app.kubernetes.io/instance=karakeep
kubectl logs -n irl deploy/karakeep --tail=50
kubectl logs -n irl deploy/karakeep-chrome --tail=20
kubectl logs -n irl karakeep-meilisearch-0 --tail=20
kubectl get pvc -n irl | grep karakeep   # both must be Bound
```

## Common Causes and Fixes

### App pod crashlooping
Check env/secret wiring first -- the app needs `NEXTAUTH_SECRET`
(`karakeep-secrets`) and `MEILI_MASTER_KEY` (`karakeep-meili-secrets`):

```bash
kubectl get secret -n irl karakeep-secrets karakeep-meili-secrets
kubectl describe pod -n irl -l app.kubernetes.io/name=karakeep | tail -20
```

If secrets are missing, re-sync: `mise run secrets:sync`, then
`uv run ansible-playbook playbooks/k8s-secrets.yml` from `ansible/`.

### Capture works but pages have no content/screenshot
Chrome worker unreachable. It's stateless -- restart it:

```bash
kubectl rollout restart -n irl deploy/karakeep-chrome
```

### Search empty or stale
Meilisearch index is rebuildable from the SQLite DB. Restart the
StatefulSet, then trigger a reindex from the karakeep UI
(Admin Settings -> Background Jobs -> Reindex) :

```bash
kubectl rollout restart -n irl statefulset/karakeep-meilisearch
```

### PVC full
`karakeep-data` (50G quota) holds the DB plus every archived page and
screenshot. Check usage on the homelab host:

```bash
ssh homelab-ts "zfs list main/karakeep-data main/karakeep-meilisearch"
```

Raise the quota in `ansible/inventory/group_vars/all/main.yml`
(`irl_zfs_datasets`) and re-run `playbooks/zfs.yml` if legitimately full.

### Domain unreachable but pods healthy
DNS or ingress. Verify the IngressRoute and CoreDNS record exist:

```bash
kubectl get ingressroute -n irl | grep karakeep
dig +short bookmarks.lab.infiniteroomlabs.cloud   # expect 100.86.213.22
```

Missing -> redeploy the routing layer:
`./ansible/run-ansible.sh playbook playbooks/helm-deploy.yml --tags coredns,traefik`

## Full Redeploy

```bash
./ansible/run-ansible.sh playbook playbooks/helm-deploy.yml --tags karakeep
```

Chart is pinned (`karakeep-app/karakeep` 0.32.0) and data lives on retained
static PVs (`pv-karakeep-data`, `pv-karakeep-meilisearch`), so a redeploy or
even a full release delete/reinstall does not touch bookmark data.

## Data Recovery

See `ansible/docs/sops/backup-and-restore.md` -- karakeep section. Sanoid
snapshots cover `main/karakeep-data` (service_data template); meilisearch is
rebuildable and only minimally retained.
