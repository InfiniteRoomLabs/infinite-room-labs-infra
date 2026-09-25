# OpenMessage on k3s: repository changes (agent-box batch plan)

> **Status (2026-09-25): repository changes EXECUTED, nothing deployed.** WP1-WP5 and WP3b are done
> in the working tree of branch `feat/openmessage-k3s` (this repo) and `feat/openmessage`
> (`helm-charts` submodule). Nothing was pushed and the cluster was not touched. Two things did not
> happen: the agent-box session had no git identity and could not create commits, so the changes sit
> uncommitted and the submodule pointer is not updated; and `pytest`/`uv` could not be executed there,
> so no test suite was run (`helm lint` / `helm template` were run and pass). See the final report in
> the session transcript for the full list. Deploy steps are section 8 below; operational procedures
> live in `ansible/docs/runbooks/openmessage-down.md` and the chart is documented in
> `helm-charts/charts/irl-openmessage/README.md`.

**Date:** 2026-09-25
**Executor:** agent-box `batch` (unattended). **Reviewer:** Wes, before anything is pushed or deployed.
**Scope of this plan:** repository changes only, in this repo and the `helm-charts` submodule.
Deploying, data migration and client cutover are later phases run by a human-supervised session.

---

## 1. Goal

Run ONE OpenMessage daemon (Google Messages SMS/RCS sync, exposed as an MCP server) in the homelab
k3s cluster instead of one daemon per machine. One Google pairing, shared by Claude Code and Claude
Desktop on the desktop and the laptop. Reachable only from the home LAN (`192.168.2.0/24`) and the
tailnet (`100.64.0.0/10`), at `openmessage.lab.infiniteroomlabs.cloud`, with a required bearer token.

OpenMessage source: fork `github.com/Deathnerd/openmessage` (Go). The fork changes the chart depends on
(remote mode, `/healthz`, container image) are being built in parallel on the desktop. Treat the
**interface contract in section 3 as fixed**; do not look for the fork in this repo.

## 2. Hard constraints for this run (read first)

1. **Do not push anything.** No `git push` in either repo. Commit locally on branches (section 6).
2. **Do not touch the cluster.** No `kubectl` / `helm install|upgrade|uninstall` / `ansible-playbook`
   against real hosts. `helm lint` and `helm template` are fine.
3. **Do not read or write secrets.** No Bitwarden (`bw`), no `fnox`, no reading `vault.yml` or `.env`
   files. Do not generate a token value. Secrets are referenced by name only.
4. **Follow the repo's own rules** in `CLAUDE.md`, `CONTRIBUTING.md` and `TESTING.md`. Where they
   conflict with this plan, stop and report the conflict instead of guessing.
5. **Match existing patterns.** Precedents to copy:
   - `helm-charts/charts/irl-gunio-mcp`: in-house chart for an MCP server (digest-pinned GHCR image,
     ExternalSecrets, hardened security contexts, NetworkPolicy). Do NOT copy its cloudflared sidecar.
   - `ansible/helm/karakeep/` and `docs/plans/2026-07-10-karakeep-tailscale-only-deployment-final.claude.md`:
     `*.lab.infiniteroomlabs.cloud` hostname, Traefik routing, wildcard TLS, ZFS-backed static PV,
     runbook, tests.
6. If something in this plan turns out to be wrong for this repo, do the closest correct thing and list
   the deviation in the final report.
7. **Docs and runbooks stay current and coherent with every change.** A change is not done until every
   doc that describes the affected area says the same thing as the code. New docs are required (WP3),
   and existing docs must be updated where the change touches them (WP3b). No doc may contradict
   another or the chart/values after this run.

## 3. Interface contract (fixed; from the fork)

