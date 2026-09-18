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

### KNOWN BROKEN (2026-09-17): chrome sidecar in permanent CrashLoopBackOff

`karakeep-chrome` has been crashlooping since it was created on 2026-07-11 --
838 restarts and counting -- so **bookmarks have had no screenshots or
full-page archives that whole time**. The app itself is healthy; only capture
is affected, which is why it went unnoticed.

```
[FATAL:credentials.cc(127)] Check failed: . : Permission denied (13)
```
exit code 133, container dies in under a second, every time.

That is Chrome's sandbox failing to set up its namespace, not a karakeep bug.
What has been ruled out on the host:

```bash
ssh homelab-ts '/usr/sbin/sysctl kernel.unprivileged_userns_clone'   # = 1, allowed
ssh homelab-ts '/usr/sbin/sysctl kernel.apparmor_restrict_unprivileged_userns'  # absent
```

So the Debian 13 AppArmor userns restriction is NOT the cause. The pod runs
`gcr.io/zenika-hub/alpine-chrome:124` as uid 1000 with `readOnlyRootFilesystem:
true`, `allowPrivilegeEscalation: false` and `capabilities.add: [SYS_ADMIN]`
(chart defaults, see the comment in `ansible/helm/karakeep/values.yaml`).

Candidate fixes, **both of the non-invasive ones tested on the node and ruled
out** on 2026-09-17:

1. ~~Relax seccomp (`seccompProfile: {type: Unconfined}`) and keep everything
   else~~ -- tested with a standalone pod: identical `credentials.cc(127)`
   failure. Not a seccomp problem.
2. ~~Run as root with SYS_ADMIN~~ -- tested: Chrome refuses outright,
   `Running as root without --no-sandbox is not supported` (crbug 638180).
3. `--no-sandbox` in the container args. This is what actually works, and it is
   what almost every k8s Chrome deployment ends up doing. It is also a real
   trade-off: this container exists to render arbitrary untrusted pages, and
   the sandbox is what stands between a malicious bookmark and the container.
   If taken, pair it with a NetworkPolicy pinning the chrome pod's egress.

**Why the chart's `capabilities.add: [SYS_ADMIN]` does nothing here**: the
container runs as uid 1000. A non-root process gets an EMPTY effective
capability set on exec unless ambient capabilities are set, which k8s does not
do -- so SYS_ADMIN (and the default SYS_CHROOT) are not actually held by the
process, and Chrome's sandbox fails at `chroot(".")` with EPERM. The capability
in the chart values is decorative for as long as `runAsUser: 1000` stands.

Whatever is chosen belongs in `ansible/helm/karakeep/values.yaml` (the chart is
pinned at 0.32.0, so a render-diff review comes with it), never as a live
`kubectl edit`. Until then, karakeep works but never captures screenshots.


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
