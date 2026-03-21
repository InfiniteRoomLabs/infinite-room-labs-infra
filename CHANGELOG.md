# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
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

### Changed
- helm-deploy.yml rewritten to use IRL charts (irl-postgres, irl-valkey, irl-gitea, irl-monitoring) from InfiniteRoomLabs/helm-charts repo
- Jenkins commented out (plugin version incompatibility, deferred)
- Vault storage class switched from zfs-local to local-path (SSD performance)

### Previously
- Docker Hub provider (`docker/docker ~> 0.5`) and `dockerhub-repo` module
- `global/dockerhub/repos` resource group with `claudesync-mcp` repository (namespace: `deathnerd`)
- `global-dockerhub-repos` TFC workspace
