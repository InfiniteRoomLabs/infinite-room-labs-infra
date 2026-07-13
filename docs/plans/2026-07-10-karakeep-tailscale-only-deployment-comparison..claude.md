# Karakeep Deployment: Plan and Review Comparison

**Author**: Claude (main session), 2026-07-10
**Compares**: the two sibling plans and all four independent reviews.

| Artifact | File |
|---|---|
| Original plan | `2026-07-10-karakeep-tailscale-only-deployment.md` |
| Alt plan | `2026-07-10-karakeep-tailscale-only-deployment-alt.md` |
| GPT review of original | `...-deployment-review..gpt.md` |
| Claude review of original | `...-deployment-review..claude.md` |
| GPT review of alt | `...-deployment-alt-review..gpt.md` |
| Claude review of alt | `...-deployment-alt-review..claude.md` |

## Scoreboard

| Artifact | GPT review | Claude review |
|---|---|---|
| Original plan (custom `irl-karakeep` chart, ~25KB) | Revise before implementation | needs-rework |
| Alt plan (official upstream chart, ~6KB) | Revise before implementation | ship-with-fixes |

All four reviewers agree the original is not shippable as written. The alt plan splits them -- and that split is the most informative signal in the set (see "The one real disagreement" below).

## The plans: two philosophies

**Original**: treats Karakeep as an occasion to *raise* the homelab's bar -- custom chart in the `helm-charts` submodule, ZFS datasets + static retained PVs, NetworkPolicies, backup/restore/rollback/upgrade procedures, 8 work packages, extensive acceptance criteria. Genuinely strong on lifecycle (storage, backup, rollback), but its two central security promises ("access through non-Tailscale interfaces fails", "prohibited pod-to-pod paths fail") are **unsatisfiable against the cluster as it exists today**, and it never evaluated the official Helm chart before deciding to build a custom one (violating the house search-before-build rule).

