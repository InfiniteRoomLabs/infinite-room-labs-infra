# Infrastructure Expansion Design: Observability, Website, and Multi-Tenant Monitoring

**Date**: 2026-03-07
**Status**: Approved
**Author**: Wes Gilleland + Claude Opus 4.6
**Relates to**: `infrastructure-roadmap.md`, `ideas/prds/prd-infrastructure-roadmap.md`, `ideas/prds/dark-matter-prd.md`

## Overview

This design expands the existing infrastructure roadmap with three new capability areas:

1. **Unified observability stack** -- OTel-centric pipeline serving both IRL internal monitoring and Dark Matter client monitoring
2. **Company website** -- Ghost CMS + Astro static build + Cloudflare Pages
3. **Proxmox migration path** -- design for transitioning from cloud-only to hybrid cloud + on-prem

All new components follow the existing principles: free-tier-first, IaC-managed, Tailscale-networked, containerized for portability.

## Decisions Made

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Collection pipeline | OTel-centric | Vendor-neutral, unified metrics+logs+traces, multi-tenant ready |
| Metrics storage | Grafana Cloud Prometheus (managed) | Free tier sufficient; self-host on Proxmox later |
| Logs storage | Grafana Cloud Loki (managed) | Same rationale |
| Traces storage | Grafana Cloud Tempo (managed) | Same rationale |
| Visualization | Grafana Cloud (managed) | Free tier: 10k metrics, 50GB logs, 50GB traces |
| Node metrics | Netdata on every node | Rich local dashboards + OTel export for centralized views |
| Error tracking | Sentry free dev tier (hosted) | Zero ops burden; 5K errors/mo, 1 user |
| CMS | Ghost (self-hosted) | Purpose-built for publishing, Content API for static builds |
| Static site generator | Astro | Modern, component-based, Cloudflare Pages integration |
| Website hosting | Cloudflare Pages | Free, already using Cloudflare for DNS, global CDN |
| Container orchestration | Docker Compose initially | Sufficient for current scale; K3s when Proxmox arrives |
| Compute allocation | Portable containers, decide per-service | Flexibility for Proxmox migration |
| Proxmox role | Future primary compute | Oracle ARM becomes cloud-edge/backup |

## Updated Roadmap Phases

### Phase 0: Foundation -- COMPLETE

- Terraform + Terragrunt (Porkbun domains, Cloudflare DNS zones)
- TFC backend (org: infinite-room-labs)
- Bootstrap layer (local state for TFC workspaces + CF tokens)

### Phase 0.5: Immediate Quick Wins (NEW -- no infra needed)

Set up managed free tier accounts. Zero infrastructure required.

- Grafana Cloud free tier account
  - 10k metrics/mo, 50GB logs, 50GB traces, 14-day retention
  - Managed Prometheus, Loki, Tempo backends included
- Sentry free dev tier account
  - 5K errors/mo, 1 user, 30-day retention
- Document accounts and free tier limits in infra repo

### Phase 1: Network + Secrets (unchanged)

- Tailscale tailnet setup (mesh VPN)
  - `terraform/modules/tailscale-*`
  - `ansible/roles/tailscale`
- Vault on Oracle ARM
  - `terraform/environments/prod/oci/vault/`
  - `ansible/roles/vault`

### Phase 1.25: Observability Pipeline (NEW)

Deploy the OTel Collector and Netdata. Backends are Grafana Cloud (managed).

- OTel Collector on Oracle ARM (~100MB RAM)
  - Receives telemetry from all services via OTLP
  - Exports metrics to Grafana Cloud Prometheus (remote write)
  - Exports logs to Grafana Cloud Loki (OTLP exporter)
  - Exports traces to Grafana Cloud Tempo (OTLP exporter)
  - Scrapes Prometheus `/metrics` endpoints from infrastructure services
  - `ansible/roles/otel-collector`
- Netdata on all nodes (~150MB RAM per node)
  - Local real-time dashboards for debugging
  - Exports to OTel Collector via Prometheus remote write
  - `ansible/roles/netdata`
- Grafana Cloud dashboards
  - Pre-built dashboards for Vault, Tailscale, and all subsequent services
  - Provisioned via Grafana Terraform provider
  - `terraform/environments/prod/grafana-cloud/dashboards/`
  - `terraform/environments/prod/grafana-cloud/alerts/`
- Sentry SDK integration
  - OTel SDK templates per language (PHP, Python, Node.js, Kotlin)
  - Sentry hooks into OTel spans for error-trace correlation
- Project onboarding automation
  - Ansible role: deploy OTel agent to any node
  - Docker Compose snippet templates for new services
  - Runbook: `docs/runbooks/add-new-project.md`
  - Runbook: `docs/runbooks/add-new-node.md`

