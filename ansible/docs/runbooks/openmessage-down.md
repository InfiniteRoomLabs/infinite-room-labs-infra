# Runbook: OpenMessage Down / Degraded

## Severity: LOW-MEDIUM

No human-facing service depends on it, but every agent that reads or sends SMS
through MCP does, and a botched recovery can cost the Google pairing -- which
is the one thing here that cannot be regenerated from the cluster.

OpenMessage (`openmessage.lab.infiniteroomlabs.cloud`) runs in the `irl`
namespace as a single Deployment (`openmessage`), from the IRL chart
`irl-openmessage` (values: `ansible/helm/openmessage/values.yaml`). It pairs
with Google Messages for Web and re-exposes the conversation as an MCP server
on port 7007. State lives on the `openmessage-data` PVC (static PV
`pv-openmessage-data`, ZFS dataset `main/openmessage`): SQLite `messages.db`
(+ `-wal`/`-shm`) and `session.json`, the pairing credential.

Chart rationale and values reference: `helm-charts/charts/irl-openmessage/README.md`.
Design and deploy sequence: `docs/plans/2026-09-25-openmessage-k3s-deployment.md`.

## THE ONE-POD RULE (read before touching anything)

The Google pairing is a single logical device backed by one `session.json`.
**Two daemons on that pairing fight over the session and Google can revoke it**,
which costs a re-pair from the phone. The chart pins `replicas: 1` and
`strategy: Recreate` for exactly this reason.

Therefore, during any recovery:

- Never `kubectl scale --replicas=2`, never add an HPA, never switch to
  RollingUpdate.
- Never run a debug/maintenance pod that mounts the same claim **while the main
  pod is running**. Scale to 0 first, do the work, scale back to 1.
- Never start a second OpenMessage anywhere else (laptop, desktop) on the same
  pairing while the cluster pod is up.

## Detection

- `https://openmessage.lab.infiniteroomlabs.cloud/healthz` not returning 200
  (covered by the derived ingress test; the registry entry sets
  `health_path: /healthz`)
- An MCP client reports 401/403 where it used to work
- Messages stop arriving while `/healthz` is still 200 -- the daemon is up but
  the Google session is dead. `/healthz` is process-level only and says
  **nothing** about pairing state; the logs do.

## Assessment

```bash
kubectl get pods -n irl -l app.kubernetes.io/instance=openmessage
kubectl logs -n irl deploy/openmessage --tail=100
kubectl get pvc -n irl openmessage-data                  # must be Bound
kubectl get ingressroute,middleware -n irl | grep openmessage
kubectl get secret -n irl openmessage-secrets            # must exist, key `token`
dig +short openmessage.lab.infiniteroomlabs.cloud        # expect 100.86.213.22
```

From a tailnet or LAN host:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://openmessage.lab.infiniteroomlabs.cloud/healthz   # 200
curl -sS -o /dev/null -w '%{http_code}\n' https://openmessage.lab.infiniteroomlabs.cloud/mcp       # 401
```

## Reading the status code: four gates, four different problems

A request passes four filters in this order. Knowing which one bit saves most
of the debugging time.

| Code | Gate | What it means | Where to fix |
|---|---|---|---|
| DNS failure / no route | Split DNS | `openmessage.lab` only resolves through the internal CoreDNS zone | Not on the tailnet, or the CoreDNS zone was not redeployed |
| 403 | Traefik `ipAllowList` middleware | Your source IP is outside `192.168.2.0/24` and `100.64.0.0/10` | `ingress.allowList.sourceRange` in `ansible/helm/openmessage/values.yaml` |
| 403 | The daemon's own `Host` check | The `Host` header is not in `OPENMESSAGES_ALLOWED_HOSTS` (DNS-rebinding defence) | `ingress.host` in the same values file -- it is what feeds the env var |
| 401 | Bearer token | `Authorization: Bearer <token>` missing or wrong on a `/mcp*` request | The `openmessage-secrets` Secret and the client config |
| 404 from Traefik | No IngressRoute | The release is not deployed, or the route was pruned | Redeploy (below) |

The two 403s are told apart by *who* answers: the Traefik middleware rejects
before the request reaches the pod, so `kubectl logs deploy/openmessage` shows
nothing at all for it. A Host-check 403 appears in the daemon's log.

`/healthz` sits behind DNS, the allowlist and the Host check, but **not** behind
the bearer token.

### Reaching it from the LAN when Tailscale is the broken thing

`192.168.2.0/24` is in the allowlist and the host firewall accepts 443 on every
interface, so a LAN client can reach Traefik -- but the hostname resolves only
through Tailscale Split DNS. A LAN-only device has to be pointed at the node by
hand, and must still send the right `Host` or the daemon 403s it:

```bash
curl -sS --resolve openmessage.lab.infiniteroomlabs.cloud:443:192.168.2.2 \
  -o /dev/null -w '%{http_code}\n' https://openmessage.lab.infiniteroomlabs.cloud/healthz
