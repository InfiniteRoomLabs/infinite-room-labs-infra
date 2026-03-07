# Infrastructure Research Backlog

> Project-wide research tracker. AI agents: read the instructions below before touching this file.

---

## Agent Instructions

<!-- RESEARCH-PROTOCOL:START — Do not remove this block -->

### When to update this file

- A conversation surfaces an open question about infrastructure, tooling, providers, or architecture -- add it here.
- An open question in `docs/plans/infrastructure-roadmap.md` needs investigation -- add it here.
- You complete research on a topic -- update its status, write findings inline (summary) and in `docs/plans/resources/{topic-slug}.md` (detail).

### Scope: project-wide vs feature-scoped

| Scope | Location | Managed by |
|-------|----------|------------|
| **Project-wide** (this file) | `docs/plans/RESEARCH.md` | Any agent, any session |
| **Feature-scoped** | `kitty-specs/{feature}/research.md` | Spec Kitty `/research` command |

Use this file for cross-cutting infrastructure questions (provider free tiers, tool comparisons, architectural trade-offs). Use `kitty-specs/` research for questions specific to a single feature's implementation.

### How to claim a topic

1. Set the topic's `Status` to `in-progress`.
2. Add your session date under the status.
3. Do your research (see "How to Run a Research Round" below).
4. Write findings inline + in `docs/plans/resources/{topic-slug}.md`.
5. Set `Status` to `done`.

### How to record findings

- **Inline**: Update the topic's `Findings` field with a 3-5 sentence summary and key takeaway.
- **Detail file**: Create `docs/plans/resources/{topic-slug}.md` with the full write-up (see naming convention below).
- **Decision**: If the research resolves a decision, fill in the `Decision` field. If not, leave it blank and note what's still unresolved.

<!-- RESEARCH-PROTOCOL:END -->

---

## Output Expectations

Every completed research entry must have:

| Field | Required | Description |
|-------|----------|-------------|
| `Status` | Yes | `open`, `in-progress`, or `done` |
| `Roadmap link` | Yes | Which phase/component in `infrastructure-roadmap.md` this informs |
| `Key questions` | Yes | Numbered list of specific things to answer |
| `Resources` | Yes | Markdown links to official docs, pricing pages, Terraform registry, GitHub repos. Prefer stable URLs (official docs > blog posts). |
| `Findings` | On completion | 3-5 sentence summary with key numbers/facts. Link to detail file. |
| `Decision` | If resolved | What we decided and why. Otherwise note what's still open. |

### What goes where

- **Inline in this file**: Summary findings (3-5 sentences), key numbers, the decision.
- **`docs/plans/resources/{topic-slug}.md`**: Full write-up with all evidence, comparisons, tables, pros/cons. Standard header:

```markdown
# {Topic Title}

- **Date researched**: YYYY-MM-DD
- **Roadmap reference**: Phase X / Component Y
- **Status**: done

## Sources

- [Source 1](url)
- [Source 2](url)

## Summary

...

## Detailed Findings

...
```

### Naming convention for resource files

`docs/plans/resources/{topic-slug}.md` -- lowercase, hyphens, no spaces.

Examples:
- `oracle-cloud-arm.md`
- `gitlab-vs-gitea.md`
- `tailscale-free-tier.md`

---

## How to Run a Research Round

### Tools and agents

| Tool | Use for |
|------|---------|
| `WebSearch` | Quick lookups -- pricing pages, free tier limits, feature lists, "does X support ARM?" |
| `WebFetch` | Deep reading of a specific URL -- official docs pages, pricing tables, Terraform provider docs |
| `Task` (subagent_type: `Explore`) | Searching this repo for related code, existing modules, or config that a research topic connects to |
| `Task` (subagent_type: `general-purpose`) | Complex multi-step research that requires combining web searches, doc reads, and synthesis |

### Parallel research pattern

For maximum throughput, launch multiple `Task` agents in a single message -- one per research topic. Each agent gets:

1. The topic's key questions (from this file).
2. The resource links as starting points.
3. Instructions to return: summary findings, key numbers, recommendation, and list of sources visited.

Example prompt for a research agent:

