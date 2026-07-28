# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Repo-hygiene contract suite (`tests/hygiene/`, `mise run test:hygiene`) -- WS1 of the ops-UX "Sharpen the Spine" plan.** The `irl_services` registry is now an *enforced* single declaration point: pure repo-introspection pytest tests (marker `hygiene`, zero cluster/secret access -- verified under `KUBECONFIG=/dev/null`) assert that every registry entry has a matching `helm-deploy.yml` tag (grouped deploys declare a new optional `deploy_tag` field: grafana/prometheus/alertmanager -> `monitoring`, garage-s3 -> `garage`), every `existingSecret` in `ansible/helm/*/values.yaml` maps to a `bw-sync-config.yaml` `k8s_secret`, every non-internal service has a homepage tile, every service has a `<svc>-down.md` runbook, and every `ansible/helm/` dir maps back to the registry. Known gaps live in shrink-only ratchet allowlists (a companion test fails when a fixed gap is not removed): 16 runbook gaps and 6 homepage-tile gaps (vaultwarden, nextcloud, firefly, ghostfolio, firefly-importer, karakeep -- every service deployed after the homepage was last touched, i.e. exactly the drift this suite exists to catch). Docs checks: a dependency-free UTF-8/smart-quote encoding gate over authored markdown (replacing reliance on the silently-skipping spec-kitty pre-commit hook) and a dead-reference denylist (`caddy_proxy`) over live docs. `tests/conftest.py` no longer hardcodes a SERVICES dict (it had drifted to 10 of 17 services): SERVICES is now derived from the registry, with only test-side HTTP expectations kept local. `test_caddy.py` (testing the retired Caddy stack) replaced by `test_ingress.py` (Traefik, same TLS/health assertions, now covering all 17 routed services); the goss `caddy-pod-running` check -- dead YAML since a duplicate `command:` key collapsed it -- replaced by a working `traefik-pod-running` check in a single merged block. Encoding fixed in 5 authored docs (ansible/CLAUDE.md, CHANGELOG.md, infrastructure-roadmap.md, 2026-06-02-proactive-paperless.md, manage-secrets skill).
- **Homelab VM hosting: KVM/libvirt + Packer gold master pipeline.** New top-level `packer/` tool directory builds versioned Ubuntu 24.04 gold masters from the official cloud image (QEMU builder; qemu-guest-agent, tailscale installed-unjoined, unattended-upgrades, machine identity + cloud-init state wiped) and publishes them to `homelab:/media/root/storage1/vms/images/` via `packer/scripts/publish-image.sh` (usage-spec script, `latest` symlink). `ansible/playbooks/libvirt.yml` installs the hypervisor alongside k3s and defines the `irl-vms` NAT network -- libvirt DNS disabled because the internal CoreDNS owns `*:53` on the host; DHCP hands VMs public resolvers until MagicDNS takes over post Tailscale join. `ansible/playbooks/vms.yml` provisions VMs declaratively from the `irl_vms` dict in `host_vars/homelab.yml` (RAM budget asserted vs `irl_vm_ram_budget_gb: 12`): per new VM it mints a **single-use, non-ephemeral Tailscale pre-auth key** via the API using the existing `vault_tailscale_api_key` (no stored authkey secret), creates a qcow2 backed by the gold master on the new ZFS `main/vms` dataset (64K recordsize), renders a NoCloud seed (hostname, admin user, `tailscale up`), and defines/starts/autostarts the domain via `community.libvirt` (new Galaxy dep; `ansible/collections/` now gitignored). `virbr-irl` allowlisted in the nftables input chain. First VM `ubuntu-vm-01` (4 vCPU/8GB/40G) verified end-to-end: tailnet join, MagicDNS split DNS, idempotent re-run, k3s unaffected. Design doc `docs/plans/2026-07-23-homelab-vm-gold-master-design.md`; runbook `docs/runbooks/vm-provisioning.md` (includes the `qemu:///system` default-URI, Tailscale key description charset, and security-hardening-flushes-libvirt-NAT gotchas). Rotated the expired `tailscale-api-key` (BW) along the way. mise pins `packer = "1.15.4"`.
- **Cloudflare Access service token for headless MCP agents** (`cloudflare-tunnel` module): 1-year service token + `non_identity` policy on the JobOps Access app, so MCP clients (Claude Code/Desktop, Codex, opencode) pass Access via `CF-Access-Client-Id`/`CF-Access-Client-Secret` headers while browsers keep the OTP flow. Infra CF token gained `Access: Service Tokens Write` (expanded in place, not rotated). Credentials in BW: `jobops-mcp-access-service-token`, `jobops-mcp-api-key`.

- **Karakeep (bookmark manager) deployed, tailscale-only** at `https://bookmarks.lab.infiniteroomlabs.cloud`. Upstream `karakeep-app/karakeep` chart pinned to 0.32.0 via `helm-deploy.yml` (`--tags karakeep`); values in `ansible/helm/karakeep/values.yaml`. Three workloads in `irl`: web app (SQLite), headless Chrome capture worker, Meilisearch StatefulSet. Storage on retained static PVs backed by new ZFS datasets `main/karakeep-data` (50G, sanoid `service_data` -- authoritative DB + page archives) and `main/karakeep-meilisearch` (20G, `large_assets` -- rebuildable index). Secrets (`karakeep-nextauth-secret`, `karakeep-meili-master-key`) flow BW -> `bw-sync-config.yaml` -> `karakeep-secrets`/`karakeep-meili-secrets`. DNS + IngressRoute wired through `irl_services` / `irl_traefik_standalone_services` (`subdomain: bookmarks`, health `/api/health`). Single admin account bootstrapped, then `DISABLE_SIGNUPS=true`. Verified: health via domain, no public DNS record, external fetch from pod (ndots-safe), Meilisearch indexing, data survives pod restarts. New runbook `ansible/docs/runbooks/karakeep-down.md`; karakeep restore section in `backup-and-restore.md`; smoke coverage in `tests/conftest.py` SERVICES + `test_dns.py`.

