# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Changed
- README: rewritten to reflect multi-tool monorepo (Ansible, Helm, Docker, secrets sync sections; homelab environment; all modules and workspaces)
- `.gitignore`: un-ignore `.claude/` directory (`.claude/.gitignore` handles `settings.local.json`)
- `.gitignore`: fix double CRLF line endings

### Added
- `.claude/`: commit agents, hooks, skills, and settings to version control
- `.idea/`: commit JetBrains project config with `.gitignore` for transient files
- Cloudflare: DNS read/write permissions added to bootstrap API token
- Terraform lock files for prod dns-records and sendgrid/config

### Fixed
- Vaultwarden Helm chart: move `existingSecret` to correct `smtp.password` block (submodule updated)

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
