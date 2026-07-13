# Karakeep Deployment -- Final Synthesized Plan

**Date:** 2026-07-10
**Status:** Proposed (synthesis)
**Synthesized from:** the original plan (custom-chart, full lifecycle), the alt plan (official-chart, minimal diff), all four independent reviews, and both comparison documents (`...-comparison..claude.md`, `...-comparison.gpt.md`). Both comparisons independently reached the same conclusion: use the alt plan as the implementation skeleton and import the original plan's production-readiness controls, after resolving the access-boundary question honestly.

## Objective

Deploy Karakeep (bookmark manager) to the `irl` namespace on the homelab k3s cluster, reachable at an internal HTTPS hostname discoverable only via Tailscale split DNS, with durable ZFS-backed storage, Bitwarden-backed secrets, and tested backup/restore -- using the official upstream Helm chart, pinned, deployed through the existing Ansible + Helm pattern (firefly/ghostfolio precedent).

## Decisions (settled by the review cycle)

### D1. Packaging: official chart, pinned

Use `karakeep-app/karakeep` from `https://karakeep-app.github.io/helm-charts`, **pinned to an exact `chart_version`** (0.32.0 at review time; confirm latest at implementation). No custom `irl-karakeep` chart -- all four reviews agreed the maintenance cost is unjustified.

Pinning is mandatory here even though firefly/ghostfolio float: this chart's contract is unusually fragile -- our overrides depend on its literal `meilesearch` misspelling and its bjw-s (common 3.7.3) value paths. Upgrades are deliberate `chart_version` bumps with a render-diff review.

### D2. Access boundary: honest scope, strict version spun out

All reviews except one proved the same fact: nftables accepts 80/443 on every interface (`ansible/templates/nftables.conf.j2` has no `iifname` restriction) and Traefik is `hostNetwork: true`, so any LAN client with `curl --resolve` reaches any `*.lab` service. Split DNS is discovery, not access control.

**This plan claims "tailnet-discoverable and non-public", not strictly Tailscale-only**: no public DNS record, no NodePort/LoadBalancer, no Funnel/Serve, TLS via the existing wildcard DNS-01 resolver -- but technically LAN-reachable at the TCP layer until the homelab-wide firewall item lands (see Spin-outs, item A). Acceptance tests are scoped to what is actually true; the LAN direct-IP test *documents* current reachability rather than pretending it fails.

### D3. Hostname

`bookmarks.lab.infiniteroomlabs.cloud` (`internal: false`, matching the user-facing peers firefly/ghostfolio). The original's `keep.internal.lab...` is equivalent in posture; one name had to be picked. Note: resolution currently works via the CoreDNS wildcard record, not an explicit record (see Spin-outs, item C).

### D4. Secrets: two Bitwarden items, two split k8s Secrets