- **Grafana MCP server wired in** (`.mcp.json` -> `scripts/mcp-grafana.sh`). The wrapper fetches only `GRAFANA_SERVICE_ACCOUNT_TOKEN` via `fnox get` (single-secret isolation with `env -i` -- the third-party `mcp-grafana` binary never sees infra-wide creds) and runs the mise-installed `aqua:grafana/mcp-grafana`. New fnox secret mapping (BW item `grafana-mcp-token`, Editor-role SA) and non-secret `GRAFANA_URL` in `mise.toml [env]`.

### Fixed
- **Stale `BW_SESSION` no longer silently breaks secret resolution.** `scripts/vault-pass.sh` and `scripts/with-secrets.sh` trusted an inherited env `BW_SESSION` blindly; a long-lived agent/terminal session started before a re-unlock would pass a dead token to `bw`, which fnox swallowed into an empty string (ansible: "Invalid vault password"). Both scripts now validate each candidate (env -> fnox age -> `~/.bw_session`) against `bw status` and use the first unlocked one, failing loudly with a pointer to `bw-unlock-prompt.sh` when none work. `ansible/run-ansible.sh` had its own copy of the same bug; it now delegates to `vault-pass.sh`.
- **Traefik helm deploys no longer time out.** Root cause of every traefik `context deadline exceeded` failure since April (revs 13/14/16/18): the chart-default `LoadBalancer` service never gets an external IP on this hostNetwork k3s (no LB provider), so `helm --wait` hung until timeout. `service.type: ClusterIP` in `ansible/helm/traefik/values.yaml` fixes the wait. The chart is now also pinned (`chart_version: 39.0.7` -- it was unset, so upgrades floated to the newest chart, whose values schema rejects our top-level `logs` key); the 40+ chart upgrade is a separate future task.
- **`helm_repository` idempotency**: `force_update: true` on the repo-add task -- the rebuilt runner image's newer `kubernetes.core` fails re-adds of existing repos with trailing-slash URLs.

### Changed
- **BW_SESSION plumbing collapsed to a single store + shared resolver.** Root-cause insight (2026-07-28): bw session keys have no inactivity TTL -- the recurring "stale session" pain was (a) agent bash shells never loading the `~/.bw_session` fish cache (fixed machine-side: `~/.bashrc` + `~/.bash_env` now load it) and (b) a second, age-encrypted `BW_SESSION` copy in the global fnox config rotating independently and shadowing the file. The fnox copy is deleted (age provider + `age` mise pin removed with it); `~/.bw_session` is the single session cache. New `scripts/includes/bw-session.sh` (`resolve_bw_session`: env -> cache, each candidate validated via `bw status`, perms/ownership-checked, return-not-exit) replaces the four divergent resolver copies in `with-secrets.sh`, `vault-pass.sh`, `bw-sync.sh`, and `mcp-grafana.sh`; `bw-unlock-prompt.sh` no longer re-seeds fnox. Covered by 6 stub-`bw` hygiene tests (`tests/hygiene/test_bw_session_resolver.py`). Docs swept (CLAUDE.md, ansible/CLAUDE.md, CONTRIBUTING.md, manage-secrets skill, bw-sync troubleshooting + laptop-DR runbooks -- the DR runbook now covers restoring `bw.fish` on a fresh machine); raw `bw unlock --raw` is now documented as a forbidden recovery path (rotates the key without updating the cache). Adversarially reviewed by codex before implementation.
- **README restructured around a "Start Here" task table** -- quick links to the contributing guide, testing guide, access guide, runbooks, and SOPs; setup section rewritten as a mise-first Quick Start.
- **Paperless OCR worker rebalance for large scans** (`ansible/helm/paperless/values.yaml`). The override was `PAPERLESS_TASK_WORKERS=8` / `PAPERLESS_THREADS_PER_WORKER=2` (throughput-biased), which crawls on a single huge scan: a 295-page 680dpi archival scan OCR'd every page but hit `TimeLimitExceeded(3600)` during the final Ghostscript PDF/A reassembly. Rebalanced to `4x5` (balanced profile -- still clears intake batches but parallelizes 5 pages within one doc, ~2.5x faster on monster scans) and raised `PAPERLESS_WORKER_TIMEOUT` 3600 -> 7200. Documented three switchable profiles inline (`batch` 8x2, `balanced` 4x5, `big-scan` 2x10) and the `TASK_WORKERS x THREADS_PER_WORKER <= host vCPU (24)` invariant. Requires a `--tags paperless` redeploy to take effect (pod restart).
- **Secrets/tooling migration to fnox + mise + usage.** Env-var secrets (Terraform/CLI provider tokens) are now managed by **fnox** over Bitwarden (still the source of truth) instead of `.env`/`.envrc`/`~/.secrets/` reads. Both `.envrc` files were deleted -- nothing loads secrets ambiently; secrets materialize only under `fnox exec` via new `scripts/with-secrets.sh`. New `fnox.toml` declares 11 secrets mapped to existing `IRL/` Bitwarden items (`value = "item"` for Login password fields, `"item/notes"` for secure notes); providers (`bitwarden` + `age`) live in the global `~/.config/fnox/config.toml`, with `BW_SESSION` age-encrypted (the age provider reuses the existing SSH ed25519 key via `key_file`, no separate age key). The cluster-secret chain (`bw-sync.sh` -> `vault.yml` + k8s Secrets) is unchanged except it now sources `BW_SESSION` from fnox. New `mise.toml` pins tool versions (terraform 1.12.1, terragrunt 0.77.22, helm 3.16.4, kubectl 1.31.4, task 3.49.1, fnox 1.25.1, usage 3.3.0, age 1.3.1), adds a `[tasks]` runner (`bootstrap`, `secrets:sync`, `secrets:check`, `secrets:verify-k8s`, `ansible`, `test:smoke`, `test:validate`), and holds non-secret identifiers in `[env]`. The Ansible vault password now comes from fnox via `ansible.cfg` `vault_password_file = ../scripts/vault-pass.sh` (executable client; legacy Docker runner resolves it on the host and mounts it). `bootstrap.sh`, `bw-sync.sh`, and `run-ansible.sh` converted to the `usage` arg-spec format (`#!/usr/bin/env -S usage bash`, `#USAGE` directives). fnox registered as a project-scoped MCP server in `.mcp.json`. New Bitwarden item `tailscale-homelab-authkey` created under `IRL/Infrastructure/Tailscale`. Six migrated `~/.secrets/` files retired after verifying fnox serves their values. Docs updated across README, CONTRIBUTING, both `CLAUDE.md`s, `ansible/CLAUDE.md`, the `manage-secrets` skill, the bw-sync troubleshooting runbook, the global `~/.claude/CLAUDE.md` fnox scope-boundary, and the agent-ops `pre-deploy-secrets-sync.sh` hook. NOTE: `CLOUDFLARE_ACCOUNT_ID` and `DOCKER_USERNAME` in `mise.toml [env]` are placeholders (`TODO_FILL_*`) pending real values.

