# Infrastructure Roadmap

> Brain dump captured 2026-02-27. Living document — update as things get built.

## Guiding Principles

1. **Everything is IaC.** Every component discussed here gets provisioned, configured, and managed through code in this repo — Terraform for infra, Ansible for config, Dockerfiles for images, Jenkinsfiles for pipelines. If it can't be `terraform apply`'d or `ansible-playbook`'d from scratch, it's not done.
2. **Free tier first.** Squeeze every free tier across every cloud provider before spending a dollar. Static sites on Cloudflare Pages. VMs on Oracle Cloud free tier. Containers on Fly.io or Railway free tiers. Edge functions where they're free. If a component is low-traffic or doesn't need to be dynamic, it lives on whatever free thing will host it.
3. **Spread across providers strategically.** Not loyalty to one cloud — use the best free/cheap option per workload. The glue is Tailscale (mesh VPN) and this repo (single source of truth). Provider-specific Terraform modules keep things portable.
4. **IaC tracks the provider.** Each cloud provider gets its own path under `terraform/environments/{env}/{provider}/` so we always know what lives where and can tear down / recreate per-provider.

## Current State

- **Terraform + Terragrunt**: Porkbun domain registration and Cloudflare DNS zone onboarding — done locally, may or may not be pushed.
- **Email**: `wes@infiniteroomlabs.com` via Cloudflare email proxy routing to `wes.gilleland@gmail.com`. Single mailbox, no team accounts yet.
- **State backend**: Terraform Cloud (org `infinite-room-labs`).

---

## What We Need

### 1. Source Control — GitLab

Self-hosted GitLab instance. Replace or complement GitHub for internal repos, CI integration, and package registries.

- [ ] Provision host (VM/container)
- [ ] Configure GitLab instance
- [ ] Set up SSO / user accounts
- [ ] Mirror or migrate repos as needed
- [ ] Integrate with Jenkins for CI/CD triggers

### 2. Secrets Management — Vault

HashiCorp Vault for centralized secret storage and dynamic credentials.

- [ ] Deploy Vault (HA or single-node to start)
- [ ] Configure auth backends (tokens, AppRole, OIDC)
- [ ] Set up secret engines (KV, database, PKI)
- [ ] Integrate with Jenkins, GitLab, Terraform, Ansible
- [ ] Rotate all existing hardcoded / env-var secrets into Vault

### 3. Networking — Tailscale

Mesh VPN for secure internal connectivity across all infra nodes.

- [ ] Set up Tailscale account / tailnet
- [ ] Enroll all infrastructure hosts
- [ ] Define ACLs and access policies
- [ ] Use as the private transport layer for Vault, GitLab, databases, etc.

### 4. CI/CD — Jenkins

Jenkins as the primary CI/CD engine.

- [ ] Deploy Jenkins controller
- [ ] Configure Docker-based build agents (see Docker Runner below)
- [ ] Set up pipeline libraries and shared Jenkinsfiles
- [ ] Integrate with GitLab webhooks
- [ ] Connect to Vault for pipeline secrets
- [ ] Connect to container registries for image push/pull

### 5. Docker Runner

Dedicated Docker execution environment for Jenkins agents and ad-hoc workloads.

- [ ] Provision Docker host(s)
- [ ] Configure Docker daemon (storage driver, logging, registry mirrors)
- [ ] Register as Jenkins agent node(s)
- [ ] Lock down with Tailscale networking

### 6. Artifact Caches — Pull-Through Registries

Pull-through caches to reduce external dependency fetches and improve build speed / reliability.

- [ ] Deploy registry mirrors (Docker Hub, ghcr.io, etc.)
- [ ] Configure as pull-through caches
- [ ] Point all Docker daemons and build agents at the mirrors
- [ ] Consider caches for other package ecosystems (npm, pip, Maven) as needed

### 7. Container Registries

Private registries for internally built images.

- [ ] Deploy private container registry (GitLab built-in or standalone Harbor/Distribution)
- [ ] Configure auth and access control
- [ ] Set up image retention / garbage collection policies
- [ ] Integrate with CI pipelines for automated image builds and pushes

### 8. Databases — Postgres & MariaDB Pools

Managed or self-hosted database pools with connection pooling.

- [ ] Deploy PostgreSQL instance(s) + PgBouncer or equivalent pooler
- [ ] Deploy MariaDB instance(s) + ProxySQL or equivalent pooler
- [ ] Automate database/user/schema provisioning (Vault dynamic creds ideal)
- [ ] Backups, monitoring, alerting
- [ ] Expose only over Tailscale

### 9. Web Properties

#### Blog

- [ ] Choose platform (Ghost, Hugo, static site, etc.)
- [ ] Deploy and configure
- [ ] DNS + CDN via Cloudflare

#### Marketing Homepage

- [ ] Design and build landing page
- [ ] Deploy (static hosting, container, etc.)
- [ ] DNS + CDN via Cloudflare

#### Email

Current: single `wes@infiniteroomlabs.com` Cloudflare proxy to Gmail.

- [ ] Evaluate needs — team mailboxes, transactional email (Postmark/SES), mailing lists
- [ ] Scale email setup as headcount / product needs grow

### 10. Configuration Management — Ansible

Ansible for post-provisioning application setup. Reusable, modular roles.