**Alt**: matches the *current* bar exactly -- official upstream chart (`karakeep-app/helm-charts`), 6-file diff cloning the ghostfolio precedent, inherits the existing posture wholesale. Ships fast, and its upstream claims verified unusually well (the chart's `meilesearch` typo, the `randAlphaNum` secret re-roll gotcha, the bjw-s override paths -- all real, all checked against actual chart sources). But it inherits the posture's gaps too, and is silent on storage durability, backup, Chrome's `SYS_ADMIN`, and NetworkPolicy -- exactly the silence the original filled.

Hostname disagreement: `keep.internal.lab.infiniteroomlabs.cloud` (original) vs `bookmarks.lab.infiniteroomlabs.cloud` (alt). Functionally near-identical -- both resolve only via the split-DNS wildcard -- but one must be chosen deliberately.

## Where all four reviews converge (treat as settled fact)

1. **"Tailscale-only" is currently false at the network layer.** nftables accepts 80/443 on *any* interface (`ansible/templates/nftables.conf.j2` renders unconditioned `tcp dport accept`; `ansible/inventory/group_vars/homelab/main.yml` lists 80/443), and Traefik is `hostNetwork: true`. Any LAN client with `curl --resolve` / a hosts-file entry reaches any `*.lab` service. Split DNS is discovery obscurity, not access control. Three of four reviews prove this independently; it is homelab-wide, not Karakeep-specific.
2. **NetworkPolicy "narrowing" is impossible.** Policies are additive (union-of-allows), and `allow-intra-namespace` (`podSelector: {}`, `ansible/playbooks/k3s.yml`) already grants everything the original plan forbids. Bonus defect: hostNetwork Traefik cannot be selected as a pod source -- any Traefik->web rule must be an ipBlock that cannot distinguish Traefik from other host processes.
3. **The Bitwarden one-item-with-fields model does not sync.** `bw-sync.sh` reads exactly one value per item; the schema has no field selector. One BW item per secret value, fanned into one k8s Secret via `k8s_key` (the alt plan already did this correctly; the original did not).
4. **The CoreDNS zone serial is hardcoded** (`coredns-internal-zone.db.j2`, serial unchanged since March), so new records never actually publish -- every service resolves via the `*` wildcard. Pre-existing repo defect both plans gloss over; both `dig` verifications would pass for the wrong reason.
5. **Signups/registration policy must be decided before first ingress.** Karakeep defaults to open signup; a tailnet is not automatically a single-user trust boundary.

## The one real disagreement: Claude-on-alt vs everyone

The Claude review of the alt plan concluded Tailscale-only "**holds by construction**." The Claude review of the *original* plan proved the opposite (its B1, with file:line evidence), and the GPT review of the alt plan agrees with the latter (direct-IP + forged Host header reachability). **Claude-on-alt is wrong on this point** -- it verified the chart mechanics to an unusual depth but accepted the inherited posture claim without testing the firewall path. Two independent same-model reviewers contradicting each other on the same shared fact is exactly why four reviews were run.

Other severity disagreements (judgment calls, not factual conflicts):

- **Chart version pinning**: GPT-on-alt calls the unpinned `chart_ref` a blocker ("unusually fragile contract" -- the overrides depend on a literal misspelling upstream could fix at any time); Claude-on-alt clears it as matching the firefly/ghostfolio precedent and "not this plan's debt." GPT has the better argument *for this specific chart*.
- **Storage/backup on alt**: GPT-on-alt blocker (dynamic local-path PVCs, no backup design, SQLite consistency unaddressed -- "the data is the reason to deploy the service"); Claude-on-alt never raised it. Its biggest coverage miss.
- **The missing values-dir loop entry** in `helm-deploy.yml`: GPT-on-alt blocker (copy destination will not exist), Claude-on-alt should-fix (filed under "section 6 misdescribes the edits"). Same defect, both caught it.

## Unique catches worth keeping

- **Claude-on-original only**: the **alpine/musl + ndots:5 DNS failure** will likely break page capture on first deploy -- the exact bug that paused the qBittorrent operator; institutional knowledge an outside reviewer could not have. Also: the missing **chart-releaser publish step** (deploy fails "chart not found" after a mere submodule push -- documented in the paperless comment in helm-deploy.yml), and the official chart's omission from the packaging options.
- **GPT-on-original only**: snapshot-on-same-pool is not a backup; SQLite WAL consistency and quiesce requirements; explicit egress CIDR/IPv6 enumeration for the SSRF policy; node capacity preflight vs ~5GiB of new limits; certificate-transparency leakage of wildcard structure; dataset ownership/fsGroup + deterministic PV binding (`volumeName`/`claimRef`).
- **Claude-on-alt only**: the `envFrom` override is **load-bearing Helm list replacement** paired with the disabled chart secrets -- an undocumented two-part invariant where re-enabling one side alone yields either `CreateContainerConfigError` or re-rolled secrets; the shared `karakeep-secrets` leaks `NEXTAUTH_SECRET` into the meilisearch pod via `envFrom`; the `irl_services` entry claims health-check wiring but is inert without `health_path`.
- **GPT-on-alt only**: the k8s-secrets task guard checks only `vault_karakeep_nextauth_secret` but interpolates both values (partial sync passes the guard, then fails); dual-path secret ownership ambiguity (bw-sync direct k8s write vs k8s-secrets.yml from vault) needs one authoritative answer.

**Pattern**: the Claude reviews are stronger on *this repo and this cluster* -- file:line evidence, institutional gotchas (ndots, chart publish, wildcard DNS). The GPT reviews are stronger on *ops lifecycle discipline* -- backup independence, data consistency, capacity, sequencing, negative-test rigor. They are complementary with surprisingly little overlap outside the five convergent findings.

## Recommended synthesis

**Merged plan** = alt's packaging + original's lifecycle + the review fixes:

1. Official chart, but **pin `chart_version`** (0.32.0 at review time) -- GPT-on-alt's argument wins for this chart.
2. Adopt the original's **ZFS datasets + static retained PVs + ownership (chown to container UID) + backup/restore design**, slimmed, replacing the alt's dynamic local-path PVCs. Include SQLite-consistent backup and a tested restore.
3. **`dnsConfig` ndots mitigation** on the web and chrome pods, with an in-pod external-resolution test (Claude-on-original B3).
4. Secrets: split into `karakeep-secrets` (NEXTAUTH_SECRET) and `karakeep-meili-secrets` (MEILI_MASTER_KEY); fix the guard to require both vars; keep one BW item per value; state which sync path is authoritative.
5. Mechanical fixes: add `karakeep` to the helm-deploy values-dir loop and repo list; document the envFrom/secrets-disable invariant in the values file; `health_path: "/api/health"` in `irl_services`; `DISABLE_SIGNUPS: "true"` after bootstrap; pick one hostname.
6. **Reword the security claim honestly**: "split-DNS + tailnet discovery; LAN-reachable at the TCP layer pending the firewall work item." Do not claim Tailscale-only until item A below lands.

**Spin out three homelab-wide work items** (they gate every service, not just Karakeep):

- **A. nftables interface scoping** -- restrict 80/443 accepts to `tailscale0` (with blast-radius analysis: every existing HTTP service, LAN-originated flows, DNS-01 needs no inbound).
- **B. `allow-intra-namespace` decision** -- refactor to label-based allowances (touches every service) or explicitly accept namespace-wide reachability and stop promising pod isolation.
- **C. CoreDNS zone serial** -- make it dynamic (epoch-derived) or add a rollout-restart after ConfigMap changes, so explicit records actually publish.