### Added
- **`claudesync-embed` laptop timer (daily vector index).** New `ansible/files/laptop/claudesync-embed.{service,timer}` run `uv run reindex embed` over `~/claude-ai-export` daily at 14:30 (after `claudesync-indexer`, so it embeds freshly regenerated `INDEX.md` summaries), building a local Chroma `.vector-db` via the Cloudflare Workers AI bge-m3 model; the content-hash skip keeps each run to pennies and it commits nothing (`.vector-db` is gitignored). Unlike `claudesync`/`claudesync-indexer` (symlinked from the app repo because they commit into it), these units are shipped from this repo and copied into place -- the embed only operates on the data dir via `WorkingDirectory` and reads `CF_ACCOUNT_ID`/`CF_API_TOKEN` from the repo `.env`, so there is no symlink coupling to the app repo's internals. `playbooks/laptop.yml` gains a copy+enable block (mirroring `knowledge-backup`) and the Alloy log-shipping config now forwards the new unit's journal to the homelab alongside the other four laptop timers.
- **Paperless app-layer config-as-code (taxonomy + workflows).** New
  `ansible/playbooks/paperless-config.yml` idempotently applies the Paperless
  classification setup from `ansible/inventory/group_vars/all/paperless_config.yml`
  (16 correspondents, 12 document types, 18 tags -- each with its keyword/`auto`-ML
  matching rule -- plus 3 starter workflows) via the REST API. Workflow request
  bodies are rendered by `ansible/templates/paperless_workflow_body.json.j2` (resolves
  tag/correspondent/type names to IDs); the per-kind GET->POST-if-missing->PATCH-if-drift
  applier is `ansible/playbooks/tasks/paperless_taxonomy.yml`. Registered in `site.yml`
  after the Helm deploy (`--tags paperless-config`); runs on the homelab host against
  the NodePort (`http://127.0.0.1:30800`). Auth reuses the existing
  `~/.secrets/.paperless-api-token` -- new `paperless-api-token` mapping in
  `bw-sync-config.yaml` and `api-token` key added (conditionally) to the
  `paperless-secrets` Secret in `k8s-secrets.yml`. WHY: `restore-paperless.md`
  truncates the tag/correspondent/type/workflow tables, so a DB rebuild otherwise
  loses the entire classification setup. Mail-account/rule monitoring is deferred
  (printer scans are the primary ingestion path).
