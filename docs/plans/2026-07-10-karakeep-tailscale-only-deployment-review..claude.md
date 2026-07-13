# Review: Karakeep Tailscale-Only Kubernetes Deployment Plan

**Plan under review:** `docs/plans/2026-07-10-karakeep-tailscale-only-deployment.md`
**Reviewer:** independent infrastructure plan review (claims verified against the repo and upstream Karakeep sources)
**Date:** 2026-07-10

## Verdict: needs-rework

The architecture and repo integration are largely correct and well matched to house conventions, and every upstream claim I checked (workload model, ports, env vars, secret key names, upstream defaults) verified accurately. But the plan's two central security promises -- "access through non-Tailscale interfaces fails" and "NetworkPolicies allow only the documented paths" -- are unsatisfiable against the cluster as it actually exists today, and the plan neither includes the changes that would make them true nor scopes the claims down. A third cluster-specific defect (musl/ndots DNS) will likely break the core page-capture acceptance criterion on first deploy. These are design-level gaps, not wording fixes, hence needs-rework -- though the rework is narrow: the Hostname/ingress, Network policy, and Secrets sections plus a few Repository Changes rows.

---

## Blockers

### B1. "Tailscale-only" acceptance criteria are false against the current firewall, and the plan includes no firewall change

Plan lines 100-105 state Tailscale-only access depends on "nftables accepts the Traefik listener through tailscale0 and rejects access through untrusted interfaces" remaining true. That condition is not currently true. `ansible/templates/nftables.conf.j2` renders every port in `irl_firewall_allowed_tcp_ports` as an unconditioned `tcp dport <port> accept` (no `iifname` restriction), and `ansible/inventory/group_vars/homelab/main.yml:8-10` includes 80 and 443 in that list. Traefik is `hostNetwork: true` (`ansible/helm/traefik/values.yaml:11`), so it is reachable on 80/443 from the home LAN (and any interface), not just tailscale0. A LAN client that sends SNI/Host `keep.internal.lab.infiniteroomlabs.cloud` (hosts-file entry or `curl --resolve`) reaches Karakeep; split DNS is the only thing standing in the way, and the plan itself correctly says DNS is not an access-control boundary (line 100).

Consequences in the plan as written:

- WP5 step 3 ("Verify ports 80 and 443 cannot reach Traefik through non-Tailscale interfaces", line 354) will fail.
- Acceptance criterion "Access through non-Tailscale interfaces fails" (line 428) will fail.
- The Repository Changes table (lines 282-296) contains no nftables/firewall change, so nothing in the plan can make these pass.

Required rework, one of:

1. Add a scoped firewall change (restrict 80/443 accepts to `iifname "tailscale0"`, relying on the existing unconditional tailscale0 accept) as an explicit work item -- with a blast-radius analysis, since it affects every HTTP service on the box, not just Karakeep (LAN-originated access to any `*.lab` service dies; check nothing besides the SMB scanner flow depends on LAN reachability, and note DNS-01 needs no inbound 80/443).
2. Or restate the boundary honestly as "split-DNS + tailnet, LAN-reachable at the TCP layer" and rewrite WP5.3 and the acceptance criterion to match reality.

### B2. The NetworkPolicy design cannot work: policies are additive, and `allow-intra-namespace` already allows everything the plan wants to forbid

Plan line 77 says Karakeep-specific NetworkPolicies "should narrow access around the three Karakeep workloads without breaking existing namespace-wide policies", and line 234 requires "Chromium and Meilisearch must not accept ingress from unrelated workloads"; WP5.6 (line 357) verifies "prohibited pod-to-pod paths fail". Kubernetes NetworkPolicies are union-of-allows: you cannot narrow by adding policies. `ansible/playbooks/k3s.yml:276-306` (`allow-intra-namespace`, `podSelector: {}`) already grants every pod in `irl` ingress from every other pod plus the `10.42.0.0/16` pod CIDR, and egress to all namespace pods. As long as that policy exists, any Karakeep-specific policy is a no-op for restriction: every pod in the namespace can already reach Chromium 9222 and Meilisearch 7700, and WP5.6 will fail.