The chart auto-generates `NEXTAUTH_SECRET` and `MEILI_MASTER_KEY` with `randAlphaNum` re-evaluated on **every** `helm upgrade` -- sessions and search auth break on each deploy unless we supply stable values. Chart-generated secrets are disabled; values come from Bitwarden via bw-sync (one BW item per value -- `bw-sync.sh` reads exactly one value per item; the original's one-item-with-fields model does not sync).

Split into two Secrets for least privilege (the meilisearch chart `envFrom`s its entire secret, so a single shared secret would leak `NEXTAUTH_SECRET` into the meilisearch pod):

| BW item (`IRL/Services/`) | vault var | k8s Secret | key |
|---|---|---|---|
| `karakeep-nextauth-secret` | `vault_karakeep_nextauth_secret` | `karakeep-secrets` | `NEXTAUTH_SECRET` |
| `karakeep-meili-master-key` | `vault_karakeep_meili_master_key` | `karakeep-meili-secrets` | `MEILI_MASTER_KEY` |

The karakeep container imports both; meilisearch imports only `karakeep-meili-secrets`. `NEXT_PUBLIC_SECRET` (from the upstream kustomize samples) is absent from the official chart -- verify during WP1 whether it is vestigial; do not create it preemptively.

### D5. Storage: ZFS-backed, deterministic, retained

Replace the chart's dynamic `local-path` volumeClaimTemplates with the repo's established pattern (paperless/garage precedent): ZFS datasets -> labeled static PVs -> PVCs with `selector.matchLabels` created in `helm-deploy.yml`.

| Dataset | Mountpoint | Quota | PV | PVC |
|---|---|---:|---|---|
| `main/karakeep-data` | `/media/root/storage1/karakeep-data` | 50G | `pv-karakeep-data` (label `app: karakeep`) | `karakeep-data` |
| `main/karakeep-meilisearch` | `/media/root/storage1/karakeep-meilisearch` | 20G | `pv-karakeep-meilisearch` (label `app: karakeep`) | `karakeep-meilisearch` |

`compression=lz4`, `atime=off`, StorageClass `zfs-local`, `Retain` reclaim, PVs pinned to the data node. **Chown the dataset mountpoints to the container UIDs** in `zfs.yml` (paperless precedent) -- non-root containers on root-owned hostPath fail at startup; determine UIDs in WP1.

To consume existing claims, override the karakeep controller from StatefulSet to **Deployment (replicas 1, strategy Recreate)** with `persistence.data.existingClaim: karakeep-data` mounted at `/data`, and point the meilisearch subchart at `karakeep-meilisearch` via its existing-claim support. Both overrides must be proven by `helm template` render in WP1, not assumed.

### D6. Known-cluster mitigations baked in

- **alpine/musl + ndots:5** (the qBittorrent-blocking bug, `group_vars/all/main.yml:168-172`): both the karakeep and chrome images are Alpine-based and must resolve arbitrary external hostnames for page capture. Set `defaultPodOptions.dnsConfig.options: [{name: ndots, value: "1"}]` in the chart values; WP4 includes an in-pod external-resolution test before any capture test.
- **Signups**: Karakeep defaults to open registration. Bootstrap the single account, then set `DISABLE_SIGNUPS: "true"` in the chart `env` and redeploy. Acceptance includes a failed registration attempt.
- **Chrome `SYS_ADMIN`**: the chart's chrome container requests `SYS_ADMIN` (mitigated upstream by non-root, read-only rootfs, no exposure beyond ClusterIP). Accepted as a documented trade-off; revisit if upstream offers a sandboxed alternative. Meaningful pod isolation is impossible anyway until the namespace policy is refactored (Spin-outs, item B).

### D7. Explicitly out of scope

- **NetworkPolicy narrowing** -- Kubernetes policies are additive; `allow-intra-namespace` (`podSelector: {}`, `k3s.yml`) already permits everything, and hostNetwork Traefik cannot be pod-selected. Deferred to Spin-out B; this plan makes no isolation claims.
- **Authentik OIDC** -- follow-up after the service is stable; built-in auth with signups disabled first.
- **AI tagging (Ollama)** -- phase 2 (WP6); capture/search/persistence must work independently first.

## Repository changes

| File | Change |
|---|---|
| Bitwarden (external) | 2 items under `IRL/Services/` (D4); generate with the established BW generator, never shell history |
| `scripts/bw-sync-config.yaml` | 2 mappings (D4 table) |
| `ansible/playbooks/k8s-secrets.yml` | Two Secret tasks (ghostfolio clone, `k8s-secrets.yml:292-307`): `no_log`, guard requires **both** its vars (the guard-one-interpolate-two bug), plus an early `assert` naming missing keys only; update summary msg |
| `ansible/inventory/group_vars/all/main.yml` | `irl_services.karakeep` (subdomain `bookmarks`, `internal: false`, `cluster_svc: karakeep`, `cluster_port: 3000`, **`health_path: "/api/health"`**); `irl_traefik_standalone_services.karakeep`; ZFS dataset entries |
| `ansible/playbooks/zfs.yml` | Dataset creation + UID/GID chown tasks (D5) |
| `ansible/playbooks/k3s.yml` | Two labeled, retained, node-affine static PVs |
| `ansible/helm/karakeep/values.yaml` | New (see Values sketch) |
| `ansible/playbooks/helm-deploy.yml` | Add `karakeep` to the **values-directory loop** (~line 40-53) and helm repo list (`karakeep-app`); PVC definitions with selectors (paperless pattern); `ansible.builtin.copy` of values (peer pattern is copy, not template); `kubernetes.core.helm` task with `chart_ref: karakeep-app/karakeep`, `chart_version` pinned, `tags: [phase3, karakeep]`; rollout checks for all three workloads |
| `ansible/files/sanoid/sanoid.conf` | Snapshot coverage for both datasets (verify recursive coverage does not already apply) |
| `tests/` | `conftest.py` SERVICES + `test_dns.py` EXPECTED_RECORDS + exposure/persistence checks (CONTRIBUTING checklist) |
| `docs/homelab-access-guide.md`, `ansible/docs/runbooks/karakeep-service-down.md`, `ansible/docs/sops/backup-and-restore.md`, `CHANGELOG.md` | Ops documentation (WP5) |

## Values sketch (`ansible/helm/karakeep/values.yaml`)

```yaml
# Karakeep -- bookmarks/read-later. Official chart (bjw-s common 3.7.3 base), PINNED.
# SQLite on ZFS-backed PV; Meilisearch + headless Chrome bundled. No Postgres/Valkey.
applicationProtocol: https
applicationHost: bookmarks.lab.infiniteroomlabs.cloud

# INVARIANT (paired overrides -- change together or break the pod):
# 1. Chart-generated secrets are DISABLED because their randAlphaNum defaults re-roll
#    on every helm upgrade (session + Meilisearch auth loss). Values live in Bitwarden
#    -> karakeep-secrets / karakeep-meili-secrets (bw-sync + k8s-secrets.yml).
# 2. The envFrom list below REPLACES the chart's default refs to those disabled
#    secrets wholesale (Helm list semantics). Re-enabling chart secrets without
#    restoring envFrom (or vice versa) yields CreateContainerConfigError or re-rolled
#    secrets. Same list-replacement caveat applies to persistence mounts.
secrets:
  karakeep:
    enabled: false
  meilesearch:            # sic -- chart's own typo, must match
    enabled: false

defaultPodOptions:
  nodeSelector:
    irl.dev/tier: data    # PVs are node-local hostPath
  dnsConfig:              # alpine/musl + ndots:5 gotcha (see main.yml qbittorrent note)
    options:
      - name: ndots
        value: "1"

controllers:
  karakeep:
    type: deployment      # not statefulset: consume the IRL-managed static-PV claim
    replicas: 1
    strategy: Recreate    # RWO claim
    containers:
      karakeep:
        envFrom:
          - secretRef:
              name: karakeep-secrets
          - secretRef:
              name: karakeep-meili-secrets
        env:
          DISABLE_SIGNUPS: "false"   # flip to "true" after account bootstrap (WP4)
        resources:
          requests: { cpu: 200m, memory: 512Mi }
          limits: { cpu: 1000m, memory: 2Gi }
  chrome: {}              # keep chart defaults (incl. SYS_ADMIN trade-off, resources)

persistence:
  data:
    existingClaim: karakeep-data
    globalMounts:
      - path: /data

meilisearch:
  auth:
    existingMasterKeySecret: karakeep-meili-secrets   # key MEILI_MASTER_KEY
  persistence:
    enabled: true
    existingClaim: karakeep-meilisearch   # verify subchart support in WP1 render
  resources:
    requests: { cpu: 200m, memory: 512Mi }
    limits: { cpu: 1000m, memory: 2Gi }
  nodeSelector:
    irl.dev/tier: data

ingress:
  karakeep:
    enabled: false        # routed by Traefik IngressRoute (irl_traefik_standalone_services)
```

Exact paths (controller type switch, existingClaim keys, meilisearch subchart options) are render-verified in WP1; the sketch encodes intent, the render encodes truth.

## Work packages

### WP1: Pin and render-prove (gate for everything else)

1. Pin `chart_version`; record chart appVersion and all three image tags in the plan record.
2. `helm template` the pinned chart with the drafted values into a scratch file. Assert: no chart-generated Secret rendered; karakeep pod imports exactly the two IRL secrets; meilisearch reads `MEILI_MASTER_KEY` from `karakeep-meili-secrets` only; no Ingress rendered; Service is ClusterIP `karakeep:3000`; deployment (not statefulset) mounts `karakeep-data` at `/data`; meilisearch uses `karakeep-meilisearch`; dnsConfig, nodeSelector, and resources present on all pods.
3. Determine container UIDs for the chown tasks. Confirm whether `NEXT_PUBLIC_SECRET` is required (expect no).
4. Confirm `bookmarks` is unclaimed in `irl_services`, routes, PVs, Secrets; confirm ZFS free space covers the quotas.

**Exit:** rendered output matches design; any values path that did not survive the render is corrected here, not during rollout.

### WP2: Storage and secrets

1. ZFS datasets + chown (zfs.yml), static PVs (k3s.yml), sanoid coverage.
2. Create the two BW items; add bw-sync mappings; `mise run secrets:sync` (dry-run first).
3. `uv run ansible-playbook playbooks/k8s-secrets.yml`; verify Secret **names and keys only, never values**.
4. Confirm PVs `Available` before deploy.

### WP3: Wire and deploy

1. All `helm-deploy.yml` edits (values-dir loop, repo list, PVCs, copy, deploy task, rollout checks), group_vars entries, values file.
2. `cd ansible/ && uv run ansible-playbook playbooks/helm-deploy.yml --tags karakeep`
3. `--tags coredns,traefik` for the DNS record and IngressRoute. Note: the Traefik tag re-renders every standalone IngressRoute (blast radius: verify existing routes still serve); the CoreDNS record publishes only via the wildcard until Spin-out C lands.

### WP4: Verification

- Pods Running, PVCs bound to the intended labeled PVs, restart counts clean.
- In-pod external DNS resolution from the karakeep and chrome containers (ndots proof) **before** capture tests.
- `curl --fail --show-error https://bookmarks.lab.infiniteroomlabs.cloud/api/health` from a tailnet client, certificate hostname validated.
- Exposure: no public A/AAAA record (query a public resolver directly); no NodePort/LoadBalancer/Ingress/Funnel/Serve; document (not deny) LAN direct-IP + Host-header reachability pending Spin-out A.
- Functional: sign up, save a static page and a JS-heavy page -> screenshots render (chrome), search finds both (meilisearch).
- Then flip `DISABLE_SIGNUPS: "true"`, redeploy, assert registration fails.
- Durability: restart each pod and all pods -> data and search survive; rerun `--tags karakeep` -> still logged in and secret data hashes unchanged (proves the randAlphaNum fix; compare hashes, never print values).
- Restore drill: ZFS snapshot both datasets (atomic -> crash-consistent for SQLite/WAL), restore into a scratch path, verify bookmarks + assets return and the Meilisearch index either restores or rebuilds; record the rebuild steps.
- Repo smoke suite (`cd tests/ && task smoke`) before and after, to catch regressions to existing routes/DNS.

### WP5: Ops and docs

Runbook (`karakeep-service-down.md`: web/chrome/meilisearch/PVC/DNS/route/cert checks), backup SOP additions with restore ordering, access guide entry, CHANGELOG, tests (conftest/test_dns), PVC-usage and workload-availability alerts in the monitoring values.

### WP6 (optional, later): Ollama tagging

`OLLAMA_BASE_URL: http://ollama:11434`, `INFERENCE_TEXT_MODEL: llama3.2`, `INFERENCE_IMAGE_MODEL` decision (no vision model currently in-cluster); measure memory contention with chrome/meilisearch; confirm graceful behavior when Ollama is down.

## Rollback

- Before user data: `helm` rollback/uninstall via the Ansible task (never by hand), remove the two group_vars entries, re-run coredns/traefik tags; PVs, datasets, and BW items remain.
- After user data: disable the IngressRoute via desired state, snapshot both datasets, roll back the pinned `chart_version`/images, restore data if a migration is not backward-compatible, re-run WP4 before re-enabling ingress.
- Never delete PVCs, PVs, datasets, snapshots, or BW items as part of an application rollback.

## Upgrades

Deliberate `chart_version` bump: read release notes, fresh snapshots, render-diff old vs new (the `meilesearch` typo and envFrom contract may change -- that is what the pin is for), deploy in a window, rerun WP4 functional + idempotency checks.

## Spin-outs (homelab-wide, gate every service -- tracked separately, not Karakeep-blocking)

- **A. nftables interface scoping / dedicated tailscale listener.** Restrict 80/443 to `tailscale0` (blast-radius analysis across all services; DNS-01 needs no inbound) or add a Tailscale-bound entrypoint. Until it lands, nothing on this box is strictly Tailscale-only; when it lands, upgrade this plan's exposure tests from "document" to "assert fails".
- **B. `allow-intra-namespace` model decision.** Label-scoped allowances (touches every service) vs accepting namespace-wide reachability. Until decided, no service can honestly claim pod-level isolation.
- **C. CoreDNS zone serial.** The template serial is hardcoded (unchanged since March), so explicit records never publish and everything rides the `*` wildcard. Fix: epoch-derived serial and/or CoreDNS rollout-restart after ConfigMap changes.

## Definition of done

Karakeep is reproducibly deployed by Ansible from a pinned official chart; reachable at the internal HTTPS hostname from tailnet clients and absent from public DNS; persistent on retained, snapshotted ZFS storage with a tested restore; secrets Bitwarden-backed, split per consumer, and stable across upgrades; signups closed; capture, search, and restart-durability verified; documented in the runbook, SOP, access guide, tests, and changelog; and its known-cluster hazards (ndots, secret re-roll, wildcard DNS, LAN reachability) explicitly handled or honestly documented rather than assumed away.
