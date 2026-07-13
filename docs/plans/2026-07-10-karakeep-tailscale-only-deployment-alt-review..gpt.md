# Review: Karakeep Tailscale-only deployment alternate plan

## Verdict

The plan has a useful low-complexity direction, but it is not implementation-ready. Reusing the official chart and the repository's standalone Traefik pattern is feasible, and the proposed stable secret ownership addresses a real chart defect. However, the plan currently contains at least one deployment blocker, does not prove the Tailscale-only security claim, omits the repository's persistence and backup expectations, and provides too little pre-deploy rendering and rollback validation for an unpinned upstream chart.

The recommended disposition is "revise before implementation." Keep the upstream-chart approach as an explicit alternative to an IRL wrapper chart, but add a chart-version decision, render tests, durable storage and backup design, network controls, and exact secret/deployment sequencing.

## What is sound

- `karakeep-app/karakeep` is an official upstream Helm chart and does deploy Karakeep, Chrome, and a Meilisearch dependency. It uses the bjw-s common library, so the general shape of `controllers`, `service`, `ingress`, and StatefulSet claim overrides is credible.
- The chart really does generate `NEXTAUTH_SECRET` and `MEILI_MASTER_KEY` when `applicationSecretKey` and `meilisearchMasterKey` are unset. Treating both as durable Bitwarden-backed values is correct.
- Disabling the chart ingress and using `irl_traefik_standalone_services` matches Firefly and Ghostfolio, which are also upstream charts without IRL-owned ingress templates.
- Adding the service to `irl_services` is the repository's established input for the CoreDNS zone and health-check generation.
- SQLite is a supported simple deployment model for Karakeep. Avoiding unnecessary PostgreSQL and Valkey dependencies is reasonable for an initial single-node installation.

## Blocking findings

### 1. `helm-deploy.yml` will not upload the values file successfully

The plan adds `ansible/helm/karakeep/values.yaml` and later copies it to `{{ helm_values_path }}/karakeep/values.yaml`, but it does not add `karakeep` to the `Create values override directories` loop near the start of `helm-deploy.yml`. A targeted `--tags karakeep` run still executes the directory task because it is tagged `always`, but without the missing loop item the copy destination directory will not exist.

Add `karakeep` to that loop and include this file change in the plan's change count.

### 2. The plan assumes an unpinned, mutable chart contract

The proposed values depend on exact implementation details in the current upstream chart, including the misspelled `secrets.meilesearch`, release-derived service names, envFrom behavior, and bjw-s common-library merge semantics. At the time of review, the official values file uses `applicationSecretKey`, `meilisearchMasterKey`, secrets named `<release>` and `<release>-meilesearch`, and default envFrom references to both generated Secrets. The override may work because the replacement envFrom points at a single Secret containing both keys, but this must be proven by rendering, not inferred.

Firefly and Ghostfolio being unpinned is not a reason to add another unpinned dependency. This chart's contract is unusually fragile and its defaults include an old Chrome image. Pin a tested `chart_version`, record the corresponding app version, and make upgrades explicit. If the team deliberately accepts floating versions, the plan needs a risk statement and a render/conformance gate before every deployment.

### 3. The Tailscale-only claim is asserted, not tested end to end

The hostname uses `bookmarks.lab.infiniteroomlabs.cloud`, which is the repository's `irl_public_domain`, and the IngressRoute requests a publicly valid Let's Encrypt certificate. Internal CoreDNS resolution alone does not establish that the listener cannot be reached through another interface or a public DNS record. The plan relies on existing host networking and nftables policy but does not inspect or test the actual listener addresses, public DNS state, router forwarding, NodePort/LoadBalancer absence, or direct-IP access with a forged Host header.

The acceptance suite must prove all of the following: no public A/AAAA/CNAME record exists; the Service is ClusterIP; no Ingress, LoadBalancer, NodePort, Tailscale Serve, or Funnel resource exposes it; ports 80/443 are unreachable through non-tailnet interfaces; and a request to every non-tailnet host address with `Host: bookmarks.lab.infiniteroomlabs.cloud` fails. A DNS failure from one non-Tailscale client is insufficient because it tests discovery rather than reachability.

### 4. Durable data and recovery are underdesigned

The plan creates dynamic `local-path` PVCs of 10 GiB and 2 GiB but does not say where those volumes land, whether they are on the protected ZFS pool, how they are backed up, how SQLite consistency is maintained, or how a restore is tested. Karakeep's database, archived content, assets, and search state are the reason to deploy the service; a deployment plan without restore criteria is incomplete.

