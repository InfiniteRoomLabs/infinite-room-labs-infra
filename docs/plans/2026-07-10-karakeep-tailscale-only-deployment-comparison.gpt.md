# GPT Comparison: Karakeep Tailscale-Only Deployment Plans and Reviews

**Date:** 2026-07-10
**Inputs:** Primary plan, alternate plan, and the GPT and Claude independent reviews of each plan
**Recommendation:** Use the alternate plan as the implementation base, then add the primary plan's production-readiness controls and resolve the access-boundary design before implementation.

## Executive Conclusion

The alternate plan is the better implementation base, but it needs several production and security sections imported from the primary plan. Neither plan is ready unchanged.

The best final plan is an official, pinned, render-tested Karakeep Helm chart with IRL-managed secrets, deterministic ZFS-backed storage, explicit backup and restore, corrected DNS behavior, and a real decision about what "Tailscale-only" means at the firewall and ingress layers.

## Overall Comparison

| Area | Primary plan | Alternate plan | Recommended direction |
|---|---|---|---|
| Packaging | New `irl-karakeep` chart | Official Karakeep chart | Official chart |
| Detail | Full production lifecycle | Short deployment recipe | Alternate implementation plus primary lifecycle |
| Secrets | Good intent, incorrect Bitwarden field model | Correctly handles chart-generated-secret hazard | Alternate model with split Kubernetes Secrets |
| Storage | Retained ZFS PV design | Default chart PVCs | Primary storage design adapted to the official chart |
| Backups | Included but underspecified | Mostly absent | Expand primary design with a real off-pool backup |
| Networking | Detailed but incompatible with current policies | Mostly omitted | Redesign after deciding namespace and isolation model |
| Tailscale restriction | Explicit acceptance tests, false assumption about firewall | Claims it is inherited automatically | Neither; firewall or listener design is required |
| Operations | Strong rollout, rollback, upgrade, and runbook coverage | Thin | Preserve primary coverage |
| Implementation accuracy | Several repository integration errors | Strong upstream-chart research with a few concrete mistakes | Corrected alternate approach |
| Maintainability | Owns another chart | Tracks a supported upstream chart | Official pinned chart |

## Plan Comparison

### Primary plan

The primary plan's strongest contribution is not the custom chart. It is the operational envelope:

- Work packages with exit criteria.
- Persistent ZFS storage.
- Image pinning.
- Resource and probe design.
- Registration closure.
- Backup and restore testing.
- Exposure tests.
- Rollback and upgrade procedures.
- Monitoring, runbooks, and documentation.
- AI integration deferred until the base system works.

That makes it a useful production-readiness specification.

Its central weakness is that it designs from the generic upstream Kustomize manifests without considering the official Helm chart. That violates the repository's search-before-build convention and creates unnecessary chart ownership.

It also contains several factual design errors:

- The current firewall does not restrict Traefik ports 80 and 443 to `tailscale0`.
- Additional NetworkPolicies cannot narrow access already allowed by the namespace-wide `allow-intra-namespace` policy.
- One Bitwarden item with several mapped custom fields is unsupported by the current synchronization schema.
- Static PV matching is not deterministic without selectors, `volumeName`, or equivalent binding.
- Dataset UID and GID ownership is unspecified.
- The proposed `/dev/shm` mount conflicts with retaining `--disable-dev-shm-usage`.
- Publishing a new IRL chart requires the chart-releaser path, not only a submodule commit.
- The Alpine/musl `ndots:5` failure already encountered elsewhere in this cluster is not addressed.

The custom chart could be made to work, but the reviews provide no compelling reason to accept that maintenance cost.

### Alternate plan

The alternate plan's strongest contribution is upstream-specific implementation research:

- It found the official chart.
- It verified the bjw-s value structure.
- It identified the chart's `meilesearch` typo.
- It identified the `randAlphaNum` secret-regeneration hazard.
- It correctly disables the upstream Ingress.
- It correctly replaces the chart's `envFrom` list.
- It correctly identifies the generated Service names.
- It closely follows the existing Firefly and Ghostfolio deployment pattern.