- `docs/plans/2026-06-02-proactive-paperless.md`: spec for making Paperless proactive and reproducible -- config-as-code (correspondents/types/tags/workflows/mail rules) applied by an idempotent Ansible play (mirroring the `gitea.yml` `uri` pattern), plus IMAP mail-account monitoring so Paperless auto-ingests inbound correspondence. Includes the catalog-script hardening notes (Gotenberg HTML->PDF since Paperless rejects `text/html`, md5 source de-dup, Ghostscript normalize-and-retry) and the OCR worker-tuning runbook (early-ack restart caveat, revoke-then-terminate, no-`ps`-in-image, worker profiles).
- First Google Cloud Terraform footprint, for the `gmail-ai-broker` tool. New `google` provider (`hashicorp/google ~> 7.0`) added to `terraform/root.hcl`'s generated `required_providers`. New reusable module `terraform/modules/gcp-project-services/` enables a list of GCP API services via `google_project_service` (with `disable_on_destroy = false` so tearing down Terraform never silently disables an API another tool relies on -- enabling is free + idempotent). New provider config `terraform/environments/homelab/gcp/provider.hcl` auths via Application Default Credentials (`gcloud auth application-default login`) -- NO service-account key files, no credentials in the repo. New leaf `terraform/environments/homelab/gcp/gmail-api/` enables `gmail.googleapis.com` (local backend for now, matching the DO leaf -- the TFC org has no workspaces yet; reconcile to TFC's root.hcl backend on formal adoption). The `google` version pin lives in `gcp/provider.hcl` so local-backend leaves are self-contained. `gcp_project_id = "infinite-room-labs"` added to `homelab/env.hcl` locals. GCP spend from this is $0: enabling an API is free. NOTE: the OAuth Desktop client + consent-screen publish the broker needs is Console-manual -- verified against hashicorp/google 7.x that no provider resource creates a Gmail user-consent installed-app client (`google_iam_oauth_client` is Workforce-Identity-Federation-only and cannot request Gmail scopes). Module `terraform validate` passes.
- `ansible/playbooks/deluge.yml` + `ansible/files/update-deluge-core-conf.py`: host-service playbook for the Deluge BitTorrent daemon on the homelab. Configures remote access (`allow_remote`, pinned BT listen port 6881, download paths at `/media/root/storage1/nfs-share/downloads/{complete,incomplete}`), adds an admin auth entry from Bitwarden, starts `deluge-web` on 8112, and registers in `site.yml` phase 1 alongside `samba.yml`. The helper script performs surgical key updates of Deluge's dual-JSON `core.conf` format while preserving other settings. Documents a non-obvious Deluge gotcha inline: deluged writes its in-memory config on shutdown, so `systemctl restart` clobbers on-disk edits -- the playbook works around this with an explicit stop -> edit -> start sequence. Chose host deploy over the previously-blocked k3s/qbittorrent-operator path to dodge the musl+k8s-ndots:5 tracker resolution bug.
- `irl_firewall_allowed_udp_ports` support in `templates/nftables.conf.j2` (template was TCP-only). Populated with UDP 6881 on homelab for Deluge DHT/uTP. TCP 58846, 8112, and 6881 added to `irl_firewall_allowed_tcp_ports` for LAN reachability; Tailscale access was already unconditional via the interface-level allow rule.
- `scripts/bw-sync-config.yaml`: `deluge-admin` -> `vault_deluge_admin_password` mapping. Host-only secret (no `k8s_secret`), stored under `IRL/Services/Deluge` in Bitwarden.
- `irl_services.qbittorrent` entry (commented out, with pointer) for the planned `torrents.lab.infiniteroomlabs.cloud` qBittorrent WebUI. Fork of [guidonguido/qbittorrent-operator](https://github.com/guidonguido/qbittorrent-operator) now lives at `git.lab.infiniteroomlabs.cloud/InfiniteRoomLabs/qbittorrent-operator` with branch `irl-deployment` carrying the IRL-specific kustomize overlay + runtime manifests (PV, PVC, TorrentServer, IngressRoute, Torrent CRs) under `deploy/irl/`. Bringup attempted 2026-04-12 and deferred: the linuxserver/qbittorrent Alpine image trips the same musl getaddrinfo + k8s ndots:5 bug that bit Vaultwarden SMTP in 2026-03, so trackers fail to resolve and only DHT/PeX/LSD peer discovery work. Unblocker is adding `dnsConfig` support to the TorrentServer CRD on the fork (enhancement #3 on top of the existing PRD features). Full writeup in `deploy/irl/README.md` on the fork.
- Documentation: nine new SOPs / runbooks under `ansible/docs/` capturing patterns and procedures from the paperless-ngx + samba bringup:
  - `sops/garage-bucket-iam-management.md` -- canonical reference for the Garage admin HTTP API: bucket creation, IAM key minting, permission grants, deletion. Includes the full port-forward + token-extraction + curl workflow.
  - `sops/authentik-oidc-via-ak-shell.md` -- create + update Authentik OAuth2/OIDC providers via the Django shell inside the worker pod, bypassing TOTP-protected admin auth. Generic across any OIDC client, not paperless-specific. Includes safe credential extraction patterns.
  - `sops/rotate-paperless-credentials.md` -- per-secret rotation procedures for all 8 paperless credentials. Calls out the SECRET_KEY destructive rotation, the OIDC client_secret coordinated rotation (Authentik first, then BW + JSON blob), and the Garage S3 key rotation with grant-then-delete sequencing.
  - `runbooks/bw-sync-troubleshooting.md` -- diagnostic runbook for `bw-sync.sh` failures. Documents the two real bugs caught during the paperless bringup (yq lexer error on JSON values, state file collision between ansible/k8s targets) as recognition patterns for future similar bugs, plus general failure modes (BW session expiry, vault password drift, missing kubectl, item-name mismatches).
- Documentation: five new SOPs / runbooks under `ansible/docs/` from the initial paperless bringup:
  - `sops/setup-windows-paperless-ingestion.md` -- end-user walkthrough for mapping the SMB share on a Windows 10/11 machine, including the `AllowInsecureGuestAuth` registry tweak and the `RequireSecuritySignature` workaround for Windows 11 24H2+, with troubleshooting for the common failure modes.
  - `sops/restore-paperless.md` -- DR procedure to restore Paperless-ngx from a `document_exporter` zip in the Garage `paperless-backups` bucket. Covers truncate, kubectl-cp, and a one-shot Job alternative for crash-loop scenarios.
  - `sops/samba-add-auth.md` -- forward-looking hardening recipe to replace the current guest-mode Samba share with a dedicated `paperlessscan` system user + Bitwarden-managed password. Referenced inline as a TODO in `group_vars/homelab/main.yml` and `smb.conf.j2`.
  - `sops/deploy-paperless-from-scratch.md` -- canonical end-to-end bringup SOP capturing the entire 10-step sequence (BW items, Authentik OIDC via `ak shell`, Garage bucket + IAM via admin API, bw-sync, ZFS datasets, NFS export, PVs, postgres bootstrap, helm install, CoreDNS) plus an 8-item Gotchas section listing the issues hit during the original bringup.
  - `runbooks/paperless-not-ingesting.md` -- incident-response runbook for the most common Paperless failure mode: files in the consume dir but not appearing in the UI. Covers UID mismatch, polling-stability stalls, format rejection, 0-byte files, Redis/Postgres connection breakage, OCR failures, and disk-full conditions.
- Samba / SMB host service on the homelab for the paperless-ngx consume directory: new `ansible/playbooks/samba.yml` (Phase 1, tagged `[phase1, samba]`) and new `ansible/templates/smb.conf.j2`. Single share `\\192.168.2.2\paperless-consume` exposing `/media/root/storage1/nfs-share/paperless-consume/` with `force user/group = dataplicity` (UID 1000) so SMB writes land as the same UID the paperless container reads as. Initial deployment is INTENTIONALLY UNAUTHENTICATED (`guest ok = yes`, `guest only = yes`) -- the goal is zero friction for the wife's HP scanner workflow on her Windows laptop, and the security boundary is the home LAN topology + smb.conf `hosts allow` (LAN + Tailscale + loopback). Hardening TODOs (dedicated user, vault password, drop guest mode) are documented inline. Adds 445/tcp to `irl_firewall_allowed_tcp_ports` and opens `/media/root` from `0750` to `0755` so smbd's `force_user` worker can traverse the path. New `irl_samba_shares` list lives in `group_vars/homelab/main.yml`. End-to-end verified: `smbclient -N` from the laptop writes a file that lands as `UID 1000:1000` and is visible to the paperless pod via the existing hostPath PV.
- Windows clients note: modern Windows (10/11) blocks unauthenticated guest SMB by default. The connection instructions in the playbook's debug task include the registry tweak (`HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters\AllowInsecureGuestAuth = 1`) needed to enable it.

### Fixed
- `ansible/playbooks/deluge.yml`: override Debian's `UMask=007` on `deluged.service` with a systemd drop-in at `/etc/systemd/system/deluged.service.d/override.conf` setting `UMask=0000`. Debian's default made completed torrents land mode `0770`/`0660` owned by `debian-deluged` (UID 128, GID 134), which collides with the NFS export's `all_squash`+`anongid=1000` squash -- the laptop's squashed UID/GID 1000 matched neither owner nor group, so "other" perms (zero on `0770`) blocked access. Now downloads land `0777`/`0666`, world-accessible over NFS. Playbook also bumps `complete/` and `incomplete/` to `0777` and adds a one-time recursive `chmod a+rwX` to repair pre-existing files. Required for running the eXoDOS launcher directly from `/mnt/homelab-nfs/downloads/` on the laptop -- the launcher writes save games + per-game config back to disk.

### Changed
- Bump `helm-charts` submodule pointer to pick up `irl-paperless v0.2.0` (paperless-ngx 2.20.14, up from 2.14.7). Upgrade driven by the freeformz/paperless-ngx-mcp MCP server's API v9 requirement plus all security fixes across the 2.15.x-2.20.x line. Chart-level change only -- no ansible playbook or values-override edits needed. No custom filename templates or storage path templates are in use on this instance, so the stricter rendering introduced upstream in 2.20.7 has no impact.
- Paperless-ngx public hostname renamed from `docs.lab.infiniteroomlabs.cloud` to `archives.lab.infiniteroomlabs.cloud`. Updates `irl_services.paperless.subdomain`, `ansible/helm/paperless/values.yaml ingress.host`, and the matching homepage dashboard entry. Authentik OIDC provider redirect URI and the `paperless-admin` Bitwarden item URL were updated out-of-band to match. Bumps `helm-charts` submodule pointer to pull in `irl-paperless v0.1.1` which carries the matching chart-default rename plus two latent bug fixes (Tika image and PAPERLESS_REDIS env-substitution).
- `helm-deploy.yml`: new "Phase 3: Write Paperless secrets override" task that materializes `PAPERLESS_REDIS` with the password rendered inline from `vault_redis_password`. The chart can't use the k8s `$(VAR)` substitution syntax because bjw-s/common alphabetizes env vars and would render `PAPERLESS_REDIS` before `PAPERLESS_REDIS_PASSWORD`.
- `credentials-rotation.yml`: parent `nfs-share` export now sets `anonuid=1000,anongid=1000` (alongside the existing `all_squash`) so writes from the laptop's autofs mount land as UID 1000 instead of `nobody`. Required for paperless to read its own consume folder back through the hostPath PV.

### Deployed
- Deluge BitTorrent daemon live on homelab at `100.86.213.22:58846` (RPC) and `:8112` (web UI). Running deluged 2.0.3-4 from Debian bookworm (current stable; no newer in apt without a PPA). Admin auth verified end-to-end from laptop via RPC; downloads path pointed at the existing NFS-backed `/media/root/storage1/nfs-share/downloads/` so finished torrents are visible on the laptop through the autofs mount. Web UI runs with deluge-web's default password and should be changed or disabled if LAN exposure is a concern.
- Paperless-ngx upgraded in-place to 2.20.14 via `irl-paperless 0.2.0`. Helm release 3, rollout clean, DB migrations applied (latest: `paperless_mail.0029_mailrule_pdf_layout`), Redis/Celery/Index all OK. API v9 handshake verified end-to-end against the freeformz/paperless-ngx-mcp MCP server -- 100+ tools now functional. No document impact (2 PDFs preserved, 17,514 chars intact).
- Paperless-ngx is live on the homelab as `irl-paperless 0.1.1` at `https://archives.lab.infiniteroomlabs.cloud`. CNPG `paperless` database, Valkey DB index 3, Tika + Gotenberg sidecars, Authentik OIDC application + provider, Garage `paperless-backups` S3 bucket + IAM key pair, all 8 BW secrets synced to vault.yml + irl namespace. End-to-end NFS write verified -- a touch on the laptop at `/mnt/homelab-nfs/paperless-consume/` is visible inside the paperless pod at `/usr/src/paperless/consume/` as UID 1000.

### Fixed
- `scripts/bw-sync.sh`: pass values to yq via `strenv()` instead of shell-interpolating them into the expression. The old form (`yq e -i ".path = \"$value\"" ...`) broke the lexer on any value containing double quotes or other yq-syntax characters, silently producing a parser error + missing vault entry. This was latent until the new `PAPERLESS_SOCIALACCOUNT_PROVIDERS` JSON blob triggered it.
- `scripts/bw-sync.sh`: namespace the checksum state file by target (`ansible:` and `k8s:` prefixes). The previous unscoped state caused `--target both` to mark new K8s Secrets as "unchanged" and skip `kubectl apply` -- the ansible sync would `save_checksum` for every item, then the subsequent k8s sync would see the matching checksum and assume the Secret was already synced even though it had never been written to k8s. Falls back to the legacy unscoped lookup for state files written before this fix.

### Added
- `bw-sync-config.yaml`: five additional paperless secret mappings (Authentik OIDC client id/secret, rendered PAPERLESS_SOCIALACCOUNT_PROVIDERS JSON, Garage S3 backup access/secret keys) bringing paperless to 8 of 8 entries.
- Paperless-ngx ansible scaffolding: `helm-deploy.yml` Phase 3 task block with 4 PVC creates + helm install against `irl/irl-paperless`; `k3s.yml` hostPath PVs for paperless-consume (under nfs-share), paperless-media, and paperless-data; `k8s-secrets.yml` conditional tasks for `paperless-secrets`, `paperless-oidc`, and `paperless-backup-s3` (gated with `when:` so pending vault vars don't block deploy); `zfs.yml` chown task for paperless-media + paperless-data to UID 1000; `credentials-rotation.yml` paperless-consume sub-export with `anonuid/anongid=1000` so scanbridge writes from the laptop land as UID 1000; `ansible/helm/paperless/values.yaml` environment overrides. Existing hand-managed NFS share at `/media/root/storage1/nfs-share` is reused (no new exports playbook or mount config).
- `irl_services`, `irl_pg_databases`, and `irl_zfs_datasets` in group_vars extended for paperless (2 ZFS datasets, 1 service entry, 1 DB).
- `bw-sync-config.yaml`: three new paperless secret mappings (`pg-paperless` -> `postgres-paperless/password`, `paperless-secret-key` -> `paperless-secrets/secret-key`, `paperless-admin` -> `paperless-secrets/admin-password`). Five additional paperless secrets (Authentik OIDC trio, Garage S3 backup access/secret keys) are documented inline as pending manual setup.
- Homepage dashboard: new "Productivity" row with a Paperless-ngx service entry linking to `docs.lab.infiniteroomlabs.cloud`. Widget wiring is deferred until paperless is deployed and an API token is minted.
- Bump helm-charts submodule to include irl-paperless v0.1.0 (paperless-ngx for the homelab). Wrapper around gabe565/paperless-ngx 0.24.1 with shared CNPG Postgres + Valkey, Traefik IngressRoute at docs.lab.infiniteroomlabs.cloud, Authentik OIDC, Tika + Gotenberg, and nightly Garage S3 backup CronJob. Infra-side edits (ansible playbook/values, PV manifests, NFS export, bw-sync mappings, homepage entry) to follow in subsequent commits.
- Claude Code telemetry: Grafana dashboard (tokens, cost, code edits, active time, sessions, Loki logs) and OTel Collector NodePort exposure (30417 gRPC, 30418 HTTP) for laptop-to-cluster OTLP export
- Observability Phase 2: Tempo v1.24.4 (distributed tracing, 7d retention) and OTel Collector v0.147.1 (OTLP receiver, fan-out to Tempo/Prometheus/Loki) via irl-monitoring v0.3.2
- Traefik native OTel tracing: zero-code-change distributed tracing for all HTTP requests
- Deployment plan: 11 new decisions log entries, Phase 3 instrumentation assessment table
- Grafana dashboards: cluster overview, Traefik ingress, PostgreSQL (CNPG). Replaces pre-k8s dashboards
- Traefik metrics scraping via Tailscale IP (workaround for hostNetwork + nftables blocking pod->host traffic)
- Monitoring values file upload in helm-deploy playbook (was previously inline-only)

### Changed
- Monitoring values restructured for umbrella chart (kube-prometheus-stack key nesting), Tempo Grafana datasource added, Prometheus remote write receiver enabled
- Deployment plan updated to reflect Traefik migration, Plane SaaS, new services, DO node policy
- Homepage: switch Plane from self-hosted to SaaS (`https://app.plane.so/infinite-room-labs/`)
- OpenViking: revert Ollama endpoints from laptop Tailscale IP to in-cluster service (helm-charts submodule updated)
- OpenViking: switch VLM from Ollama smollm2 to Gemini 3.1 Pro Preview, with secret injection for API key
- OpenViking: switch embeddings from Ollama nomic-embed-text (768d) to Gemini gemini-embedding-001 (3072d) via OpenAI-compatible endpoint
- OpenViking: switch VLM from Gemini 3.1 Pro Preview to Gemini 2.5 Flash (250/day -> 10,000/day rate limit)
- NFS: add Tailscale CIDR (100.64.0.0/10) with rw access, LAN stays ro. Restructure `irl_nfs_allowed_subnets` to per-subnet `{cidr, mode}` objects
- README: rewritten to reflect multi-tool monorepo (Ansible, Helm, Docker, secrets sync sections; homelab environment; all modules and workspaces)
- `.gitignore`: un-ignore `.claude/` directory (`.claude/.gitignore` handles `settings.local.json`)
- `.gitignore`: fix double CRLF line endings

### Added
- `scripts/bw-notes-to-login.py`: convert BW Secure Notes to Login items via safe three-step swap
- `scripts/bw-organize.py`: sort misplaced BW items into proper IRL folder tree
- Nextcloud 33.0.0: deploy via upstream Helm chart with external PostgreSQL (CNPG), Valkey (Redis DB 3), ZFS-backed user data storage (100Gi), Caddy reverse proxy at `cloud.lab.infiniteroomlabs.cloud`, and cron sidecar
- Nextcloud: bw-sync-config entries for `pg-nextcloud` and `nextcloud-admin` secrets
- `.claude/`: commit agents, hooks, skills, and settings to version control
- `.idea/`: commit JetBrains project config with `.gitignore` for transient files
- Cloudflare: DNS read/write permissions added to bootstrap API token
- Terraform lock files for prod dns-records and sendgrid/config

### Fixed
- `bw-sync.sh`: skip `--vault-password-file` when `ANSIBLE_VAULT_PASSWORD_FILE` env var is set to avoid duplicate vault-id error
- `bw-sync-config.yaml`: rename `git.lab.infiniteroomlabs.cloud` to `homepage-gitea-token` (matches BW rename)
- Vaultwarden Helm chart: move `existingSecret` to correct `smtp.password` block (submodule updated)
- Vaultwarden SMTP: use FQDN trailing dot (`smtp.sendgrid.net.`) to bypass k8s `ndots:5` + musl resolver failure

### Added
- SendGrid: domain authentication DNS records (DKIM, DMARC, link branding) via Cloudflare Terraform
- SendGrid: reusable `sendgrid-config` Terraform module (sender verification, scoped API key, unsubscribe group)
- SendGrid: Terragrunt leaf at `prod/sendgrid/config/` with local state
- SendGrid: verified sender `no-reply@infiniteroomlabs.com` (auto-verified via domain auth)
- SendGrid: scoped `irl-mail-send` API key (mail.send only)
- SendGrid: default unsubscribe group for CAN-SPAM compliance
- Cloudflare: `prod/cloudflare/dns-records/` Terragrunt leaf for production DNS records
- Cloudflare: DNS read/write permissions added to bootstrap API token
- Secrets: SendGrid admin API key and mail-send key in Bitwarden and bw-sync-config
- Secrets: `SENDGRID_API_KEY` env var in .envrc and .env.example
- Skill: `manage-secrets` -- full lifecycle secrets management (create, rotate, edit, move, delete)
- Vaultwarden: irl-vaultwarden Helm chart wrapper (guerzon/vaultwarden@0.35.1) with CNPG PostgreSQL, SendGrid SMTP, admin panel
- Vaultwarden: Ansible deployment at Phase 3, service at passwords.lab.infiniteroomlabs.cloud
- Vaultwarden: Bitwarden items and bw-sync mappings for DB password and admin token
- Skill: `vault-unlock` -- unseal HashiCorp Vault via Bitwarden unseal keys
- Hook: `deny-vault-edit.py` -- blocks direct edits to vault.yml (PreToolUse)
- Hook: `terraform-fmt.py` -- auto-formats .tf files after edits (PostToolUse)
- Skill: `helm-deploy` -- deploy services via Ansible Helm playbook
- Skill: `tg-plan` -- run Terragrunt plan for leaf modules
- Agent: `infra-reviewer` -- infrastructure code review subagent

### Removed
- Plane: removed self-hosted deployment (CE and Enterprise charts) from k8s cluster
- Plane: removed all Ansible tasks, Helm values, Caddy routes, DNS records, secrets, and tests
- Plane: migrated to SaaS at https://app.plane.so/infinite-room-labs/

### Added
- Tests: `.gitignore` to exclude `__pycache__/` and `results/` from version control

### Fixed
- Homepage Kubernetes widget: NaN errors caused by NetworkPolicy blocking API access
- Homepage service widgets: DNS resolution failures from ndots:5 FQDN expansion (use short names)
- Homepage PostgreSQL: removed invalid Docker socket integration (server/container)

### Changed
- Homepage: pinned image tag to v1.2.0 (was :latest)
- Homepage: widget URLs use in-cluster short service names instead of external domains
- Homepage: added namespace/app labels to all 13 services for per-pod CPU/memory stats
- Homepage: wired Grafana widget with admin credentials, Gitea/Authentik with API tokens

### Added
- NetworkPolicy: allow-homepage-kube-api (scoped egress to k8s API for dashboard widgets)
- bw-sync: homepage-api-keys secret with Gitea and Authentik API tokens
- Design spec: docs/superpowers/specs/2026-03-23-homepage-kubernetes-widget-design.md
- Deployment plan: added 7 decisions log entries for 2026-03-22 (Oracle->DigitalOcean, Flannel VXLAN/Tailscale, Garage, Split DNS, OpenViking, node labels, acceptance tests)
- Deployment plan: updated service list with Garage, OpenViking, CoreDNS Internal, Plane (on DO node)
- Deployment plan: updated chart dependency map with new services
- Access guide: replaced IP:port URLs with `*.lab.infiniteroomlabs.cloud` domain names via Caddy internal TLS
- Access guide: added DigitalOcean agent node info, Garage S3, OpenViking, CoreDNS, Split DNS troubleshooting
- OpenViking: switched from ClusterIP to NodePort 31933, accessible at `context.internal.lab.infiniteroomlabs.cloud`
- Tests: added OpenViking and Homepage to SERVICES dict, DNS resolution list, Caddy health checks
- Homepage dashboard deployed at `home.lab.infiniteroomlabs.cloud` (NodePort 30000, HOMEPAGE_ALLOWED_HOSTS fix)
- CONTRIBUTING.md: full guide for adding services, secrets, testing, networking, gotchas

### Added
- DigitalOcean k3s agent node: Terraform module (`do-droplet`), cloud-init, Ansible inventory
- Garage S3 object storage: PVs, secrets, deployment in helm-deploy.yml, replaces MinIO for Plane
- Internal CoreDNS for Tailscale Split DNS (`lab.infiniteroomlabs.cloud`, `internal.infiniteroomlabs.cloud`)
- Tailscale Split DNS Terraform config (`environments/homelab/tailscale/split-dns/`)
- k3s agent playbook (`k3s-agent.yml`) with nftables template for agent nodes
- Node label taxonomy (`irl.dev/*`) for scheduling: provider, tier, storage, network, cost, persistence, gpu, memory-class
- Bitwarden provider config for future Terraform secret integration
- `.envrc` for homelab env (direnv auto-sources secrets from `~/.secrets/`)
- NetworkPolicy: allow-intra-namespace for cross-node pod communication
- OpenViking context database: PV, secret, deployment in helm-deploy.yml (Phase 2)
- Ollama values: add nomic-embed-text to model pull list
- Caddy playbook: log directory ownership fix, restart handler
- Plane NodePort services for Caddy path-based routing (web/api/space/admin/live)

### Changed
- Caddyfile template: all services use internal TLS (Tailscale-only access), Plane path-based routing, admin API enabled for reload
- CoreDNS: hostNetwork patch for port 53 (Tailscale Split DNS requires standard port)
- irl_services: fix Authentik port (30900->30080), remove Jenkins, mark ClusterIP services as caddy_proxy:false

### Changed
- k3s.yml: add `--flannel-iface tailscale0`, `--flannel-mtu 1230`, `--node-external-ip`, `--flannel-external-ip` for multi-node over Tailscale
- Plane values: nodeSelector + tolerations for DO node, MinIO disabled (using Garage), external_secrets for DNS race fix
- Authentik memory bumped to 1.5Gi
- ZFS playbook: support per-dataset custom properties (recordsize, xattr)
- root.hcl: add digitalocean and bitwarden providers
- bw-sync-config: add Garage secrets (rpc, admin, metrics, plane keys)
- run-ansible.sh: conditional TTY detection

### Previously (this session)
- ZFS ARC memory cap (8 GB) in zfs.yml playbook with persistent modprobe.d config
- Full Ansible automation for homelab (HP Z600, Debian 12)
  - Phase 0: security hardening (nftables, SSH, Docker TCP fix, cleanup)
  - Phase 1: Tailscale mesh, Caddy reverse proxy, ZFS datasets + sanoid
  - Phase 2: k3s (single-node, Flannel CNI) + Helm chart deployments
  - Kubernetes Secrets provisioned from Bitwarden via bw-sync.sh
  - Containerized Ansible runner (Dockerfile + run-ansible.sh)
- Terraform: cloudflare-dns-records module, tailscale-acl module, homelab environment
- Terraform: Tailscale provider added to root.hcl
- Bitwarden CLI integration for secrets management (bw-sync.sh + bw-sync-config.yaml)
- Helm values for 10 services (PostgreSQL via CNPG, Valkey, Vault, Gitea, Authentik, Plane, monitoring, Loki, Jenkins, Ollama)
- SOPs: deploy-new-service, backup-and-restore, rotate-secrets, add-dns-record
- Runbooks: drive-failure, service-down, security-breach, vault-sealed
- Pre-built Grafana dashboards (homelab overview, Docker containers, ZFS health)
- Deployment plan with decisions log and OTel observability architecture (`docs/plans/2026-03-20-homelab-k3s-helm-deployment.md`)

- Homelab service access guide (`docs/homelab-access-guide.md`)

### Changed
- helm-deploy.yml rewritten to use IRL charts (irl-postgres, irl-valkey, irl-gitea, irl-monitoring) from InfiniteRoomLabs/helm-charts repo
- Jenkins commented out (plugin version incompatibility, deferred)
- Ollama values rewritten to match actual chart schema (ollama.models.pull, ollama.gpu)
- Plane values rewritten for makeplane/plane-ce v1.4.1 (external PG/Redis, local MinIO/RabbitMQ)
- Plane deployment uses external_secrets.app_env_existingSecret with short hostnames (DNS race fix)
- Authentik server memory limit bumped from 1Gi to 1.5Gi
- run-ansible.sh: conditional TTY detection for non-interactive contexts
- bw-sync-config.yaml: added plane-live-secret-key mapping
- Vault storage class switched from zfs-local to local-path (SSD performance)

### Previously
- Docker Hub provider (`docker/docker ~> 0.5`) and `dockerhub-repo` module
- `global/dockerhub/repos` resource group with `claudesync-mcp` repository (namespace: `deathnerd`)
- `global-dockerhub-repos` TFC workspace
