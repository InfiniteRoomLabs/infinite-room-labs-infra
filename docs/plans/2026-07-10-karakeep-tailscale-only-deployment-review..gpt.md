# Review: Karakeep Tailscale-Only Kubernetes Deployment Plan

**Review date:** 2026-07-10
**Reviewed plan:** `docs/plans/2026-07-10-karakeep-tailscale-only-deployment.md`
**Recommendation:** Revise before implementation

## Summary

The plan has a sound workload decomposition, appropriate persistence intent, deliberate image pinning, a useful staged rollout, and unusually strong acceptance and rollback sections. It also correctly recognizes that internal DNS is not an access-control boundary.

Two current-repository facts make the stated security design unachievable as written. First, nftables accepts TCP 80 and 443 from every interface, so Traefik's host-network listeners are reachable from the LAN and potentially any other routed interface. Second, the existing `allow-intra-namespace` NetworkPolicy selects every pod and permits all same-namespace ingress and egress. Kubernetes combines allowed traffic across matching policies, so additional Karakeep policies cannot narrow that access. These are blockers, not implementation details.

The plan also assumes a Bitwarden item-field synchronization model that the current `bw-sync-config.yaml` schema does not expose, omits required filesystem ownership design for the new ZFS datasets, and describes snapshots as backups without identifying an actual independent backup destination. Those issues should be resolved in the plan before chart work begins.

## Blocking Findings

### 1. The current firewall exposes Traefik on non-Tailscale interfaces

The plan states that nftables accepts the Traefik listener through `tailscale0` and rejects it through untrusted interfaces. The repository currently does the opposite for the relevant ports:

- `ansible/helm/traefik/values.yaml` uses `hostNetwork: true` and binds ports 80 and 443 on the node.
- `ansible/inventory/group_vars/homelab/main.yml` includes 80 and 443 in `irl_firewall_allowed_tcp_ports`.
- `ansible/templates/nftables.conf.j2` accepts every port in that list without an interface or source restriction.

A client that can route to the node's LAN address can bypass split DNS by sending the Karakeep Host header or by overriding local resolution. A ClusterIP backend and an internal-only DNS record do not prevent this.

The plan must choose and specify an enforceable ingress design. The most direct repository-aligned change is to model firewall rules by interface or source class, permit 80/443 only on `tailscale0`, and explicitly decide how existing public services remain reachable. That is a broader platform change because the same Traefik instance serves public hostnames. If existing public services must remain reachable from the LAN or internet, a single listener cannot distinguish Karakeep safely at nftables by hostname. In that case use separate entrypoints/listen addresses, a dedicated Tailscale-only ingress controller, or an application-layer source-IP middleware whose trusted-forwarding behavior is precisely documented and tested. The plan should not claim Tailscale-only until one of these is designed.

Add an explicit repository change for the chosen firewall/Traefik mechanism. The current table incorrectly predicts no such file change.

### 2. Karakeep NetworkPolicies cannot narrow the namespace-wide allow policy

`ansible/playbooks/k3s.yml` creates `allow-intra-namespace` with `podSelector: {}` and allows ingress from any pod in `irl` plus egress to any pod in `irl`. NetworkPolicy permissions are additive. A second policy selecting Karakeep pods can only add allowed paths; it cannot subtract the paths already granted by `allow-intra-namespace`.

Therefore the proposed claims that Chromium and Meilisearch will reject unrelated workloads, and that Karakeep-specific policies will narrow access, are false under the present policy set. WP5 tests for prohibited pod-to-pod paths will fail.

The plan must include a namespace policy refactor before Karakeep policy implementation. Replace the blanket policy with label-based allowances for existing applications, or isolate Karakeep in a dedicated namespace with its own default-deny baseline. The latter conflicts with the current namespace decision but is likely the lower-risk way to obtain meaningful isolation without simultaneously rewriting every existing service policy. If a dedicated namespace is selected, the plan must update secret synchronization, Traefik-to-Karakeep cross-namespace routing, DNS assumptions, monitoring, and Ansible deployment conventions accordingly.

### 3. The proposed Bitwarden item-field model does not match `bw-sync-config.yaml`

The plan says to create one item under `IRL/Services/Karakeep`, generate three independent values as fields, and add those item fields to `scripts/bw-sync-config.yaml`. The current schema maps one `bw_item` to one password value, one Ansible variable, and one Kubernetes Secret key. Existing entries use separate Bitwarden item names for each value. No field selector is present in the configuration shown by the repository.