Making the isolation real requires either scoping `allow-intra-namespace` (e.g., label-based opt-in, which touches every existing service) or accepting namespace-wide reachability and deleting the "prohibited paths fail" verification. The plan must pick one explicitly; as written it promises an outcome the CNI semantics forbid.

Related concrete defect in the traffic table (line 226): "Traefik -> Karakeep web TCP 3000" cannot be expressed as a podSelector rule. Traefik runs with `hostNetwork: true`, so its traffic arrives at pod IPs from the node's addresses, not from a Traefik pod IP -- this is exactly why the existing `ipBlock 10.42.0.0/16` clause in `allow-intra-namespace` (k3s.yml:295-297) exists. Any Karakeep ingress policy for Traefik must use an ipBlock for the node/pod CIDR, and that ipBlock cannot distinguish Traefik from any other host-network process.

### B3. The known alpine/musl + ndots:5 DNS failure will likely break page capture on first deploy, and the plan never mentions it

The upstream Chromium image is `gcr.io/zenika-hub/alpine-chrome:124` (verified in `kubernetes/chrome-deployment.yaml` upstream) -- musl-based -- and the Karakeep web image is also Alpine-based. Both must resolve arbitrary external hostnames to capture pages. This cluster has a documented, service-blocking history with exactly this failure mode (alpine/musl pods failing external DNS under k8s `ndots:5`; it is the reason the qBittorrent operator deployment is paused, per project memory and the comment at `ansible/inventory/group_vars/all/main.yml:168-172`). The plan's acceptance criterion "save a page, render it through Chromium" (line 427) is therefore at high risk of failing first try.

Fix: the `irl-karakeep` chart should set `dnsConfig` with `ndots: 1` (or equivalent FQDN handling) on the web and Chromium pod specs, and WP1/WP5 should include an explicit external-resolution test from inside both pods. This belongs in the plan, not as a surprise during rollout -- the repo already paid for this lesson once.

---

## Should-fix

### S1. The Bitwarden "one item with fields" model does not match bw-sync.sh

Plan lines 154-160: "Create a Bitwarden item under `IRL/Services/Karakeep` ... Add the item fields to `scripts/bw-sync-config.yaml`". bw-sync extracts exactly one value per item -- `.login.password` or a custom field literally named `password` (`scripts/bw-sync.sh:243`); the mapping schema (`scripts/bw-sync-config.yaml`) has `bw_item`/`ansible_var`/`k8s_secret`/`k8s_key` and no per-field selector. The established pattern is one BW item per secret value, several items fanning into one K8s Secret via distinct `k8s_key`s (see `paperless-secrets`, config lines 117-125 and 139-142). The plan needs three items (e.g., `karakeep-nextauth-secret`, `karakeep-meili-master-key`, `karakeep-next-public-secret`) each mapped to `karakeep-secrets`. Subfolder placement is fine -- bw-sync walks all IRL subfolders (`bw-sync.sh:220-230`).

### S2. Skipping the k8s-secrets.yml task breaks cluster-rebuild reproducibility

Plan line 160 and the Repository Changes row (line 287) treat extending `ansible/playbooks/k8s-secrets.yml` as optional. But `site.yml` provisions K8s Secrets from vault vars via k8s-secrets.yml (site.yml:65) before helm-deploy (site.yml:82); bw-sync's direct K8s write path is not part of site.yml. Every recent service precedent (paperless, firefly, ghostfolio -- k8s-secrets.yml:182-307) has both the bw-sync mapping and an explicit, `no_log`, conditionally-guarded k8s-secrets.yml task. Without the task, a from-scratch rebuild leaves `karakeep-secrets` missing until someone remembers to run bw-sync manually. Make the k8s-secrets.yml task unconditional in the plan.