```

### Client-IP caveat for the allowlist

The `ipAllowList` middleware only filters if Traefik sees the real client
address. It does today: Traefik runs `hostNetwork: true` with a `ClusterIP`
Service (`ansible/helm/traefik/values.yaml`), so connections land on the node's
own socket with no kube-proxy DNAT/SNAT in front, and Traefik's `RemoteAddr` is
the client. The middleware uses `RemoteAddr` by default and ignores
`X-Forwarded-For`, so a client cannot spoof its way in with a header.

**If Traefik is ever moved behind a LoadBalancer, a NodePort Service with
`externalTrafficPolicy: Cluster`, or another proxy, the allowlist silently
starts allowing everything that can reach Traefik.** Re-verify after any change
to how Traefik is exposed. Even then the service is not public: the hostname
has no public DNS record and the bearer token still applies.

## Common Causes and Fixes

### Pod in ImagePullBackOff

`image.digest` in `ansible/helm/openmessage/values.yaml` must name a
published manifest of `ghcr.io/deathnerd/openmessage` (from a fork release
tag). Check, in order: the digest was mistyped or points at an unpublished
build; the GHCR package was made private (it is public, so the cluster has
no pull secret); GHCR itself is unreachable from the node. Confirm the
digest resolves with
`docker buildx imagetools inspect ghcr.io/deathnerd/openmessage@<digest>`.

```bash
kubectl describe pod -n irl -l app.kubernetes.io/instance=openmessage | tail -20
```

### Pod never becomes Ready, probes failing with 403

The probes send an explicit `Host` header (`probes.setHostHeader`, default
true) precisely because kubelet dials the pod IP and that Host is never in
`OPENMESSAGES_ALLOWED_HOSTS`. If someone turned that off, or `ingress.host` and
`app.allowedHosts` disagree, every probe 403s and the pod crashloops on a
perfectly healthy daemon.

### Pod crashlooping on startup, cannot write /data

`readOnlyRootFilesystem: true` means `/data` is the only writable path that
matters, and hostPath PVs ignore `fsGroup` -- the dataset must be owned by
1000:1000 on the host:

```bash
ssh homelab-ts "ls -ld /media/root/storage1/openmessage"
```

Wrong owner: re-run the chown task.

```bash
cd ansible/ && uv run ansible-playbook playbooks/zfs.yml --tags openmessage
```

### 401 on every request although the Secret exists

The token file is mounted read-only at `/run/secrets/openmessage/token` from
Secret `openmessage-secrets`, key `token`. Check the mount, not the value:

```bash
kubectl exec -n irl deploy/openmessage -- ls -l /run/secrets/openmessage/
```

Missing Secret: re-sync from Bitwarden (item `openmessage-control-token`), then
restart the pod -- a mounted Secret updates in place eventually, but a restart
is deterministic.

```bash
mise run secrets:sync
kubectl rollout restart -n irl deploy/openmessage
```

Never echo the token. If a client is failing and the Secret is fine, the client
config is stale -- see "Rotating the control token".

### Messages stop syncing, /healthz still 200

The Google session is dead or revoked. Confirm from the logs (pairing state
appears there and nowhere else), then re-pair (below). Common triggers: a
second daemon was started on the same pairing, the phone was offline for a long
period, or the account revoked the web device.

### Domain unreachable but pods healthy

DNS or routing:

```bash
kubectl get ingressroute -n irl | grep openmessage
dig +short openmessage.lab.infiniteroomlabs.cloud   # expect 100.86.213.22
```

The record is generated from `irl_services` into the CoreDNS zone; the zone
also carries a wildcard, so a name resolving is not proof the record was
regenerated. Redeploy routing:

```bash
./ansible/run-ansible.sh playbook playbooks/helm-deploy.yml --tags coredns,traefik
```

### PVC full

5G quota on `main/openmessage`.

```bash
ssh homelab-ts "zfs list main/openmessage"
```

Raise the quota in `ansible/inventory/group_vars/all/main.yml`
(`irl_zfs_datasets`), re-run `playbooks/zfs.yml --tags datasets`, and raise the
PV capacity in `playbooks/k3s.yml` to match.

## Re-pairing with Google

Re-pairing is done **in a debug pod that mounts the same claim, with the main
pod scaled to zero**. Never alongside the running pod.

```bash
# 1. Stop the daemon. Wait for the pod to actually be gone -- the RWO claim
#    cannot be mounted twice, and this is also the one-pod rule.
kubectl scale -n irl deploy/openmessage --replicas=0
kubectl wait -n irl --for=delete pod -l app.kubernetes.io/instance=openmessage --timeout=120s