### Phase 1.5: Identity + SSO (unchanged, now monitored from deploy)

- IdP (Keycloak/Authentik/Authelia/Kanidm) on Oracle ARM
  - OIDC clients for Vault, Git, Jenkins, Grafana, registries
  - OTel instrumentation from day one

### Phase 2: Source Control + CI/CD (unchanged, now monitored)

- Gitea on Oracle ARM (~256MB RAM -- chosen over GitLab for resource efficiency)
  - `terraform/environments/prod/oci/git/`
  - `ansible/roles/gitea`
- Jenkins controller (~1GB RAM)
  - `ansible/roles/jenkins`
- Docker runner config
  - `ansible/roles/docker-host`

### Phase 2.5: Company Website (NEW)

- Ghost CMS on Oracle ARM (~250MB RAM with SQLite)
  - Docker Compose deployment
  - Admin panel accessible only via Tailscale (not public)
  - Content API exposed for static build
  - `ansible/roles/ghost`
- Astro static site generator
  - Pulls content from Ghost Content API at build time
  - Outputs pure static HTML/CSS/JS
  - Source in website repo or `website/` directory
- Cloudflare Pages deployment
  - `terraform/environments/prod/cloudflare/pages-website/`
  - CI pipeline: Ghost webhook on publish triggers Astro build, deploys to Pages
- Domains
  - `infiniteroomlabs.com` -- homepage/landing page
  - `blog.infiniteroomlabs.com` -- blog content

Build trigger flow:
1. Author publishes content in Ghost admin (via Tailscale)
2. Ghost fires webhook to CI pipeline
3. Astro fetches all content from Ghost Content API
4. Astro builds static site
5. Output deployed to Cloudflare Pages
6. Live globally within seconds

### Phase 3: Registries + Databases (unchanged, now monitored)

- Pull-through cache + private registry on Oracle ARM
- Postgres pool (~512MB RAM)
- MariaDB pool (if needed)

### Phase 4: Dark Matter Multi-Tenant Observability (EXPANDED)

Scale the observability stack for Dark Matter client monitoring.

- Per-client OTel Collector instances
  - Each client gets isolated collection -- no cross-tenant data
  - Tenant labels added at collection layer
- Tenant-isolated Grafana orgs/folders
  - Each client sees only their data
  - Provisioned via Terraform
- Client onboarding automation
  - New client: Terraform provisions OTel Collector + Grafana org + alert rules
  - Ansible deploys monitoring agents to client infrastructure
- Multi-tenant Prometheus (Thanos or Cortex when needed)

### Phase 5: Proxmox Migration (NEW -- when hardware is ready)

Transition from cloud-only to hybrid cloud + on-prem.

**Moves to Proxmox** (resource-heavy, benefits from local hardware):
- Databases (Postgres, MariaDB) -- storage-heavy, latency-sensitive
- Jenkins runners -- CPU-intensive builds
- Gitea -- benefits from local disk I/O
- Self-hosted Prometheus + Loki + Tempo -- replaces Grafana Cloud storage
- Self-hosted Grafana -- replaces Grafana Cloud dashboards
- Ghost CMS -- frees Oracle ARM capacity

**Stays on Oracle ARM** (benefits from cloud availability):
- Vault -- high uptime requirements, lightweight
- OTel Collector (edge relay) -- receives data, forwards to Proxmox backends
- IdP public endpoints -- needs public reachability for SSO
- Tailscale coordination

**Migration procedure:**
1. Set up Proxmox VMs, join to Tailscale mesh
2. Deploy self-hosted Prometheus/Loki/Tempo/Grafana on Proxmox
3. Update OTel Collector config: change export targets from Grafana Cloud to self-hosted backends
4. Export Grafana Cloud dashboards, import into self-hosted Grafana
5. Verify data flow end-to-end
6. Gradually move services (databases, Git, Jenkins) to Proxmox
7. Oracle ARM becomes cloud edge

## Observability Architecture

### Data Flow

```
Applications (any node)
  |-- OTel SDK (OTLP) ---------> OTel Collector ------> Grafana Cloud Prometheus (metrics)
  |-- OTel SDK (OTLP) ---------> OTel Collector ------> Grafana Cloud Loki (logs)
  |-- OTel SDK (OTLP) ---------> OTel Collector ------> Grafana Cloud Tempo (traces)
  |-- Sentry SDK --------------> Sentry Cloud (errors)

Infrastructure Services (Vault, Jenkins, Gitea, etc.)
  |-- /metrics endpoint -------> OTel Collector (Prometheus receiver) --> Grafana Cloud

Every Node
  |-- Netdata agent ------------> OTel Collector (Prometheus remote write) --> Grafana Cloud
  |-- Netdata local dashboard    (direct access via Tailscale for debugging)
```