### S3. First deploy will fail with "chart not found" unless the chart is published, not just pushed

helm-deploy.yml consumes IRL charts via the Helm repo (`chart_ref: irl/irl-<name>`, e.g. line 833), not the local submodule path. The paperless prerequisites comment (helm-deploy.yml:721-724) documents the exact failure: the submodule change must be "PUBLISHED to the chart-releaser GitHub Pages repo -- deploy will fail with 'chart not found' until push+publish". The plan's submodule instructions (lines 69, 276) cover commit/push/pointer-update but never mention the chart-releaser publish step. Add it to WP2 exit criteria or WP4 prerequisites.

### S4. Packaging decision never evaluates the official Karakeep Helm chart

Options considered (lines 59-62) are: vendor kustomize, generic app chart, custom `irl-karakeep` chart. The official chart (`karakeep-app/helm-charts`, `charts/karakeep`) is not among them. Having fetched its values: the custom-chart decision is in fact defensible -- the official chart defaults secrets to `{{ default (randAlphaNum 48) .Values.applicationSecretKey }}` (regenerated on upgrade unless pinned, exactly the account-lockout hazard the ghostfolio values file warns about at `ansible/helm/ghostfolio/values.yaml:35-38`), uses a generic Ingress rather than IngressRoute, and provisions storage via StatefulSet volumeClaimTemplates rather than static PVs. But per the house search-before-build rule, the plan should name the official chart and reject it for those concrete reasons, not omit it.

### S5. PVC binding needs the label/selector pattern spelled out

`zfs-local` is a no-provisioner StorageClass (k3s.yml:458-468); binding is by capacity/class matching unless constrained. Every existing consumer pairs PV labels (`app: <name>`, k3s.yml:378-380) with PVC `selector.matchLabels` (e.g., garage and paperless PVCs in helm-deploy.yml:242-282, 725-804). The plan's "The chart will create or bind claims named `karakeep-data` and `karakeep-meilisearch`" (line 148) specifies neither labels nor selectors, leaving room for a future Available PV to satisfy the wrong claim. Specify `app: karakeep` PV labels and matching PVC selectors, and decide (and state) whether PVCs live in the chart or in helm-deploy.yml like paperless/garage.

### S6. hostPath dataset ownership is unaddressed and conflicts with the non-root aspiration

The plan prefers non-root containers "if the image supports them" (line 208) but never plans ownership of the new dataset mountpoints. The paperless precedent explicitly chowns dataset paths to the container UID in zfs.yml (documented at main.yml:49-54). A non-root Karakeep or Meilisearch writing to a root-owned hostPath fails at startup. Add the chown step (with the chosen UIDs) to the ZFS work in WP3, or explicitly accept root containers.

### S7. /dev/shm emptyDir contradicts the upstream Chromium flags

Plan line 208 mounts an in-memory emptyDir at `/dev/shm` for Chromium; the upstream manifest runs Chromium with `--disable-dev-shm-usage` (verified in upstream `chrome-deployment.yaml`), which makes that mount dead weight. The plan's own flag-minimization instruction should call out the interaction: either keep `--disable-dev-shm-usage` and skip the mount, or drop the flag and size the mount. Also worth noting during WP1: the zenika alpine-chrome project appears unmaintained (image pinned at Chrome 124); evaluating a maintained headless-Chromium image should be an explicit WP1 task, not a parenthetical.

---

## Nits