```
Research Oracle Cloud ARM free tier for our infrastructure needs.

Key questions:
1. What are the exact always-free ARM compute limits (OCPUs, RAM, storage)?
2. Which regions offer the ARM free tier?
3. What are the known gotchas (account verification, capacity limits, reclamation)?
4. Does the Terraform OCI provider fully support ARM instance provisioning?

Start with these resources:
- https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier.htm
- https://registry.terraform.io/providers/oracle/oci/latest/docs

Return: 3-5 sentence summary, key numbers, gotchas list, recommendation, and all sources visited with URLs.
```

After agents return, update each topic's `Findings` and `Decision` fields in this file, and create the corresponding `docs/plans/resources/{topic-slug}.md` detail file.

### For deeper feature-scoped research

Use the Spec Kitty research workflow:

```
/spec-kitty.research
```

This scaffolds a full research artifact under `kitty-specs/` with evidence logs and source registers. Use this when a topic graduates from "project-wide question" to "we're actually building this feature now."

---

## Research Topics

### R01: Oracle Cloud ARM Free Tier

- **Status**: done
- **Roadmap link**: Phase 1-3 (Vault, GitLab/Gitea, Jenkins, databases -- all candidate for Oracle ARM hosting)
- **Key questions**:
  1. What are the exact always-free ARM compute limits (OCPUs, RAM, boot volume, block storage)?
  2. Which regions offer ARM free tier availability?
  3. What are the known gotchas (account verification delays, capacity limits, idle instance reclamation policies)?
  4. Does the Terraform `oci` provider fully support ARM instance provisioning, VCN setup, and security lists?
  5. One big VM (4 OCPU / 24 GB) vs multiple smaller VMs -- what does Oracle allow?