### OTel Collector Configuration Strategy

The collector uses a pipeline architecture:

- **Receivers**: OTLP (gRPC + HTTP), Prometheus scraper, Host Metrics
- **Processors**: Batch, memory limiter, resource detection (adds host/container metadata), tenant attribution
- **Exporters**: Prometheus remote write (Grafana Cloud), OTLP/HTTP (Grafana Cloud Loki + Tempo)

### Project Onboarding

**For a new application:**
1. Add OTel SDK to the project (language-specific package)
2. Set environment variables:
   - `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.tailscale:4317`
   - `OTEL_SERVICE_NAME=my-new-service`
3. Optionally add Sentry SDK for error tracking
4. Metrics, logs, and traces flow automatically

**For a new infrastructure node:**
1. Run Ansible: `ansible-playbook -e host=new-node site.yml --tags netdata,otel-agent`
2. Netdata + OTel agent deploy, metrics flow to collector

### Dark Matter Multi-Tenancy Model

Each Dark Matter client gets:
- Dedicated OTel Collector instance (data isolation at collection)
- Tenant label on all telemetry data
- Isolated Grafana org/folder (see only their data)
- Per-tenant alert rules and dashboards
- Provisioned via Terraform + Ansible automation

## Website Architecture

### Components

- **Ghost CMS**: Content management, admin panel, Content API
  - Self-hosted on Oracle ARM (Docker, ~250MB RAM, SQLite)
  - Admin accessible only via Tailscale
  - Content API used by Astro at build time
- **Astro**: Static site generator
  - Fetches content from Ghost Content API
  - Outputs static HTML/CSS/JS
  - Supports component-based development (React/Vue if needed)
- **Cloudflare Pages**: Hosting
  - Free tier: unlimited bandwidth, 500 builds/month
  - Global CDN, automatic HTTPS
  - Custom domains via existing Cloudflare DNS

### Content Workflow

1. Author writes/publishes in Ghost admin (Tailscale access)
2. Ghost webhook triggers CI build
3. Astro pulls content from Ghost Content API
4. Astro builds static site
5. Deploy to Cloudflare Pages
6. Live globally

## Oracle ARM Resource Budget (Before Proxmox)

| Service | RAM | Phase |
|---------|-----|-------|
| Vault | ~256MB | 1 |
| OTel Collector | ~100MB | 1.25 |
| Netdata | ~150MB | 1.25 |
| IdP (Keycloak/Authentik) | ~512MB | 1.5 |
| Gitea | ~256MB | 2 |
| Jenkins controller | ~1GB | 2 |
| Ghost CMS | ~250MB | 2.5 |
| Postgres | ~512MB | 3 |
| Docker overhead | ~500MB | all |
| **Total** | **~3.5GB** | |
| **Available** | **24GB** | |

Plenty of headroom for growth before Proxmox arrives.

## IaC Artifacts Summary

```
ansible/roles/
  otel-collector/          # OTel Collector deployment + config
  netdata/                 # Netdata agent + OTel export config
  otel-agent/              # Lightweight OTel agent for app nodes
  grafana/                 # Self-hosted Grafana (Phase 5)
  prometheus/              # Self-hosted Prometheus (Phase 5)
  loki/                    # Self-hosted Loki (Phase 5)
  tempo/                   # Self-hosted Tempo (Phase 5)
  ghost/                   # Ghost CMS Docker deployment

terraform/environments/prod/
  grafana-cloud/
    dashboards/            # Dashboard provisioning via Grafana TF provider
    alerts/                # Alert rule provisioning
  cloudflare/
    pages-website/         # Cloudflare Pages project + custom domains

docs/runbooks/
  add-new-project.md       # OTel SDK onboarding for applications
  add-new-node.md          # Ansible playbook for node monitoring setup
  observability-troubleshooting.md
  proxmox-migration.md     # Step-by-step migration procedure
```

## Open Questions for Implementation

1. **Astro vs Hugo**: Astro recommended for flexibility, but Hugo builds faster and is simpler if no interactive components needed. Final choice during implementation.
2. **Ghost database**: SQLite sufficient at small scale; migrate to Postgres (from Phase 3 pool) if performance requires it.
3. **Grafana Cloud retention limits**: 14-day retention on free tier. Acceptable for now; self-hosted backends in Phase 5 remove this limit.
4. **OTel Collector HA**: Single instance sufficient initially. Add a second collector (active-passive) when reliability requirements increase.
5. **Netdata Cloud vs local-only**: Netdata offers a free cloud tier (5 nodes). Could supplement Grafana Cloud dashboards. Evaluate during Phase 1.25.
