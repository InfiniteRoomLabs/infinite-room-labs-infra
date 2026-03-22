# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

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
