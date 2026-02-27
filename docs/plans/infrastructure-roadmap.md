# Infrastructure Roadmap

> Brain dump captured 2026-02-27. Living document — update as things get built.

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

## Rough Priority / Sequencing

Some of this is parallel, but the dependency chain roughly looks like:

```
Tailscale (network foundation)
  └─→ Vault (secrets foundation)
        ├─→ GitLab (code home)
        ├─→ Jenkins + Docker Runner (CI/CD)
        │     └─→ Container Registries + Artifact Caches
        ├─→ Databases (Postgres, MariaDB pools)
        └─→ Ansible roles (configure all of the above)

Web properties (blog, homepage, email) can proceed in parallel — they're Cloudflare-fronted and less coupled.
```

---

## Open Questions

- **Hosting**: Where does all this run? Single beefy box to start? Multiple VPS? Cloud provider?
- **GitLab vs Gitea**: GitLab is heavy — is the full GitLab feature set needed, or would something lighter work?
- **Database hosting**: Co-located with apps or separate dedicated hosts?
- **Monitoring / observability**: Not mentioned yet but will be needed (Prometheus, Grafana, Loki, etc.).
- **Backup strategy**: Needs definition for Vault, GitLab, databases.