| Item | Value |
|---|---|
| Image | `ghcr.io/deathnerd/openmessage`, **pinned by digest**. The digest does not exist yet: make `image.digest` a required value (chart fails to render without it), set no default, and note it in the report. |
| Command | `openmessage serve --mcp-sse` (args `["serve", "--mcp-sse"]`; entrypoint is the binary) |
| Listen | `0.0.0.0:7007` via env `OPENMESSAGES_HOST=0.0.0.0`, `OPENMESSAGES_PORT=7007` |
| Data | `/data` via env `OPENMESSAGES_DATA_DIR=/data` (SQLite `messages.db` + WAL, `session.json` pairing credentials) |
| Remote mode | env `OPENMESSAGES_ALLOWED_HOSTS=openmessage.lab.infiniteroomlabs.cloud` (comma-separated). Requests with any other `Host` get 403 (DNS-rebinding defence), so the ingress must preserve the original `Host` header. |
| Auth | env `OPENMESSAGES_CONTROL_TOKEN_FILE=/run/secrets/openmessage/token`. Every `/mcp*` request needs `Authorization: Bearer <token>`; missing or wrong token gets 401. |
| Endpoints | `/mcp` (MCP streamable HTTP; responses can be long-lived SSE streams), `/mcp/sse` (legacy SSE), `/healthz` (unauthenticated, 200 when the process is up, no data). No web UI, no `/api`. |
| User | runs as uid/gid 1000, works with `readOnlyRootFilesystem: true` given writable `/data` and `/tmp` |
| Shutdown | may take up to ~10s to exit on SIGTERM (a Google RPC can hang); `terminationGracePeriodSeconds: 30` |

## 4. Design decisions

- **D1. Exactly one pod, ever.** Two daemons on one Google pairing fight and can get the session revoked.
  `replicas: 1`, `strategy: Recreate` (never RollingUpdate), no HPA, and a PodDisruptionBudget is
  unnecessary. Put a comment on `replicas` and `strategy` saying why.
- **D2. Storage.** ZFS-backed static PV on a new dataset `main/openmessage`, following the karakeep
  storage pattern exactly (storage class, reclaim policy Retain, node affinity, PVC binding). Size 5Gi.
  Include creating the dataset wherever the repo creates the others (ansible), with the same options.
- **D3. Secret.** One Kubernetes Secret `openmessage-secrets`, key `token`, sourced from a Bitwarden item
  named `openmessage-control-token`. Wire it the way this repo syncs other service secrets (gunio's
  ExternalSecrets and/or `scripts/bw-sync-config.yaml`; pick whichever the repo uses for new services and
  say which in the report). Mount it read-only at `/run/secrets/openmessage/token`. Service-secret
  rotation policy applies (365 days).