Choose and document durable storage. In this repository that likely means dedicated ZFS datasets and retained static PVs, or a clearly justified local-path layout covered by an existing backup mechanism. Back up the Karakeep data volume with an application-safe SQLite procedure. Meilisearch can be rebuilt if that is the intended recovery model, but the plan must state and test that choice. Include quota sizing, ownership, reclaim policy, node affinity, backup schedule, restore steps, and a restore acceptance test.

## Major findings

### Secret flow is redundant and has an unsafe conditional

`bw-sync.sh` already supports writing the mapped keys directly to the Kubernetes Secret. The proposed sequence runs `mise run secrets:sync` and then recreates the same Secret through `k8s-secrets.yml`. That duplicates ownership and obscures which path is authoritative. Pick one pattern and document it. If the repository requires both vault materialization and Ansible creation, explain why and ensure they converge.

The proposed Ansible task is guarded only by `vault_karakeep_nextauth_secret is defined` but interpolates both values. A partial sync would pass the guard and fail on the undefined Meilisearch value. Guard on both variables and add an `assert` that fails early with key names only. The summary should call the Secret conditional, as other summaries do.

The manual Bitwarden step should use the repository's actual folder and item conventions rather than merely saying `IRL/Services/`; `bw-sync-config.yaml` declares `IRL` as its root and looks items up by name. Verify whether nested-folder lookup is supported before prescribing placement. Do not place secret-generating commands in a workflow that could leak shell history; provide the established Bitwarden generation procedure.

### The chart and workload security posture needs explicit review

The upstream chart's Chrome container requests `SYS_ADMIN`. It also runs a browser against untrusted internet content, which is a materially risky workload. The plan does not discuss this capability, pod security, seccomp, read-only filesystems, service-account token mounting, or isolation from other namespace workloads.

Add a security decision for Chrome. At minimum, render and inspect the pod security context, disable service-account token mounting where possible, apply resource limits, and restrict network flows. Prefer a browser configuration that does not require `SYS_ADMIN` if upstream supports one; otherwise document acceptance of the sandbox tradeoff.

### NetworkPolicy is omitted

Tailscale-only controls user ingress but does not constrain pod-to-pod access or Karakeep's crawler egress. The plan should define policies allowing Traefik to reach Karakeep, Karakeep to reach Chrome and Meilisearch, DNS resolution, and the specific outbound access needed for page capture. Chrome and Meilisearch should reject unrelated namespace clients, and Meilisearch should not have general internet egress. If the current CNI does not enforce NetworkPolicy, say so explicitly and track the gap rather than silently treating ingress routing as workload isolation.

### Resource planning and scheduling are absent

Chrome and Meilisearch can be memory-intensive, while this homelab uses explicit resource budgeting. The plan supplies no requests or limits for Karakeep or Meilisearch and accepts only the chart's Chrome defaults. Add CPU/memory requests and limits based on `host_vars/homelab.yml`, account for them in the node budget, and include disk-pressure and out-of-memory checks in acceptance testing.

### The hostname decision is inconsistent with the sister plan and deserves an explicit choice

This plan selects `bookmarks.lab.infiniteroomlabs.cloud`; the sister plan selects `keep.internal.lab.infiniteroomlabs.cloud`. Both could fit the repository dictionaries, but `internal: false` means "public-domain suffix in the private CoreDNS zone," not "publicly exposed." The final implementation should make one deliberate hostname choice and explain the `internal` flag semantics so readers do not confuse naming with reachability.

### "Six files" is inaccurate

The listed changes include two external Bitwarden items plus four existing/new repository files, while the necessary Helm values directory-loop change is missing. If the summary is intended to count repository files, it should enumerate them precisely. A deployment-quality plan should also include test and runbook files, which raises the count further.

## Sequencing problems

1. Creating external secret items should be followed by a dry-run and validation of the mapping before mutating either vault or cluster state.
2. The plan runs `mise run secrets:sync`, which already targets Kubernetes by default, then runs `k8s-secrets.yml`; the intended secret owner must be resolved before this sequence is valid.
3. The values file and chart should be rendered locally with the pinned chart before any cluster mutation. Verify Secret references, generated resource names, service port, PVC names, images, security contexts, and probes.
4. Storage and backup prerequisites must exist before Helm installation.
5. DNS and ingress should normally be created only after the backend is healthy, or initially deployed with ingress withheld. Running the Traefik tag re-renders every standalone IngressRoute, so the plan should acknowledge the blast radius and validate all existing routes.
6. The first UI sign-up should occur only after registration policy is decided. A tailnet is not necessarily a single-user trust boundary. Disable new registrations after bootstrap or configure OIDC if multi-user policy requires it.
7. Rollback steps are missing. Specify how to remove the route, roll back the Helm revision, preserve PVCs, and restore the previous data state.

