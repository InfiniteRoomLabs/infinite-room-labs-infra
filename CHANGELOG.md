# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Documentation: four new SOPs / runbooks under `ansible/docs/`:
  - `sops/setup-windows-paperless-ingestion.md` -- end-user walkthrough for mapping the SMB share on a Windows 10/11 machine, including the `AllowInsecureGuestAuth` registry tweak and the `RequireSecuritySignature` workaround for Windows 11 24H2+, with troubleshooting for the common failure modes.
  - `sops/restore-paperless.md` -- DR procedure to restore Paperless-ngx from a `document_exporter` zip in the Garage `paperless-backups` bucket. Covers truncate, kubectl-cp, and a one-shot Job alternative for crash-loop scenarios.
  - `sops/samba-add-auth.md` -- forward-looking hardening recipe to replace the current guest-mode Samba share with a dedicated `paperlessscan` system user + Bitwarden-managed password. Referenced inline as a TODO in `group_vars/homelab/main.yml` and `smb.conf.j2`.
  - `sops/deploy-paperless-from-scratch.md` -- canonical end-to-end bringup SOP capturing the entire 10-step sequence (BW items, Authentik OIDC via `ak shell`, Garage bucket + IAM via admin API, bw-sync, ZFS datasets, NFS export, PVs, postgres bootstrap, helm install, CoreDNS) plus an 8-item Gotchas section listing the issues hit during the original bringup.
  - `runbooks/paperless-not-ingesting.md` -- incident-response runbook for the most common Paperless failure mode: files in the consume dir but not appearing in the UI. Covers UID mismatch, polling-stability stalls, format rejection, 0-byte files, Redis/Postgres connection breakage, OCR failures, and disk-full conditions.
- Samba / SMB host service on the homelab for the paperless-ngx consume directory: new `ansible/playbooks/samba.yml` (Phase 1, tagged `[phase1, samba]`) and new `ansible/templates/smb.conf.j2`. Single share `\\192.168.2.2\paperless-consume` exposing `/media/root/storage1/nfs-share/paperless-consume/` with `force user/group = dataplicity` (UID 1000) so SMB writes land as the same UID the paperless container reads as. Initial deployment is INTENTIONALLY UNAUTHENTICATED (`guest ok = yes`, `guest only = yes`) -- the goal is zero friction for the wife's HP scanner workflow on her Windows laptop, and the security boundary is the home LAN topology + smb.conf `hosts allow` (LAN + Tailscale + loopback). Hardening TODOs (dedicated user, vault password, drop guest mode) are documented inline. Adds 445/tcp to `irl_firewall_allowed_tcp_ports` and opens `/media/root` from `0750` to `0755` so smbd's `force_user` worker can traverse the path. New `irl_samba_shares` list lives in `group_vars/homelab/main.yml`. End-to-end verified: `smbclient -N` from the laptop writes a file that lands as `UID 1000:1000` and is visible to the paperless pod via the existing hostPath PV.
- Windows clients note: modern Windows (10/11) blocks unauthenticated guest SMB by default. The connection instructions in the playbook's debug task include the registry tweak (`HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters\AllowInsecureGuestAuth = 1`) needed to enable it.

### Changed
- Paperless-ngx public hostname renamed from `docs.lab.infiniteroomlabs.cloud` to `archives.lab.infiniteroomlabs.cloud`. Updates `irl_services.paperless.subdomain`, `ansible/helm/paperless/values.yaml ingress.host`, and the matching homepage dashboard entry. Authentik OIDC provider redirect URI and the `paperless-admin` Bitwarden item URL were updated out-of-band to match. Bumps `helm-charts` submodule pointer to pull in `irl-paperless v0.1.1` which carries the matching chart-default rename plus two latent bug fixes (Tika image and PAPERLESS_REDIS env-substitution).
- `helm-deploy.yml`: new "Phase 3: Write Paperless secrets override" task that materializes `PAPERLESS_REDIS` with the password rendered inline from `vault_redis_password`. The chart can't use the k8s `$(VAR)` substitution syntax because bjw-s/common alphabetizes env vars and would render `PAPERLESS_REDIS` before `PAPERLESS_REDIS_PASSWORD`.
- `credentials-rotation.yml`: parent `nfs-share` export now sets `anonuid=1000,anongid=1000` (alongside the existing `all_squash`) so writes from the laptop's autofs mount land as UID 1000 instead of `nobody`. Required for paperless to read its own consume folder back through the hostPath PV.

### Deployed
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