- **D4. Routing.** Hostname `openmessage.lab.infiniteroomlabs.cloud` on the existing Traefik with the
  existing wildcard TLS. Restrict with a Traefik IP allowlist middleware to `192.168.2.0/24` and
  `100.64.0.0/10`. **Verify from the repo** whether Traefik sees real client IPs (for example the
  Traefik service's `externalTrafficPolicy` and any proxy-protocol settings). If it does not, the
  allowlist is ineffective; still add it, but say so plainly in the report and the runbook, as the
  karakeep plan did. No NodePort, no LoadBalancer, no public DNS, no Funnel/Serve, no cloudflared.
  Make sure long-lived streaming responses are not cut off or buffered by Traefik (check timeouts).
- **D5. NetworkPolicy.** Ingress to port 7007 only from the Traefik pods (and the kubelet for probes if
  the repo's other policies need that). Egress: DNS plus outbound HTTPS 443 to the internet (Google
  Messages). No other egress.
- **D6. Probes.** Liveness and readiness `GET /healthz` on 7007. Generous startup (first sync can be
  slow): startupProbe with ~5 minutes of budget.
- **D7. Resources.** requests 50m / 128Mi, limits 1 CPU / 1Gi (deep backfill is bursty).
- **D8. Security context.** Same hardening as gunio: non-root 1000, readOnlyRootFilesystem, drop ALL,
  RuntimeDefault seccomp, `fsGroup: 1000` with `OnRootMismatch`. `emptyDir` for `/tmp`.
- **D9. Out of scope.** Web UI, WhatsApp/Signal bridges, Authentik, public exposure. A later move to a
  Claude custom connector behind the Cloudflare MCP proxy (like gunio/jobops) is tracked separately;
  mention it in the runbook's "future" section only.

## 5. Work packages

### WP1. Chart `helm-charts/charts/irl-openmessage/` (submodule)

- `Chart.yaml` (version 0.1.0; appVersion `0.2.9-fork`, with a comment that the image is built from the
  `Deathnerd/openmessage` fork and the digest in values is authoritative),
  `values.yaml` (defaults per sections 3-4, digest required), `README.md` (what it is, values table,
  the one-pod rule), `templates/`: `_helpers.tpl`, `deployment.yaml`, `service.yaml` (ClusterIP 7007),
  ingress/IngressRoute + middleware (whichever the repo uses for `*.lab` services), `networkpolicy.yaml`,
  secret wiring per D3, `serviceaccount.yaml` (automount false), PVC per D2.
- Render gate: `helm lint` and `helm template` with a dummy digest must pass; `helm template` without a
  digest must fail with a clear message.
- If the chart repo has chart tests/CI config (`ct.yaml`, chart-testing), make the new chart pass them.

### WP2. Infra wiring (this repo)

- `ansible/helm/openmessage/values.yaml`: environment overrides (hostname, allowlist CIDRs, PV node,
  image digest placeholder that must be filled before deploy, clearly marked).
- Register the release wherever `ansible/playbooks/helm-deploy.yml` (or the repo's equivalent) lists
  services, following karakeep.
- ZFS dataset `main/openmessage` + PV per D2 wherever the repo defines them.
- Secret mapping per D3 (config only, no values).
- DNS: follow karakeep (wildcard vs explicit record); add an explicit record only if that is now the
  convention.

### WP3. Docs

- Runbook `ansible/docs/runbooks/openmessage-down.md` in the style of `karakeep-down.md`: symptoms,
  checks (pod, PVC, route, cert, DNS, `/healthz`, 401 vs 403 meaning, Google pairing state from logs),
  the one-pod rule, how to re-pair (exec `openmessage pair` in a scaled-down debug pod against the same
  PVC, never alongside the running pod), backup/restore of `/data` (SQLite WAL: stop pod first, copy
  `messages.db*` and `session.json`), token rotation, future connector note (D9).
- Add the service to whatever index/access guide lists `*.lab` services and to the backup SOP.
- `CHANGELOG.md` entry.

### WP3b. Keep existing docs coherent (do this as you go, then sweep at the end)

- **Find every affected doc.** Search both repos (`README.md`, `CLAUDE.md`, `CONTRIBUTING.md`,
  `TESTING.md`, `docs/`, `ansible/docs/` incl. `runbooks/` and `sops/`, chart READMEs, the helm-charts
  repo's own README/CHANGELOG/index) for anything that enumerates or describes: services in the `irl`
  namespace, `*.lab` hostnames, ZFS datasets/PVs, Bitwarden/bw-sync secret mappings, NetworkPolicies,
  backup scope, monitoring/alert coverage, test inventories (e.g. "17 smoke tests"), and MCP servers
  hosted in the cluster. Update each one that the new service changes.
- **Cross-link.** The chart README, the runbook, the values file header and this plan link to each other.
  The runbook names the chart, values path, dataset, secret name and hostname exactly as the code does.
- **One source of truth per fact.** Where a fact (hostname, CIDRs, secret name, dataset, port) is
  repeated in docs, it must match the chart/values byte for byte. Prefer linking over restating.
- **Counts and lists.** If a doc states a count (services, tests, datasets) or keeps a list, fix the
  count/list, don't just append.
- **This plan.** At the end, add a short "Status" line at the top of this file (what was done, pointer to
  the final report) so the plan isn't read later as still-unexecuted.
- **Final coherence sweep.** Before the last commit, re-read every doc you touched plus the chart
  `values.yaml` and `ansible/helm/openmessage/values.yaml` side by side and fix any mismatch.

### WP4. Tests

- Add the service to the repo's test suites the way karakeep was added (DNS test, policy/conftest checks,
  smoke/acceptance definitions), but only run tests that do not need the live cluster. Record which
  live tests exist but were not run.

### WP5. Deploy-phase checklist (write it, do not execute it)

Append to this plan file a section "Deploy phase (human-supervised)" listing, in order: publish image and
fill digest; create Bitwarden item + sync secret; create dataset/PV; **stop the desktop's Windows
`OpenMessage` service**; copy desktop `C:\Users\wesgi\.local\share\openmessage\{messages.db*,session.json}`
into the PV (pod not running) so the existing pairing is reused; deploy; verify `/healthz`, 401 without
token, 200 MCP `tools/list` with token, sync resumes; then client cutover. Keep it concrete.

## 6. Git

- This repo: work on the current branch `feat/openmessage-k3s` (already created; this plan file is on it).
- Submodule: create branch `feat/openmessage` in `helm-charts/`, commit the chart there, then commit the
  updated submodule pointer in this repo.
- Small, logical commits with clear messages. No `Co-Authored-By` trailers, no session links.
- Before finishing, run the repo's public-readiness / leak scan if one exists for pre-push use, and report
  the result (commits are local, but the branch will be pushed after review).

## 7. Final report (your last message)

Plain markdown, short:
1. What was created/changed (files, per repo) and the commit list for both repos.
2. Every deviation from this plan and why.
3. Verification run and results (lint/template/tests), plus live tests that exist but were not run.
3b. Docs: every doc created or updated (path + one line on what changed), and any doc you found that
   describes the area but deliberately left unchanged, with why.
4. Open questions and anything the reviewer must decide, especially: Traefik client-IP visibility (D4),
   secret mechanism chosen (D3), anything that blocks the deploy phase.

---

## 8. Deploy phase (human-supervised)

Written by the repo-changes run; **not executed by it**. Every step below touches the cluster, a
secret, or the desktop, and is deliberately out of scope for an unattended session. Do them in order:
each one is a prerequisite for the next.

### 0. Land the repository changes

1. Review and commit the working-tree changes on `feat/openmessage` (submodule) and
   `feat/openmessage-k3s` (this repo).
2. **Push the submodule branch and merge it to `helm-charts` `main` first.** `helm-deploy.yml` installs
   `chart_ref: irl/irl-openmessage` from `https://infiniteroomlabs.github.io/helm-charts/`, not from the
   local submodule path, so `chart-releaser` must have published `irl-openmessage-0.1.0` before the
   deploy task can resolve. (`CONTRIBUTING.md`, "Pick or write the chart".)
3. Then update the submodule pointer in this repo and push `feat/openmessage-k3s`.
4. Confirm CI is green: `hygiene`, `kubeconform`, `conftest`.

### 1. Publish the image and fill the digest

5. Build and push the fork image to `ghcr.io/deathnerd/openmessage`.
6. Resolve the manifest digest:
   `docker buildx imagetools inspect ghcr.io/deathnerd/openmessage:<tag> --format '{{.Manifest.Digest}}'`
7. Replace the placeholder in `ansible/helm/openmessage/values.yaml` -> `image.digest`. Until this is
   done every deploy ends in `ImagePullBackOff` (fail-safe, by design). Commit that change.

### 2. Create the control token

8. Generate a token off-box (for example `openssl rand -base64 48`) and store it in Bitwarden as
   `openmessage-control-token` under `IRL/Services/OpenMessage`. Put `{"rotation_days": 365}` in the
   item's Notes -- without it `bw-sync.sh --check-rotation` silently skips the item.
9. Sync it: `mise run secrets:sync`, then verify the Secret exists without printing it:
   `kubectl get secret -n irl openmessage-secrets -o jsonpath='{.data.token}' | wc -c`

### 3. Create storage

10. `cd ansible/ && uv run ansible-playbook playbooks/zfs.yml --tags datasets,sanoid,openmessage`
    (creates `main/openmessage`, applies the sanoid policy, chowns it to 1000:1000).
11. `uv run ansible-playbook playbooks/k3s.yml --tags pvs` (creates `pv-openmessage-data`).
12. Confirm: `ssh homelab-ts "zfs list main/openmessage; ls -ld /media/root/storage1/openmessage"`
    -- owner must be `1000:1000`, or the daemon cannot write `messages.db`.

### 4. Stop the desktop daemon and move its data in

**This is the step that must not be rushed: from here until the pod is up, exactly one OpenMessage
may exist on this Google pairing.**

13. On the Windows desktop, stop the `OpenMessage` service and set it to Manual so a reboot cannot
    revive it behind your back:
    ```powershell
    Stop-Service OpenMessage
    Set-Service OpenMessage -StartupType Manual
    Get-Service OpenMessage    # must report Stopped
    ```
14. Copy `C:\Users\wesgi\.local\share\openmessage\{messages.db,messages.db-wal,messages.db-shm,session.json}`
    off the desktop. Take all four together -- SQLite is in WAL mode, so `messages.db` alone can be a
    torn database. (`-wal`/`-shm` are absent after a clean stop; that is fine.)
15. Create the PVC but keep the pod at zero, then copy the files in. The PV is a hostPath on the ZFS
    dataset, so the simplest path is straight onto the host:
    ```bash
    uv run ansible-playbook playbooks/helm-deploy.yml --tags openmessage   # creates the PVC
    kubectl scale -n irl deploy/openmessage --replicas=0 2>/dev/null || true
    scp messages.db* session.json homelab-ts:/tmp/om/
    ssh homelab-ts "sudo cp -a /tmp/om/. /media/root/storage1/openmessage/ && \
      sudo chown -R 1000:1000 /media/root/storage1/openmessage && \
      sudo rm -rf /tmp/om"
    ```
    Reusing the existing `session.json` is the whole point: it means no re-pairing and no re-sync.

### 5. Deploy

16. `uv run ansible-playbook playbooks/helm-deploy.yml --tags openmessage`
17. `uv run ansible-playbook playbooks/helm-deploy.yml --tags coredns` (regenerates the zone from
    `irl_services`; the wildcard record means the name resolves even without this, so do not take
    resolution as proof it ran).
18. Watch the first start: `kubectl -n irl logs -f deploy/openmessage`. Pairing state appears only in
    the logs -- `/healthz` says nothing about it.

### 6. Verify

From a tailnet host:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://openmessage.lab.infiniteroomlabs.cloud/healthz   # 200
curl -sS -o /dev/null -w '%{http_code}\n' https://openmessage.lab.infiniteroomlabs.cloud/mcp       # 401
curl -sS https://openmessage.lab.infiniteroomlabs.cloud/mcp \
  -H "Authorization: Bearer <token>" -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'                                              # 200 + tool list
```

19. Confirm the token gate really is a gate (the 401 above) before pointing any client at it.
20. Confirm sync resumed: recent messages appear, and the logs show no re-pair prompt.
21. `cd tests/ && uv run pytest -m "smoke or hygiene"` -- DNS record, runbook, secret mapping and
    registry contracts all land here.

### 7. Client cutover

22. Point each client at the cluster endpoint, one machine at a time, checking each works before
    moving on:
    ```bash
    claude mcp add --scope user --transport http openmessage \
      https://openmessage.lab.infiniteroomlabs.cloud/mcp \
      --header "Authorization: Bearer <token>"
    ```
    Claude Desktop: same URL and header in its MCP config.
23. Remove the per-machine OpenMessage configuration from every client that had a local daemon, so
    nothing can start a second one by habit.
24. Only once every client is cut over: uninstall the Windows service on the desktop (leaving its
    data directory in place as a cold backup until you are confident).

### Rollback

The desktop data directory is untouched by all of the above. To fall back: scale the cluster pod to
zero (`kubectl scale -n irl deploy/openmessage --replicas=0`), wait for the pod to be gone, then
start the Windows service again. The PVC keeps its copy for a later retry. Do not run both.