This is a smaller and more maintainable starting point.

Its weakness is that it treats "the UI came up" as nearly equivalent to successful integration. It omits or underspecifies:

- Chart-version pinning.
- Durable retained ZFS storage.
- Backup and restore.
- Resource limits and scheduling.
- NetworkPolicy behavior.
- Chrome capabilities and isolation.
- Registration closure.
- Monitoring and alerting.
- Runbooks.
- Upgrade and rollback behavior.
- Direct-IP and Host-header exposure testing.
- Database consistency.
- PVC lifecycle and uninstall behavior.

It also contains concrete implementation mistakes:

- It says to add Karakeep to a nonexistent "valid tags list"; the actual location is the values-directory loop.
- It does not clearly add `karakeep` to that directory loop, which can cause the values copy to fail.
- It uses an unpinned chart contract.
- It conflates copying and templating the values file.
- It assumes rerunning CoreDNS produces a new explicit record, while current behavior depends on the wildcard and a static SOA serial.
- It puts `NEXTAUTH_SECRET` into the same Secret imported wholesale by Meilisearch.
- It omits `health_path: /api/health`.
- It uses non-ASCII prose against repository instructions.

## Review Comparison

### Primary-plan reviews

The GPT and Claude reviews of the primary plan substantially agree. Both independently identify the two most important blockers:

1. Traefik uses `hostNetwork`, while nftables accepts ports 80 and 443 without an interface restriction.
2. Kubernetes NetworkPolicies are additive, so Karakeep policies cannot undo the existing namespace-wide allowance.

They also agree on:

- Unsupported Bitwarden field mapping.
- Missing filesystem ownership.
- Nondeterministic PV/PVC binding.
- The need to evaluate the official chart.
- The need to update `k8s-secrets.yml` for rebuild reproducibility.
- DNS behavior being more subtle than the plan states.

The GPT review is stronger on lifecycle and security completeness:

- Off-pool backup versus same-pool snapshots.
- SQLite consistency.
- IPv4 and IPv6 SSRF exclusions.
- Initial signup closure.
- Version selection as a hard gate.
- Service accounts and token automounting.
- Upgrade downtime and probe semantics.
- Certificate-transparency implications.
- Concrete rollback mechanics.

The Claude review is stronger on repository-specific deployment traps:

- Alpine/musl `ndots:5`.
- Chart publishing.
- CoreDNS wildcard behavior.
- Exact Bitwarden precedent.
- PVC label and selector precedent.
- Chromium `/dev/shm` contradiction.
- Missing values-directory and Homepage entries.

Together they provide a credible rejection of the primary plan as written.

### Alternate-plan reviews

The GPT and Claude reviews of the alternate plan diverge more significantly.

The GPT review says to revise before implementation and treats several omissions as blockers:

- Values-directory setup.
- An unpinned mutable chart.
- An unproven Tailscale-only boundary.
- Inadequate durability and recovery.
- Unsafe or redundant secret synchronization.
- Missing workload security review.
- Missing networking, resources, scheduling, and operational coverage.

That judgment is closer to correct for production infrastructure.

The Claude review says "ship-with-fixes." It provides excellent verification of the official chart's exact behavior, including:

- The typo is real.
- The generated-secret bug is real.
- The bjw-s override paths work.
- The Service names resolve as expected.
- The `envFrom` replacement works.
- The Meilisearch existing Secret works.
- The bw-sync aggregation model works.

However, its statement that the Tailscale-only claim holds by construction conflicts with repository evidence cited by both primary reviewers. Split DNS, ClusterIP Services, and lack of NodePort do not prevent a LAN client from addressing host-network Traefik directly with the appropriate SNI and Host header. The unconditional nftables acceptance of ports 80 and 443 is decisive.