## Testability gaps and recommended acceptance gates

### Static and render checks

- Run the repository YAML/Ansible lint and syntax checks for every changed playbook and variable file.
- Add the chart repository and render the exact pinned chart with the proposed values into a temporary file.
- Assert that no rendered Secret contains chart-generated credentials, the Karakeep container imports `karakeep-secrets`, Meilisearch reads the expected key from that Secret, and no upstream Ingress is rendered.
- Assert the rendered Service is ClusterIP on port 3000, both PVCs have the intended class/size/reclaim behavior, and all images and chart dependencies match the reviewed versions.
- Run `helm lint` or the equivalent chart validation supported by the upstream package.

### Deployment checks

- Verify StatefulSet/Deployment rollout, pod readiness, PVC binding, restart count, events, resource pressure, and all three component logs.
- Use `kubectl get svc,ingress,ingressroute` to prove the exposure model rather than relying on pod names and DNS alone.
- Query `/api/health` and assert HTTP status and response content; `curl -s` alone can hide TLS and HTTP errors. Use `--fail --show-error` and validate the certificate hostname.
- Test page capture against both a static page and a JavaScript-heavy page, then verify the archived result survives a pod restart.
- Verify search after restart and after a Helm upgrade. Also verify the Secret data hashes remain unchanged without printing their values.
- Test SQLite backup and restore into a disposable release or namespace. Confirm bookmarks and assets return; confirm whether Meilisearch rebuilds as designed.
- Run public DNS queries against authoritative/public resolvers and perform direct-IP/Host-header probes from outside the tailnet.
- Run the repository smoke suite before and after deployment to detect regressions to existing CoreDNS and Traefik routes.

## Operational omissions

- No service-down or restore runbook is proposed. Add checks for the web component, Chrome, Meilisearch, PVCs, DNS, Traefik, certificate issuance, and secret references.
- No monitoring or alerting is defined. Even if Prometheus integration is deferred, define minimum Kubernetes health signals, PVC capacity alerts, and backup-failure visibility.
- No upgrade policy is defined for the chart, application image, Meilisearch, or Chrome. Pinning plus a documented upgrade test is important because SQLite migrations and search compatibility can affect rollback.
- No uninstall/data-retention behavior is documented. State that Helm removal must not delete retained application data or Bitwarden items without an explicit separate action.
- No registration/authentication policy is defined. Deferring Authentik is acceptable only if password auth, initial signup, and subsequent registration behavior are made explicit.

## Recommended revised implementation shape

1. Decide the canonical hostname and authentication/registration policy.
2. Select and pin an official chart version after rendering its complete dependency tree and reviewing image/security defaults.
3. Design ZFS-backed persistent storage, backup, restore, reclaim policy, and node affinity.
4. Define the single authoritative secret synchronization path, add both mappings, and validate both keys atomically.
5. Add `karakeep` to the Helm values-directory loop, repository list, upload task, and deploy task.
6. Add `irl_services` and standalone Traefik entries, but withhold the external route until the workload passes internal health checks.
7. Add NetworkPolicy and resource-budget changes or explicitly document why enforcement is unavailable.
8. Add render-level assertions and repository lint/syntax tests.
9. Deploy storage and secrets, then the pinned chart, then verify internal component behavior.
10. Enable DNS and ingress, execute tailnet and non-tailnet exposure tests, then run backup/restore and Helm upgrade/rollback tests.
11. Add a runbook and monitoring before declaring the service accepted.

## Conclusion

The upstream-chart route is viable and substantially smaller than maintaining an IRL wrapper chart, but the current plan optimizes for file count at the expense of lifecycle safety. The minimum acceptable revision must fix the missing values directory, pin and render-test the chart, make secret ownership atomic, provide durable backed-up storage, prove interface-level Tailscale-only exposure, and address Chrome isolation and pod networking. Without those changes, a successful initial UI load would not demonstrate a secure, recoverable, or repeatable deployment.