- **Resources**:
  - [Oracle Cloud Free Tier](https://www.oracle.com/cloud/free/)
  - [OCI Always Free Resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)
  - [Terraform OCI Provider](https://registry.terraform.io/providers/oracle/oci/latest/docs)
  - [OCI Ampere A1 Compute](https://docs.oracle.com/en-us/iaas/Content/Compute/References/arm.htm)
  - [Full Metal Brackets - OCI Free Tier Breakdown](https://fullmetalbrackets.com/blog/oci-free-tier-breakdown) (Jan 2026)
  - [Oracle Cloud Free Tier FAQ](https://www.oracle.com/cloud/free/faq)
- **Findings**: ARM free tier provides 4 OCPUs and 24 GB RAM (VM.Standard.A1.Flex), flexibly split across 1-4 VMs. Also includes 2x AMD micro VMs (1/8 OCPU, 1 GB each). Block storage is 200 GB total (boot + data combined, min 47 GB boot per VM). Object storage is 20 GB. Networking includes 2 VCNs, 1 LB, 1 NLB, and 10 TB/month egress. Critical gotcha: Oracle reclaims idle instances if CPU, network, AND memory all stay below 20% for 7 days. ARM capacity is frequently unavailable in popular regions -- upgrading to Pay As You Go (credit card required) significantly improves availability. OCI also provides 2 free Autonomous Databases (20 GB each), 1 free MySQL HeatWave (50 GB), and built-in Vault (150 secrets, 20 HSM keys). Full detail in `docs/plans/resources/oracle-cloud-arm.md`.
- **Decision**: Oracle ARM is viable but kept in reserve rather than used as primary compute. Concerns: 200 GB storage limit is tight, idle reclamation risk, ARM capacity shortages in popular regions. Primary compute moved to Hetzner CAX21 (~EUR7.49/mo) after provider comparison. Oracle ARM reserved for Tailscale relay, emergency failover, and potential future expansion. See `docs/plans/resources/provider-comparison.md` for the full evaluation.

---

### R02: GitLab vs Gitea

- **Status**: open
- **Roadmap link**: Phase 2 (Source Control)
- **Key questions**:
  1. GitLab CE minimum resource requirements (CPU, RAM, disk) vs Gitea?
  2. Which features do we actually need? (repo hosting, CI, container registry, issue tracking, package registry)
  3. ARM (aarch64) container image availability for both?
  4. Terraform providers: `gitlabhq/gitlab` vs `go-gitea/gitea` -- maturity, resource coverage?
  5. Ansible roles: community galaxy roles for each? Quality?
  6. If Gitea: how well does it integrate with Jenkins, Vault, external container registries?
- **Resources**:
  - [GitLab CE System Requirements](https://docs.gitlab.com/ee/install/requirements.html)
  - [Gitea Installation](https://docs.gitea.com/installation/install-with-docker)
  - [Terraform GitLab Provider](https://registry.terraform.io/providers/gitlabhq/gitlab/latest/docs)
  - [Gitea on Docker Hub](https://hub.docker.com/r/gitea/gitea)
  - [Forgejo](https://forgejo.org/) (Gitea fork -- worth evaluating)
- **Findings**: _Not yet researched._
- **Decision**: _Pending._

---

### R03: Tailscale Free Tier and IaC

- **Status**: open
- **Roadmap link**: Phase 1 (Network foundation)
- **Key questions**:
  1. Free tier limits -- devices, users, subnet routers, exit nodes?
  2. Terraform provider capabilities -- can it manage ACLs, auth keys, device approval?
  3. MagicDNS for internal service discovery -- how does it work, can we use `*.ts.net` names?
  4. ACL policy syntax -- how granular can we get (per-service, per-port)?
  5. Ansible integration -- is there an official or community role for node enrollment?
- **Resources**:
  - [Tailscale Pricing](https://tailscale.com/pricing)
  - [Tailscale Terraform Provider](https://registry.terraform.io/providers/tailscale/tailscale/latest/docs)
  - [Tailscale ACLs](https://tailscale.com/kb/1018/acls)
  - [Tailscale MagicDNS](https://tailscale.com/kb/1081/magicdns)
- **Findings**: _Not yet researched._
- **Decision**: _Pending._

---

### R04: HashiCorp Vault on ARM

- **Status**: open
- **Roadmap link**: Phase 1 (Secrets foundation)
- **Key questions**:
  1. Does Vault have official ARM64 binaries/containers?
  2. Minimum memory/CPU for single-node dev/prod modes?
  3. Best storage backend for single-node (file, Raft integrated, Consul)?
  4. Terraform Vault provider -- can it bootstrap policies, auth backends, secret engines?
  5. Ansible roles -- `ansible-community/vault` or `brianshumate/ansible-vault` -- which is maintained?
  6. Auto-unseal options without cloud KMS (transit unseal from another Vault, or Shamir with automation)?
- **Resources**:
  - [Vault Installation](https://developer.hashicorp.com/vault/install)
  - [Vault Docker Image](https://hub.docker.com/r/hashicorp/vault)
  - [Terraform Vault Provider](https://registry.terraform.io/providers/hashicorp/vault/latest/docs)
  - [Vault Integrated Storage (Raft)](https://developer.hashicorp.com/vault/docs/configuration/storage/raft)
- **Findings**: _Not yet researched._
- **Decision**: _Pending._

---

### R05: Jenkins on ARM

- **Status**: open
- **Roadmap link**: Phase 2 (CI/CD)
- **Key questions**:
  1. Official Jenkins ARM64 Docker images -- available? Stable?
  2. Controller + agent architecture on a single ARM host -- feasible?
  3. Docker-based build agents on ARM -- multi-arch image builds?
  4. Plugin ecosystem for Vault credential injection, Gitea/GitLab webhooks, container registry push?
  5. Jenkins Configuration as Code (JCasC) -- can we fully define Jenkins config in this repo?
  6. Alternatives worth considering? (Woodpecker CI, Drone, Tekton)
- **Resources**:
  - [Jenkins Docker Images](https://hub.docker.com/r/jenkins/jenkins)
  - [Jenkins Configuration as Code](https://www.jenkins.io/projects/jcasc/)
  - [Jenkins ARM Support](https://www.jenkins.io/blog/2022/12/27/run-jenkins-agent-as-a-service/)
  - [Woodpecker CI](https://woodpecker-ci.org/) (lightweight alternative)
- **Findings**: _Not yet researched._
- **Decision**: _Pending._

---

### R06: Container Registries and Pull-Through Caches

- **Status**: open
- **Roadmap link**: Phase 3 (Registries)
- **Key questions**:
  1. Distribution (Docker Registry v2) vs Harbor vs Gitea/GitLab built-in -- resource footprint comparison?
  2. Pull-through cache configuration for Docker Hub, ghcr.io -- how complex?
  3. ARM64 support for each option?
  4. Storage requirements and garbage collection -- how much disk for a small team?
  5. Auth integration with Vault or OIDC?
- **Resources**:
  - [Distribution (CNCF)](https://distribution.github.io/distribution/)
  - [Harbor](https://goharbor.io/)
  - [Distribution Pull-Through Cache](https://distribution.github.io/distribution/recipes/mirror/)
  - [Gitea Container Registry](https://docs.gitea.com/usage/packages/container)
- **Findings**: _Not yet researched._
- **Decision**: _Pending._

---

### R07: Database Free Tiers vs Self-Hosted

- **Status**: open
- **Roadmap link**: Phase 3 (Databases)
- **Key questions**:
  1. Neon free tier -- storage limit, compute hours, connection limit, branching?
  2. PlanetScale free tier -- storage, row reads/writes, connections? (Note: PlanetScale killed free tier in 2024 -- verify current state)
  3. Alternative managed MySQL/MariaDB free tiers?
  4. Self-hosted on Oracle ARM: Postgres + PgBouncer, MariaDB + ProxySQL -- memory/CPU overhead?
  5. Vault database secrets engine -- dynamic credential rotation for Postgres and MariaDB?
  6. Backup strategy for self-hosted DBs?
- **Resources**:
  - [Neon Free Tier](https://neon.tech/pricing)
  - [PlanetScale Pricing](https://planetscale.com/pricing)
  - [PgBouncer](https://www.pgbouncer.org/)
  - [ProxySQL](https://proxysql.com/)
  - [Vault Database Secrets Engine](https://developer.hashicorp.com/vault/docs/secrets/databases)
- **Findings**: _Not yet researched._
- **Decision**: _Pending._

---

### R08: Cloudflare Pages

- **Status**: open
- **Roadmap link**: Phase 4 (Web properties)
- **Key questions**:
  1. Free tier limits -- builds per month, bandwidth, sites, concurrent builds?
  2. Integration with Cloudflare DNS (already in use) -- automatic CNAME setup?
  3. Supported frameworks (Hugo, Astro, Next.js SSG)?
  4. Terraform Cloudflare provider -- can it manage Pages projects and deployments?
  5. Custom domain setup -- any quirks with existing zone management?
- **Resources**:
  - [Cloudflare Pages](https://pages.cloudflare.com/)
  - [Cloudflare Pages Limits](https://developers.cloudflare.com/pages/platform/limits/)
  - [Terraform Cloudflare Provider - Pages](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/pages_project)
- **Findings**: _Not yet researched._
- **Decision**: _Pending._

---

### R09: Backup Storage Free Tiers

- **Status**: open
- **Roadmap link**: Cross-cutting (backup strategy)
- **Key questions**:
  1. Backblaze B2 free tier -- storage limit, egress, API calls?
  2. Cloudflare R2 free tier -- storage, operations, egress (zero egress fees)?
  3. Oracle Cloud Object Storage free tier -- limits?
  4. S3-compatible API support for all three (for tool compatibility)?
  5. Encryption at rest and in transit?
  6. Which one works best with `restic` or `borgbackup`?
- **Resources**:
  - [Backblaze B2 Pricing](https://www.backblaze.com/cloud-storage/pricing)
  - [Cloudflare R2 Pricing](https://developers.cloudflare.com/r2/pricing/)
  - [Oracle Object Storage](https://docs.oracle.com/en-us/iaas/Content/Object/Concepts/objectstorageoverview.htm)
  - [Restic](https://restic.net/)
- **Findings**: _Not yet researched._
- **Decision**: _Pending._

---

### R10: Transactional Email

- **Status**: open
- **Roadmap link**: Phase 4 (Email)
- **Key questions**:
  1. Resend free tier -- emails/month, domains, API?
  2. Postmark free tier -- does one still exist?
  3. AWS SES -- free tier limits (62,000/month from EC2)?
  4. Which integrates best with Cloudflare DNS (SPF, DKIM, DMARC records)?
  5. Terraform support for each?
- **Resources**:
  - [Resend Pricing](https://resend.com/pricing)
  - [Postmark Pricing](https://postmarkapp.com/pricing)
  - [AWS SES Pricing](https://aws.amazon.com/ses/pricing/)
- **Findings**: _Not yet researched._
- **Decision**: _Pending._

---

### R11: Monitoring and Observability Stack

- **Status**: done
- **Roadmap link**: Phase 1.25 (Observability Pipeline -- new phase added by infrastructure expansion design)
- **Key questions**:
  1. Grafana Cloud free tier -- metrics series, log volume, trace spans, retention?
  2. Self-hosted Prometheus + Grafana + Loki on ARM -- resource overhead?
  3. Alloy (Grafana's new collector) vs Prometheus + node_exporter -- which is lighter?
  4. Alerting -- Grafana Cloud alerting free tier vs self-hosted Alertmanager?
  5. Uptime monitoring -- Grafana synthetic monitoring free tier or alternatives (UptimeRobot, Healthchecks.io)?
- **Resources**:
  - [Grafana Cloud Free Tier](https://grafana.com/pricing/)
  - [Grafana Alloy](https://grafana.com/oss/alloy/)
  - [Prometheus](https://prometheus.io/)
  - [Loki](https://grafana.com/oss/loki/)
  - [Healthchecks.io](https://healthchecks.io/)
  - [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/)
  - [Sentry Developer Tier](https://sentry.io/pricing/)
  - [Netdata](https://www.netdata.cloud/)
- **Findings**: Resolved via infrastructure expansion design. OTel-centric pipeline with OTel Collector as central hub receiving OTLP from all services. Grafana Cloud free tier (10k metrics, 50 GB logs, 50 GB traces, 14-day retention) as managed backends for Prometheus, Loki, and Tempo. Netdata on every node for system metrics + local dashboards. Sentry free dev tier (5K errors/mo) for error tracking. Self-hosted backends deferred to Phase 5 (Proxmox migration). Architecture serves both IRL internal and Dark Matter multi-tenant use cases.
- **Decision**: OTel Collector + Grafana Cloud (managed) + Netdata + Sentry free tier. Full design in `docs/plans/2026-03-07-infrastructure-expansion-design.md`. Implementation plan in `docs/plans/2026-03-07-infrastructure-expansion-plan.md`.

---

### R12: Compute Provider Comparison (Fly.io, Hetzner, DigitalOcean, AWS, Vercel)

- **Status**: done
- **Roadmap link**: Phase 1-3 (Primary compute for all infrastructure services)
- **Key questions**:
  1. Fly.io free tier -- VMs, memory, bandwidth, regions? (Hobby plan changes in 2024/2025?)
  2. Railway free tier -- hours/month, memory, storage? (They also changed tiers recently)
  3. ARM support on either platform?
  4. Cold start behavior for low-traffic containers?
  5. Terraform providers for either?
  6. Are these actually useful for our workloads, or is Oracle ARM better for everything?
  7. Hetzner ARM (CAX series) pricing and specs?
  8. DigitalOcean cheapest droplets?
  9. AWS t4g.small free trial details and hidden costs?
  10. Vercel Hobby plan restrictions?
- **Resources**:
  - [Fly.io Pricing](https://fly.io/docs/about/pricing/)
  - [Hetzner Cloud](https://www.hetzner.com/cloud/)
  - [DigitalOcean Droplet Pricing](https://www.digitalocean.com/pricing/droplets)
  - [AWS EC2 T4g Free Trial](https://aws.amazon.com/ec2/instance-types/t4/)
  - [Vercel Pricing](https://vercel.com/pricing)
  - [Hetzner Price Adjustment April 2026](https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/)
- **Findings**: Fly.io removed free tier for new customers in 2024; now 2-hour trial only. Running our 8-service stack on Fly.io would cost ~$32-35/mo (per-machine billing). Also architecturally mismatched: no host for Netdata, Jenkins Docker-in-Docker is painful, Tailscale conflicts with Fly.io's own private networking. Hetzner CAX21 (4 ARM vCPU, 8 GB RAM, 80 GB NVMe, 20 TB transfer) at ~EUR7.49/mo is the best price/performance for always-on Docker Compose infrastructure. DigitalOcean starts at $4/mo but only 512 MB / 1 vCPU / 10 GB -- not competitive. AWS t4g.small is "free" through Dec 2026 but hidden costs (EBS + IPv4) add ~$6/mo for only 2 GB RAM, and the trial expires. Vercel Hobby is free but non-commercial only -- unusable for a company. Full detail in `docs/plans/resources/provider-comparison.md`.
- **Decision**: Hetzner CAX21 as primary compute (~EUR7.49/mo). Oracle ARM kept in reserve. Cloudflare Pages for static website hosting (free). Fly.io rejected for infrastructure backbone (cost + architectural mismatch); may revisit for future stateless app deployments.

---

### R13: SSO / Identity Provider

- **Status**: open
- **Roadmap link**: Phase 1.5 (Identity + SSO -- right after Vault, before everything else authenticates)
- **Key questions**:
  1. Keycloak vs Authentik vs Authelia vs Kanidm -- resource footprint (RAM, CPU) on ARM?
  2. Which ones have ARM64 container images?
  3. Terraform providers -- Keycloak has `mrparkers/keycloak`, Authentik has one too. Maturity? Can they manage realms, clients, roles, mappers as code?
  4. OIDC client support matrix -- which of our services support OIDC? (Vault, Gitea, GitLab, Jenkins, Grafana, Harbor/Distribution)
  5. Database requirements -- Keycloak needs Postgres, Authentik needs Postgres + Redis. How does this fit with our DB pool plan?
  6. Can the full config (realms, clients, roles, groups, users) be defined declaratively and version-controlled?
  7. Ansible roles available for each? Quality?
  8. Authelia and Kanidm are lighter but more limited -- is forward-proxy auth (Authelia) enough, or do we need a full IdP with token issuance (Keycloak/Authentik)?
- **Resources**:
  - [Keycloak](https://www.keycloak.org/)
  - [Keycloak Docker](https://quay.io/repository/keycloak/keycloak)
  - [Terraform Keycloak Provider](https://registry.terraform.io/providers/mrparkers/keycloak/latest/docs)
  - [Authentik](https://goauthentik.io/)
  - [Authentik Docker](https://docs.goauthentik.io/docs/install-config/install/docker-compose)
  - [Terraform Authentik Provider](https://registry.terraform.io/providers/goauthentik/authentik/latest/docs)
  - [Authelia](https://www.authelia.com/)
  - [Kanidm](https://kanidm.com/)
- **Findings**: _Not yet researched._
- **Decision**: _Pending._

---

### R14: Git DAG — Repo Dependency Graph Engine

- **Status**: open
- **Roadmap link**: Future / Sister Projects (Git DAG)
- **Key questions**:
  1. What git primitives are available for efficiently discovering cross-repo relationships? (`git submodule`, `git worktree list`, subtree metadata, custom conventions?)
  2. Existing tools in this space — `meta`, `git-subrepo`, `josh`, `gita`, Bazel/Buck repo graphs, Google's `repo` tool — what do they cover and where do they fall short?
  3. Graph representation — in-memory from git queries on demand, or materialized into a lightweight store (SQLite, flat file, git notes)?
  4. Efficient change detection — can `git rev-parse` + `git status` across N repos be parallelized cheaply, or does this need a daemon / filesystem watcher?
  5. API surface — REST? GraphQL? gRPC? What makes sense for a tool that's primarily queried by CI systems and UIs?
  6. UI framework — lightweight dashboard (Svelte, htmx) or TUI for terminal-native workflows?
  7. Language choice — Go and Rust both have strong git libraries (`go-git`, `gitoxide`). Which gives better ergonomics for this use case?
- **Resources**:
  - [git-submodule](https://git-scm.com/docs/git-submodule)
  - [git-worktree](https://git-scm.com/docs/git-worktree)
  - [meta (multi-repo tool)](https://github.com/mateodelnorte/meta)
  - [josh (git proxy)](https://github.com/josh-project/josh)
  - [gita (manage multiple repos)](https://github.com/nosarthur/gita)
  - [go-git](https://github.com/go-git/go-git)
  - [gitoxide (Rust)](https://github.com/Byron/gitoxide)
- **Findings**: _Not yet researched._
- **Decision**: _Pending._
