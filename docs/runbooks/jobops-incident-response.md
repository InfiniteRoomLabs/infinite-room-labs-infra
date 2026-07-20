# Runbook: JobOps Incident Response and Monitoring

Last updated: 2026-07-16

Covers the self-hosted JobOps deployment: chart/release `irl-jobops`, namespace `jobops`, ZFS dataset `main/jobops-data`, public hostname `jops.infiniteroomlabs.com`. The app container is a fork of `ghcr.io/dakheera47/job-ops` pinned by digest (`REPLACE_WITH_DIGEST` in values). There is **no in-cluster Service** for this workload -- a Cloudflare tunnel sidecar reaches the app over pod-localhost `127.0.0.1:3001`. If a Service is ever added it must be named `jobops` on port `3001`, but the default posture is no Service at all.

## Threat Context

JobOps is a public-exposed workload that holds a Gmail OAuth token (historically plaintext-in-SQLite, now AES-256-GCM at rest) plus the user's full application history, and it embeds a browser that runs hostile job-board JavaScript in the same process as that database. Because its normal job is arbitrary scraping egress, a post-compromise attacker exfiltrating those secrets cannot be stopped at the network layer -- outbound data movement is indistinguishable from the app doing its job, so containment depends on cutting the app off entirely and revoking the credentials it held.

## Indicators That Warrant Containment

- Unexpected pod restarts or OOM/crash loops correlated with a scrape run (possible RCE via hostile board JS).
- Egress to hosts that are not known job boards or the configured AI provider.
- Gmail security alerts, unfamiliar OAuth activity, or AI-provider usage spikes on the linked accounts.
- Unauthorized changes to the SQLite DB, the tunnel config, or the deployment spec.

## Containment Sequence

Run these in order. Steps 1-3 stop the bleeding in under a minute; do not skip ahead to rebuild before evidence is preserved and credentials are revoked.

### 1. Disable the Cloudflare route

Cut public reachability first. Prefer flipping the Access policy to an explicit deny (fast, reversible, keeps the tunnel intact for forensics); disabling tunnel ingress is the harder cut if the connector itself is suspect.

```bash
# Fast path: set the Access application policy for jops.infiniteroomlabs.com to Deny.
# (Cloudflare dashboard: Zero Trust -> Access -> Applications -> JobOps -> Policies -> Deny)

# Harder cut: delete/disable the tunnel's public hostname route so nothing reaches the sidecar.
cloudflared tunnel route dns --overwrite-dns jops-jobops <placeholder>   # or remove the ingress rule
# If the tunnel is managed in Terraform, blank the ingress hostname and apply:
cd terraform/environments/homelab/cloudflare/tunnels && terraform apply
```

Confirm the public hostname no longer serves the app:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://jops.infiniteroomlabs.com   # expect 403 (deny) or 530/1033 (no route)
```

### 2. Apply a deny-all egress NetworkPolicy

The app's legitimate behavior is arbitrary egress, so a running pod can exfiltrate at will. Clamp egress before or in parallel with scaling down, in case the pod is mid-exfiltration and the scale-down is slow.

```bash
kubectl apply -n jobops -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: jobops-deny-all-egress
  namespace: jobops
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress: []
EOF

kubectl get networkpolicy -n jobops
```

Note: kube-router enforces NetworkPolicy on this cluster. Verify the policy is actually enforced (not just accepted by the API) before trusting it.

### 3. Scale the deployment to zero

```bash
kubectl scale -n jobops deploy/irl-jobops --replicas=0
kubectl get pods -n jobops -w   # wait until no jobops pods remain
```

This also stops the tunnel sidecar (it shares the pod), which is the intended belt-and-suspenders on top of step 1.

### 4. Preserve evidence

Snapshot the data **before** any wipe, rollback, or rebuild. The SQLite DB is the crime scene: it holds the (encrypted) Gmail token, application history, and whatever the hostile JS touched.

```bash
# ZFS snapshot of the JobOps dataset on the homelab node.
ssh homelab-ts "sudo zfs snapshot main/jobops-data@incident-$(date +%Y%m%d-%H%M)"
ssh homelab-ts "sudo zfs list -t snapshot main/jobops-data | tail"

# Capture the pod/deploy spec, recent events, and last logs for the timeline.
kubectl get deploy/irl-jobops -n jobops -o yaml > jobops-incident-deploy.yaml
kubectl get events -n jobops --sort-by=.lastTimestamp > jobops-incident-events.txt
kubectl logs -n jobops -l app.kubernetes.io/name=irl-jobops --all-containers --tail=2000 > jobops-incident-logs.txt 2>/dev/null || true
```

Keep the snapshot until the incident is closed. Do not `zfs rollback` or `zfs destroy` the incident snapshot during recovery.

### 5. Revoke the Google user grant (not just the client secret)

**This is the step people get wrong.** A stolen OAuth **refresh token** survives client-secret rotation -- rotating the secret does not invalidate tokens already issued to the user's grant. You must revoke the user's authorization so every issued token dies.

- Revoke the app's access from the user's Google Account: https://myaccount.google.com/permissions -> find the JobOps app -> **Remove access**. This invalidates the refresh token immediately.
- Then also rotate the OAuth **client secret** in Google Cloud Console (project `infinite-room-labs`) so a leaked client credential can't mint new grants, and update it in Bitwarden + re-sync.
- Revoke/rotate the **AI provider key** the app uses (the scraping/scoring model key). Revoke at the provider dashboard first, then update Bitwarden.

```bash
# After updating the values in Bitwarden:
cd infinite-room-labs-infra && ./scripts/bw-sync.sh --target both
./scripts/bw-sync.sh --verify-k8s
```

Do not bring the app back up until the grant is confirmed revoked (attempt a Gmail sync against the old token and confirm it 401s).

### 6. Rotate the Cloudflare tunnel connector token

The tunnel connector token lived in the compromised pod. Rotate it so a copied token can't re-establish a tunnel.

- Cloudflare dashboard: Zero Trust -> Networks -> Tunnels -> JobOps tunnel -> **Refresh token** (or delete and recreate the connector).
- Update the token in Bitwarden, re-sync, and let the new value land via a rollout (see step 8 / the rotation note in Monitoring).

```bash
cd infinite-room-labs && ./scripts/bw-sync.sh --target both && ./scripts/bw-sync.sh --verify-k8s
```

### 7. Rebuild the image from verified provenance

Assume the running image and anything the container wrote may be tampered. Rebuild the fork from a known-good commit and re-pin the digest -- never `:latest`.

```bash
# Rebuild from a verified upstream ref of the fork of ghcr.io/dakheera47/job-ops,
# push to the IRL registry, and capture the immutable digest.
docker buildx build --provenance=true --sbom=true -t <registry>/irl-jobops:incident-rebuild . --push
docker buildx imagetools inspect <registry>/irl-jobops:incident-rebuild --format '{{.Manifest.Digest}}'
```

Put that digest into the chart values, replacing the placeholder, and keep analytics disabled:

```yaml
# values (irl-jobops)
image:
  repository: <registry>/irl-jobops
  digest: "REPLACE_WITH_DIGEST"   # sha256:... from imagetools inspect