Resolve this by either:

- using three separate Bitwarden items, each mapped to a key in `karakeep-secrets`; or
- explicitly extending and testing `bw-sync.sh` and its configuration schema to select named custom fields from a single item.

The first option is consistent with the repository and should be the default. The plan should list the exact Kubernetes Secret key names and how the chart maps each key to the exact environment variable. It should also distinguish direct Kubernetes synchronization by `bw-sync.sh` from the older `k8s-secrets.yml` Ansible-Vault path. If direct sync is authoritative, no `k8s-secrets.yml` change should be proposed.

### 4. Storage provisioning omits container ownership and binding guarantees

ZFS datasets are created root-owned. `ansible/playbooks/zfs.yml` contains an explicit ownership task for Paperless because root-owned hostPath datasets otherwise break non-root containers. The Karakeep plan asks for non-root security contexts but does not specify UID/GID ownership, `fsGroup` behavior, or an Ansible ownership task for either dataset. `fsGroup` behavior on hostPath should not be assumed.

WP1 must identify the runtime UID/GID for the pinned Karakeep and Meilisearch images. WP3 must provision ownership and modes explicitly, without recursive ownership changes on every normal run after the datasets contain substantial data. The security context and filesystem ownership must be designed together.

The static PV/PVC design should also use deterministic binding. `storageClassName: zfs-local` and matching capacity alone allow Kubernetes to choose any compatible available PV. Set `volumeName` in each PVC, `claimRef` in each PV, or unique selector labels, and include `nodeAffinity` on local PVs. A pod `nodeSelector` is useful but is not a substitute for PV node affinity and topology semantics.

## High-Priority Findings

### 5. The backup requirement is not backed by an off-dataset or off-host design

The existing `ansible/docs/sops/backup-and-restore.md` mostly documents local ZFS snapshots and contains stale Docker examples. A snapshot on the same pool is not an independent backup against pool loss. The plan says to use the existing backup system but leaves ownership and recovery objectives as an open question, while its acceptance criteria already require backup and restore testing.

Before implementation, identify the actual backup target, transport, retention, encryption, consistency method, and restore host/path. Decide whether Karakeep must be quiesced for a consistent SQLite snapshot and whether Meilisearch should be stopped, dumped, or rebuilt rather than copied live. Specify an RPO and RTO. WP6 should test restoration from the independent backup artifact, not merely rollback a same-pool snapshot.

Sanoid coverage is also not automatic merely because a child dataset exists. The plan must add the datasets to `ansible/files/sanoid/sanoid.conf` or prove that recursive template coverage applies.

### 6. The plan does not resolve application database consistency

Karakeep `/data` is described as containing database and application state, but the plan does not name the database engine, migration model, or backup consistency mechanism for the pinned release. If this is SQLite, copying a live dataset may capture WAL-related state and requires an upstream-supported backup procedure or quiesced snapshot. If the selected release has moved to another storage model, the chart and restore ordering may differ.

Add the database format and supported backup/restore procedure to the WP1 compatibility matrix. The rollback procedure must state when an application rollback also requires a data rollback and how to prevent an older application version from opening newer migrated data.

### 7. Egress policy design needs explicit CIDRs and IPv6 treatment

The plan correctly identifies SSRF risk but leaves the actual private-range exclusions to implementation. That is too late for a security acceptance criterion. Define the current pod CIDR, service CIDR, LAN CIDR, Tailscale CGNAT range, link-local ranges, loopback, metadata endpoints, and all IPv6 private/link-local ranges. Confirm kube-router behavior for `ipBlock.except`, service translation, DNS targets, and dual-stack traffic.

Also decide whether the application genuinely needs direct web egress in addition to Chromium. Permit only the component and ports required by the pinned release. Include tests for blocked access to the Kubernetes API, node addresses, cluster Services, LAN hosts, tailnet peers, and cloud metadata-style addresses, not just a generic failed internet request from Meilisearch.

### 8. Initialization and registration closure are operationally underspecified

"Disable open registration after the initial administrative account is created, if supported" leaves an unsafe window and makes desired state depend on a manual action. WP1 must determine the exact supported bootstrap and registration settings before deployment. Prefer an explicit initial-admin procedure with registration disabled in desired state, or a tightly bounded maintenance procedure that verifies registration is closed before ingress acceptance.