- [ ] Scaffold Ansible directory structure (`ansible/` at repo root per monorepo convention)
- [ ] Build roles for each service (GitLab, Vault, Jenkins, databases, Docker hosts, etc.)
- [ ] Reusable pattern: every role templated with mandatory inputs and full parameter interfaces
- [ ] Inventory management (dynamic via Tailscale or cloud APIs)
- [ ] Integrate with Vault for secret injection during playbook runs

---

## Cross-Cutting Requirements

These apply to **everything** above:

| Requirement | Detail |
|---|---|
| **12-factor config** | Every service gets a fully documented variable interface. Mandatory inputs enforced. No implicit defaults hiding behavior. Config is injected via environment, not baked in. |
| **Human + AI operability** | All templates, roles, and modules must be self-describing — clear variable names, descriptions, types, constraints, and examples. An AI agent or a new team member should be able to operate any component from its interface alone. |
| **Templateized everything** | Terraform modules, Ansible roles, Jenkinsfiles, Dockerfiles — all parameterized. No snowflakes. |
| **Secrets via Vault** | Once Vault is up, nothing stores secrets in env files or CI variables. Everything goes through Vault. |
| **Tailscale by default** | Internal services bind to Tailscale IPs. Public exposure is explicit and intentional (Cloudflare edge only). |

---

## Hosting Strategy — Free Tier Scavenging

Spread workloads across providers to maximize free tiers. Everything stitched together via Tailscale.

| Workload | Candidate Provider(s) | Free Tier Notes |
|---|---|---|
| **Static sites** (blog, homepage) | Cloudflare Pages, Vercel, Netlify | All offer generous free static hosting + CDN. Already on Cloudflare for DNS so Pages is natural. |
| **Always-on VMs** (GitLab/Gitea, Vault, Jenkins, databases) | Oracle Cloud (ARM free tier: 4 OCPU / 24 GB RAM), GCP e2-micro, Azure B1s | Oracle's ARM free tier is the big one — enough for multiple containers on one box. |
| **Container workloads** (lighter services, runners) | Fly.io, Railway | Free tiers for low-usage containers. Good for bursty CI runners or edge-ish services. |
| **Artifact / registry caches** | Co-locate on the Oracle ARM box or use GitLab's built-in registry | Avoid paying for hosted registries when self-hosted is fine behind Tailscale. |
| **Databases** | Co-locate on VM initially; Neon (Postgres free tier), PlanetScale (MySQL free tier) as alternatives | Free managed DB tiers are tight on storage but fine for early stage. Self-hosted on the Oracle box gives more room. |
| **Email** | Cloudflare email routing (current), Resend free tier for transactional | No reason to pay for email yet. |
| **DNS + CDN** | Cloudflare (free) | Already here. Stay here. |

Each provider gets Terraform modules under `terraform/environments/{env}/{provider}/` — nothing is provisioned by hand.

---

## Priority / Sequencing

Dependency chain with IaC deliverables at each step:

```
Phase 0: Foundation (no cloud dependency)
  ├─ Push existing Terraform (Porkbun + Cloudflare) to this repo
  ├─ Scaffold Ansible directory structure
  └─ Document provider accounts + free tier limits

Phase 1: Network + Secrets
  ├─ Tailscale tailnet setup (Terraform provider exists)
  │     → terraform/modules/tailscale-*
  │     → ansible/roles/tailscale
  └─ Vault on Oracle ARM free tier
        → terraform/environments/prod/oci/vault/
        → ansible/roles/vault

Phase 2: Source Control + CI/CD
  ├─ GitLab or Gitea on Oracle ARM (co-locate with Vault)
  │     → terraform/environments/prod/oci/git/
  │     → ansible/roles/gitlab (or gitea)
  ├─ Jenkins controller (same host or second free-tier VM)
  │     → ansible/roles/jenkins
  └─ Docker runner config
        → ansible/roles/docker-host

Phase 3: Registries + Databases
  ├─ Pull-through cache + private registry (on Oracle box)
  │     → ansible/roles/registry
  ├─ Postgres pool (Oracle box or Neon free tier)
  │     → terraform/modules/database-*
  └─ MariaDB pool (Oracle box or PlanetScale free tier)

Phase 4: Web Properties (parallel track)
  ├─ Blog → Cloudflare Pages (Hugo/Astro static)
  │     → terraform/environments/prod/cloudflare/pages-blog/
  ├─ Homepage → Cloudflare Pages
  │     → terraform/environments/prod/cloudflare/pages-homepage/
  └─ Email scaling as needed
```

Web properties can start anytime — they don't depend on the backend infra chain.

---

## Open Questions

- **GitLab vs Gitea**: GitLab is a memory hog (~4 GB minimum). Gitea runs in ~256 MB. Do we need GitLab's built-in CI, registry, and project management, or is Gitea + Jenkins + standalone registry lighter and good enough?
- **Oracle ARM allocation**: 4 OCPU / 24 GB is a lot — one big VM or split into multiple smaller ones? One box is simpler, multiple is more resilient.
- **Database managed vs self-hosted**: Neon/PlanetScale free tiers are convenient but limited. Self-hosted on the Oracle box gives more control but more ops burden.
- **Monitoring / observability**: Not in the brain dump yet but will be needed. Grafana Cloud has a free tier (10k metrics, 50 GB logs). Worth adding as Phase 2.5.
- **Backup strategy**: Where do backups go? Another free-tier provider's object storage? Backblaze B2 (10 GB free)? Cloudflare R2 (10 GB free)?
- **Domain for internal services**: `*.internal.infiniteroomlabs.com` split-horizon DNS via Tailscale MagicDNS, or manage it ourselves?