- **N1. CoreDNS resolution relies on the wildcard, not the `internal` flag.** The zone template (`ansible/templates/coredns-internal-zone.db.j2`) emits `{{ subdomain }} IN A` under `$ORIGIN lab.infiniteroomlabs.cloud.` for internal services too -- i.e., an explicit record for `keep.lab...`, not `keep.internal.lab...`. The chosen hostname resolves only via the `* IN A` wildcard (template line 37), same as the existing internal services. "No change expected; verify" (line 290) is correct in effect, but the plan (and the DNS tests it adds) should state that `keep.internal.lab` is wildcard-backed, so nobody "fixes" the wildcard later and silently breaks every internal name.
- **N2. Homepage config file missing from Repository Changes.** WP7.1 (line 379) adds Karakeep to Homepage, but the table (lines 282-296) has no `ansible/helm/homepage/values.yaml` row.
- **N3. helm-deploy values-directory loop.** The "Create values override directories" loop (helm-deploy.yml:39-52) needs `karakeep` appended; the table row "Add the tagged Karakeep Helm release and rollout checks" arguably covers it, but it is the classic forgotten line -- name it.
- **N4. DNS rows in the NetworkPolicy table are redundant.** `allow-dns-egress` already grants namespace-wide DNS egress (k3s.yml:308-328). Harmless, but the plan presents them as new work.
- **N5. `NEXT_PUBLIC_SECRET` provenance.** It does exist in upstream `kubernetes/.secrets_sample` (verified), so the plan is faithful to its chosen spec -- but it is absent from both the official Helm chart and Karakeep's documented configuration, and a `NEXT_PUBLIC_`-prefixed "secret" is a Next.js smell. The plan's WP1 variable verification (line 176) should explicitly decide whether it is vestigial.

---

## Verified correct (credit where due)

- **Upstream workload model table (lines 27-33) is accurate**: web on 3000 with `/data`, Chromium on 9222, Meilisearch with `/meili_data`; `BROWSER_WEB_URL`/`MEILI_ADDR` wiring; separate `karakeep` namespace and LoadBalancer/Ingress defaults; kustomize-based. All confirmed against the upstream manifests and install docs.
- **Secret key names match upstream** `.secrets_sample` exactly (`NEXTAUTH_SECRET`, `MEILI_MASTER_KEY`, `NEXT_PUBLIC_SECRET`).
- **Ingress design matches house convention**: websecure-only + `letsencrypt` certResolver mirrors `ansible/templates/ingressroute-standalone.yaml.j2`; the wildcard cert really does cover `*.internal.lab.infiniteroomlabs.cloud` (traefik values.yaml:48); chart-owned IngressRoute for an irl-* chart matches the documented split (main.yml:196-197).
- **Scheduling and storage primitives check out**: `irl.dev/tier: data` label exists (k3s.yml:239); `zfs-local` + `Retain` + hostPath static PVs is the established pattern; Recreate strategy for RWO claims matches the Traefik precedent; dataset naming/mountpoints/properties follow `irl_zfs_datasets` conventions.
- **Secret hygiene intent is right**: existingSecret-only, no values in files/logs, `bw-sync.sh` as the only vault write path, `mise run secrets:sync` -- all consistent with repo rules; the plan never asks anyone to print a secret value.
- **`keep` is genuinely unclaimed** in `irl_services`, standalone IngressRoutes, and PV/Secret names.
- **Doc targets exist**: `tests/`, `CHANGELOG.md`, `docs/homelab-access-guide.md`, `ansible/docs/runbooks/`, `ansible/docs/sops/backup-and-restore.md` are all real paths.
- **Markdown style compliant**: no hard-wrapped prose, ASCII-clean, Mermaid for the diagram.

## Summary of required rework

1. Resolve the firewall contradiction (B1): add a scoped nftables change with blast-radius analysis, or honestly rescope "Tailscale-only" and the WP5/acceptance language.
2. Redesign the NetworkPolicy section (B2) around additive semantics and hostNetwork Traefik: either scope `allow-intra-namespace` (cluster-wide change, own work item) or drop the "prohibited paths fail" promise.
3. Add the musl/ndots `dnsConfig` mitigation and in-pod external-DNS verification (B3).
4. Fold in S1-S7 (three BW items not one; unconditional k8s-secrets.yml task; chart publish step; official-chart evaluation; PV label/PVC selector; dataset chown; /dev/shm flag interaction).