Acceptance should include an unauthenticated registration attempt that fails. The runbook should document credential recovery without exposing or regenerating secrets blindly.

### 9. Version selection should happen before chart behavior is designed

The chart skeleton may be created before all open questions are answered, but probes, environment variables, container ports, security contexts, migration behavior, browser flags, and secret keys all depend on exact upstream versions. WP1 should be a hard gate for workload templates, not merely an exit criterion running alongside chart creation.

Pin image digests, not just tags, for all three images unless the registry or update workflow makes that impractical. Record image source, architecture support for the data node, license, upstream support relationship, and signature/SBOM verification policy. Chart `appVersion` and release notes should reflect the selected Karakeep version.

## Medium-Priority Findings

### 10. The chart resource inventory is incomplete

The proposed tree does not show PodDisruptionBudgets, ServiceAccounts, ConfigMaps, test hooks, monitoring rules, or alert resources. Not all are necessarily required, but the plan promises availability alerts, PVC alerts, chart tests, and a narrow security posture. State whether these live in the chart, `ansible/helm/monitoring/values.yaml`, or Ansible-created ConfigMaps/PrometheusRule resources.

Use dedicated ServiceAccounts with `automountServiceAccountToken: false` for all three workloads unless Kubernetes API access is proven necessary. Add this as an acceptance assertion. Add `seccompProfile: RuntimeDefault`, dropped capabilities, read-only roots where supported, and explicit writable mounts. Chromium exceptions should be documented per image rather than silently weakening all workloads.

### 11. `Recreate` avoids one RWO rollout problem but needs downtime semantics

With one replica and node-local RWO storage, `Recreate` is reasonable. The plan should state the expected outage and Helm/Deployment timeout behavior. Meilisearch shutdown grace and Karakeep migration completion need suitable `terminationGracePeriodSeconds` and lifecycle handling. Acceptance should test a normal upgrade rollout, not only restarts.

### 12. Probe definitions need to avoid false health

A root-page probe can report success while migrations, Meilisearch, or Chromium integration are broken, and it may redirect to authentication. WP1 should record exact status codes and dependency semantics. Liveness should test process health only and should not restart Karakeep merely because Meilisearch or the internet is unavailable. Readiness may reflect the minimum dependencies required to serve safely. Probe tests should include dependency failure and recovery.

### 13. DNS wording and tests should distinguish authoritative absence from resolver behavior

The current CoreDNS template serves both public-style and internal names from one zone file with `$ORIGIN lab.infiniteroomlabs.cloud`, and it includes a catch-all wildcard in the private view. The requested internal hostname will work when rendered from `irl_services`, but tests should query the configured Tailscale resolver directly and a named public recursive resolver directly. A negative public response may be cached; assert NXDOMAIN or NODATA explicitly and ensure no public wildcard or record covers the name.

The CoreDNS zone serial is currently static. Adding a record may not cause downstream caches to recognize a zone change predictably. Include a serial update strategy or confirm that pod/config reload behavior makes the serial irrelevant for this deployment.

### 14. Certificate privacy and issuance behavior should be acknowledged

The existing wildcard SAN appears to cover the hostname, so the IngressRoute should reuse the resolver-backed certificate rather than require a unique hostname certificate. The plan should verify this in rendered Traefik configuration and note that public certificate transparency reveals wildcard domain structure even though no public A record exists. This is not an access-control failure but is relevant to the plan's privacy language.

### 15. Homepage timing conflicts with the repository change list

WP1 says to confirm `keep` is unused in Homepage, and WP7 says to add Karakeep to Homepage, but the repository change table omits `ansible/helm/homepage/values.yaml`. Add it explicitly. Because Homepage is currently public-facing, decide whether showing an internal service there leaks service metadata or creates a confusing unreachable link for non-tailnet users.

### 16. Resource validation needs a node-capacity gate

The proposed limits permit roughly 5 GiB of memory and 3.5 CPU across these workloads, before existing services and Ollama. Add a preflight using allocatable node resources and current requests/usage. Define an eviction/headroom threshold and test Chromium under concurrent captures. Do not rely only on post-deployment tuning.

### 17. Rollback through Ansible needs a concrete mechanism