Therefore, the Claude alternate review is reliable for Helm-chart mechanics, but not for its ingress-security conclusion or overall readiness rating.

## Cross-Review Consensus

The most reliable findings are those supported across reviews or by direct repository mechanics:

1. Use the official chart instead of immediately creating `irl-karakeep`.
2. Pin the chart and review its complete rendered output.
3. Disable the chart-generated Secrets.
4. Do not store secret values in committed Helm values.
5. Use the repository's Bitwarden mapping model.
6. Correct the values-directory and Helm repository integration.
7. Treat DNS as discovery, not access control.
8. Redesign or honestly rescope Tailscale-only ingress.
9. Do not claim restrictive Karakeep NetworkPolicies while the blanket namespace policy exists.
10. Define storage ownership, deterministic binding, backup, and restore before deployment.
11. Test page capture, search, restart, upgrade, secret stability, and outside-tailnet direct-IP access.
12. Close signups after controlled bootstrap.
13. Handle the known Alpine DNS behavior.
14. Add operational documentation and monitoring.

## Recommended Merged Architecture

Use the official chart, but override the parts that conflict with IRL requirements:

- Pin an exact chart version and dependency tree.
- Disable upstream-generated Secrets.
- Disable upstream Ingress.
- Use the existing standalone Traefik IngressRoute.
- Split authentication and Meilisearch secrets:
  - `karakeep-secrets`: `NEXTAUTH_SECRET`.
  - `karakeep-meili-secrets`: `MEILI_MASTER_KEY`.
- Import both Secrets into Karakeep, but only the Meilisearch Secret into Meilisearch.
- Verify whether `NEXT_PUBLIC_SECRET` is actually required by the chosen chart and version before creating it.
- Replace chart storage defaults with ZFS-backed claims or prove that the chart can bind explicitly to IRL-managed claims.
- Pin workloads to the data node.
- Add explicit dataset ownership.
- Set `dnsConfig.options.ndots: "1"` where required.
- Add `health_path: /api/health`.
- Disable signups after controlled account bootstrap.
- Add resources, probes, security contexts, backup, restore, monitoring, and upgrade tests.

## Unresolved Architectural Decision

Before merging the plans, decide what "Tailscale-only" means.

### Strict interpretation

Karakeep must reject all non-tailnet clients, including home-LAN clients capable of reaching the homelab node.

This requires one of:

- Restricting shared Traefik ports 80 and 443 to `tailscale0`, after analyzing the effect on every existing service.
- A dedicated Tailscale-only Traefik entrypoint and listener.
- A separate ingress controller bound only to the Tailscale address.
- A carefully validated application-layer IP allowlist with correct proxy trust handling.

A dedicated Tailscale-bound ingress listener is likely the least surprising long-term design because it does not change the reachability of every existing service.

### Loose interpretation

Karakeep is not publicly advertised or exposed, but remains technically reachable from the trusted home LAN by direct address and Host/SNI override.

If that is acceptable, call it "tailnet-discoverable and non-public," not strictly Tailscale-only, and remove the false interface-level acceptance tests.

## Final Recommendation

Promote the alternate plan as the implementation skeleton, then merge the primary plan's production-readiness sections into it.

Before implementation, make these decisions and corrections mandatory:

1. Select strict Tailscale-only versus trusted-LAN-plus-tailnet access.
2. Pin the official chart and render-test it.
3. Split the Secrets and document the load-bearing list replacements.
4. Replace default storage with deterministic ZFS-backed persistence.
5. Specify off-pool backup and SQLite-consistent restore.
6. Decide whether Karakeep needs a dedicated namespace for meaningful NetworkPolicy isolation.
7. Add Alpine DNS mitigation.
8. Add resources, scheduling, signup closure, monitoring, runbooks, upgrade, rollback, and exposure tests.

This merged direction produces less custom code than the primary plan and materially better operability than the alternate plan.