# 2. One-off pod on the same claim, same uid, same image as the Deployment.
kubectl run -n irl openmessage-pair --rm -it --restart=Never \
  --image="$(kubectl get deploy -n irl openmessage -o jsonpath='{.spec.template.spec.containers[0].image}')" \
  --overrides='{
    "spec": {
      "securityContext": {"runAsUser": 1000, "runAsGroup": 1000, "fsGroup": 1000},
      "containers": [{
        "name": "openmessage-pair",
        "image": "IMAGE",
        "args": ["pair"],
        "stdin": true, "tty": true,
        "env": [{"name": "OPENMESSAGES_DATA_DIR", "value": "/data"}],
        "volumeMounts": [{"name": "data", "mountPath": "/data"}]
      }],
      "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "openmessage-data"}}]
    }
  }'
# (kubectl substitutes --image into the "IMAGE" placeholder.)

# 3. Scan the QR code from Google Messages on the phone:
#    Messages -> Device pairing -> Pair new device.

# 4. Bring the daemon back.
kubectl scale -n irl deploy/openmessage --replicas=1
kubectl logs -n irl deploy/openmessage -f
```

The new `session.json` lands on the PVC, so the pairing survives pod restarts
and redeploys.

## Backup and restore of /data

SQLite in WAL mode: copying `messages.db` alone while the daemon is writing
gives you a torn database. **Stop the pod first**, then copy all of
`messages.db*` plus `session.json` together -- they are one unit.

Sanoid snapshots `main/openmessage` on the `service_data` template (hourly x24,
daily x30, weekly x4, monthly x6). Full procedure, including restoring from a
snapshot: `ansible/docs/sops/backup-and-restore.md`, OpenMessage section.

Quick copy-out:

```bash
kubectl scale -n irl deploy/openmessage --replicas=0
kubectl wait -n irl --for=delete pod -l app.kubernetes.io/instance=openmessage --timeout=120s
ssh homelab-ts "sudo tar -C /media/root/storage1/openmessage -cf - messages.db messages.db-wal messages.db-shm session.json" > openmessage-data.tar
kubectl scale -n irl deploy/openmessage --replicas=1
```

`messages.db-wal` / `messages.db-shm` may be absent after a clean shutdown;
that is fine, `tar` will say so.

## Rotating the control token

Service secret: 365-day rotation policy (`ansible/docs/sops/rotate-secrets.md`).
Rotation is a three-step, and skipping step 3 locks out every client:

```bash
# 1. New value into Bitwarden item `openmessage-control-token` (keep
#    rotation_days: 365 in the item's Notes JSON, or --check-rotation skips it).
# 2. Sync it into the cluster and restart the pod.
mise run secrets:sync
kubectl rollout restart -n irl deploy/openmessage
# 3. Update the Authorization: Bearer header in EVERY MCP client config
#    (Claude Code and Claude Desktop, laptop and desktop).
```

There is no grace period: the daemon accepts exactly one token.

## Full Redeploy

```bash
./ansible/run-ansible.sh playbook playbooks/helm-deploy.yml --tags openmessage
```

The chart is pinned (`irl/irl-openmessage` 0.1.0) and data lives on a retained
static PV (`pv-openmessage-data`, `persistentVolumeReclaimPolicy: Retain`), so a
redeploy -- or even a full release delete and reinstall -- does not touch
`messages.db` or `session.json`.

## Future

A later move to a Claude custom connector behind the Cloudflare MCP proxy (the
pattern gunio-mcp and JobOps already use) would replace the bearer token with
Cloudflare Access and make the service reachable off-tailnet. That is tracked
separately and is explicitly **not** how it works today: no public DNS record,
no tunnel, no Funnel, tailnet/LAN only.