"Roll back or uninstall through Ansible" and "remove or disable the IngressRoute through desired state" are outcomes, not procedures supported by an identified variable or tag. Define chart values such as `ingress.enabled`, release state control, and the Ansible path for an uninstall. Otherwise an emergency operator may resort to hand changes that the plan forbids.

## Sequencing Corrections

Use this order instead of beginning chart implementation while the foundational questions remain open:

1. Resolve the ingress boundary design and prove non-Tailscale rejection against the existing shared Traefik deployment.
2. Resolve namespace isolation and remove the blanket policy conflict, or choose a dedicated namespace.
3. Pin the three upstream images and complete the compatibility matrix, including architecture, environment variables, ports, probes, UID/GID, browser flags, migrations, and registration controls.
4. Define independent backup/restore and consistency semantics with RPO/RTO.
5. Define exact Bitwarden items, Kubernetes Secret keys, and the single authoritative synchronization path.
6. Implement ZFS datasets, ownership, Sanoid coverage, PV node affinity, and deterministic claim binding.
7. Implement and test the chart offline with schema validation, linting, rendering, policy tests, and secret/exposure assertions.
8. Deploy secrets, storage, DNS, workloads, and ingress in that order, initially with ingress disabled or otherwise unreachable to users.
9. Run functional, security, restart, upgrade, backup, and restore tests.
10. Enable ingress only after registration is closed and the Tailscale-only boundary passes from both allowed and denied networks.

## Required Test Improvements

The acceptance list is good but needs executable definitions and negative controls. Add named tests with expected results for:

- LAN-IP HTTPS request with the Karakeep Host header fails at the network boundary.
- Tailscale-IP HTTPS request with the same Host header succeeds.
- Public resolvers return NXDOMAIN or NODATA while the Tailscale split resolver returns the expected Tailscale address.
- No Service type, host port, host network workload other than the intended Traefik path, Ingress, Gateway, Funnel, or Serve configuration exposes Karakeep.
- An unrelated pod in `irl` cannot reach Chromium or Meilisearch after the namespace policy redesign.
- Karakeep can reach only required Meilisearch and Chromium ports, not arbitrary ports on those pods.
- Web and Chromium cannot reach pod, service, node, LAN, tailnet, link-local, or metadata destinations, while approved public HTTP/HTTPS capture works.
- Meilisearch has no DNS or internet egress unless an upstream requirement is documented.
- Pods do not mount service-account tokens and satisfy the intended security contexts.
- PVCs bind to the named PVs on the data node and cannot schedule on the DigitalOcean node.
- A fresh deployment bootstraps safely with registration closed, and a second unauthenticated user cannot register.
- Dependency outages do not trigger destructive liveness loops and recover without manual data repair.
- A pinned-version upgrade preserves login, capture, search, and data.
- Restore uses the independent backup destination into an isolated validation location and verifies application data plus either restored or rebuilt search state.
- Helm and Ansible reruns are idempotent and do not rotate secrets, replace retained volumes, reopen registration, or broaden exposure.

For automated manifest checks, consider `helm lint`, `helm template`, Kubernetes schema validation, policy assertions over rendered YAML, and existing repo test-task integration. The exact tool should follow repository policy, but the test must fail on `LoadBalancer`, `NodePort`, `hostPort`, floating image tags, missing resource controls, embedded Secret values, and absent security settings.

## Plan Strengths Worth Preserving

- Correct separation of application data and reconstructable search data.
- Explicit `Retain` policy and a prohibition on destructive rollback cleanup.
- Deliberate image upgrades rather than floating tags.
- AI integration deferred until the core workload is stable.
- Recognition of Chromium resource and sandboxing risk.
- Negative exposure checks included in acceptance criteria.
- Backup-before-upgrade and migration-aware rollback intent.
- Clear ownership boundaries between Ansible, the Helm submodule, and secret synchronization.

## Approval Conditions

The plan is ready for implementation after it is revised to:

1. provide a concrete Tailscale-only ingress boundary compatible with shared Traefik and the actual nftables rules;
2. resolve the additive NetworkPolicy conflict;
3. define a supported Bitwarden-to-Secret mapping;
4. specify dataset ownership, PV node affinity, and deterministic PVC binding;
5. identify an independent, consistency-safe backup and tested restore path;
6. make version compatibility a gate before workload template implementation; and
7. turn the key security and recovery claims into reproducible positive and negative tests.