env:
  JOBOPS_DISABLE_ANALYTICS: "true"   # analytics MUST stay disabled
```

### 8. Restore only validated data

Restore from a snapshot taken **before** the compromise window, not from whatever was live. Integrity-check the SQLite DB as part of the restore -- a corrupted or tampered DB must not be trusted back into service.

```bash
# Roll the dataset back to a pre-incident snapshot (app already at 0 replicas from step 3).
ssh homelab-ts "sudo zfs list -t snapshot main/jobops-data"
ssh homelab-ts "sudo zfs rollback main/jobops-data@<pre-incident-snapshot>"   # DESTRUCTIVE

# Integrity-check the SQLite DB before trusting it (path is the app DB inside the dataset).
ssh homelab-ts "sudo sqlite3 /media/root/storage1/jobops-data/<db-file>.db 'PRAGMA integrity_check;'"
# Expect exactly: ok
```

If `integrity_check` returns anything other than `ok`, do not restore that copy -- fall back to an older snapshot and re-check. Only after a clean check, redeploy the rebuilt image and scale back up:

```bash
cd infinite-room-labs-infra
./ansible/run-ansible.sh playbook playbooks/helm-deploy.yml --tags jobops
kubectl scale -n jobops deploy/irl-jobops --replicas=1
```

Bring the Cloudflare route back last (re-enable the Access policy / restore tunnel ingress) once the app is confirmed healthy and the deny-all egress policy has been replaced with the normal scoped policy.

### Post-incident

File an incident note in `docs/runbooks/` with the timeline, affected accounts (Gmail, AI provider, tunnel), the snapshot name held as evidence, and the rebuilt image digest. Re-link Gmail only after the user re-consents through a fresh OAuth flow.

## Monitoring and Alerts

Wire these into the `irl-monitoring` stack (Prometheus + Alertmanager, Grafana at `grafana.lab.infiniteroomlabs.cloud`). The recurring theme: **app health, tunnel health, and data freshness are three separate signals** -- one being green does not imply the others are.

| Signal | What to alert on | Why it matters |
|--------|------------------|----------------|
| Pod readiness | Deployment `irl-jobops` has 0 ready replicas for > 5m | The workload is down or crash-looping; public route may still be up while the app is broken. |
| Restart count | `kube_pod_container_status_restarts_total` for the pod increases > 3 in 15m | Repeated restarts during scrape runs can indicate a crash from hostile board JS -- treat as a possible compromise indicator, not just flakiness. |
| PVC capacity | `main/jobops-data`-backed PVC > 85% used | SQLite + scraped artifacts fill the dataset; a full volume corrupts writes and stalls the pipeline. |
| Tunnel connector health | `cloudflared` connector down / unhealthy (Cloudflare tunnel health, scraped or checked separately from the app) | **Tunnel health != app health.** The connector can be up while the app is dead, or the app healthy while the public route is broken. Alert on both independently. |
| Backup age | Newest `main/jobops-data` Sanoid snapshot older than its retention interval (e.g. no hourly snapshot in the last ~90m) | If backups silently stop, step 8 restore has nothing recent to restore from. Alert on snapshot staleness, not just snapshot existence. |

Sanoid manages `main/jobops-data` snapshots (service-data template: hourly/daily/weekly/monthly). The backup-age alert should fire on the newest snapshot's timestamp, so a wedged Sanoid or a renamed dataset surfaces before an incident needs it.

### Rotation gotcha: envFrom Secret updates do not restart the pod

Updating a Secret consumed via `envFrom` (the tunnel token, the AI key, OAuth values) does **not** refresh a running pod -- environment variables are injected once at container start. `bw-sync.sh` writing the new Secret is not enough; the pod keeps the old value in memory until it is recreated. Rotation must trigger an explicit rollout:

```bash
# After the Secret is updated (e.g. by bw-sync.sh), force the pod to pick it up:
kubectl rollout restart deploy/irl-jobops -n jobops
kubectl rollout status deploy/irl-jobops -n jobops
```

This applies during normal rotation and during containment steps 5-6: the new grant/token/key values only take effect after the rollout, and during an active incident the pod should stay at 0 replicas until you are ready to bring the rebuilt image up anyway.
