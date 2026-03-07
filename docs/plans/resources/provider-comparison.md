# Compute Provider Comparison -- Research Detail

- **Date researched**: 2026-03-07
- **Roadmap reference**: Phase 1-3 (primary compute for all infrastructure services)
- **Status**: done

## Sources

- [Hetzner Cloud Pricing](https://www.hetzner.com/cloud/)
- [Hetzner CAX11 Benchmarks](https://www.vpsbenchmarks.com/hosters/hetzner/plans/cax11)
- [Hetzner Price Adjustment April 2026](https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/)
- [DigitalOcean Droplet Pricing](https://www.digitalocean.com/pricing/droplets)
- [Fly.io Resource Pricing](https://fly.io/docs/about/pricing/)
- [Fly.io Free Allowance Gone (2026)](https://www.saaspricepulse.com/tools/flyio)
- [AWS t4g.small Free Trial Extension](https://repost.aws/articles/ARi_gf6vo6TuqNtMQdiYPKyA/announcing-amazon-ec2-t4g-free-trial-extension)
- [AWS t4g.small Specs](https://cloudprice.net/aws/ec2/instances/t4g.small)
- [Vercel Hobby Plan](https://vercel.com/docs/plans/hobby)
- [Vercel Pricing](https://vercel.com/pricing)

## Summary

Hetzner CAX21 is the best fit for IRL infrastructure: 4 ARM vCPU, 8 GB RAM, 80 GB NVMe, 20 TB transfer at ~EUR7.49/mo. It provides the best price/performance ratio for always-on Docker Compose workloads. Oracle Cloud Always Free ARM (4 OCPU, 24 GB) is kept in reserve -- generous specs but operational concerns (idle reclamation, capacity shortages) make it unreliable as a sole primary. Fly.io was rejected due to cost (~$32-35/mo for our stack) and architectural mismatches with infrastructure backbone services.

## Detailed Findings

### Our Workload Requirements

| Service | RAM | Storage |
|---------|-----|---------|
| Vault | ~256 MB | minimal |
| OTel Collector | ~100 MB | minimal |
| Netdata | ~150 MB | minimal |
| IdP (Keycloak/Authentik) | ~512 MB | ~1 GB |
| Gitea | ~256 MB | ~10 GB |
| Jenkins controller | ~1 GB | ~10 GB |
| Ghost CMS | ~250 MB | ~5 GB |
| Postgres | ~512 MB | ~10 GB |
| Docker overhead | ~500 MB | ~30 GB (images) |
| **Total** | **~3.5 GB** | **~66 GB** |

### Provider Comparison -- Compute

| Provider | Plan | vCPU | RAM | Storage | Transfer | Price/mo | Arch |
|----------|------|------|-----|---------|----------|----------|------|
| Oracle Cloud | A1.Flex (Always Free) | 4 ARM | 24 GB | 200 GB | 10 TB | $0 | ARM64 |
| Hetzner | CAX11 | 2 ARM | 4 GB | 40 GB NVMe | 20 TB | ~EUR3.79 | ARM64 |
| **Hetzner** | **CAX21** | **4 ARM** | **8 GB** | **80 GB NVMe** | **20 TB** | **~EUR7.49** | **ARM64** |
| Hetzner | CAX31 | 8 ARM | 16 GB | 160 GB NVMe | 20 TB | ~EUR14.99 | ARM64 |
| DigitalOcean | Basic | 1 shared | 512 MB | 10 GB | 500 GB | $4 | x86 |
| DigitalOcean | Basic | 1 shared | 2 GB | 50 GB | 2 TB | $12 | x86 |
| AWS | t4g.small (trial) | 2 ARM | 2 GB | EBS extra | pay extra | ~$6 effective | ARM64 |
| Fly.io | 8x shared-cpu-1x | varies | ~3.5 GB | volumes extra | pay per GB | ~$32-35 | varies |

### Provider Deep Dives

#### Hetzner (SELECTED)

**Strengths:**
- All-inclusive pricing (IPv4, DDoS protection, firewall, 20 TB transfer included)
- NVMe SSD storage -- fast I/O for databases and container images
- Excellent ARM performance (Ampere Altra processors)
- Simple billing, no surprises
- Additional block volumes available at EUR0.052/GB/mo
- EU data centers (Germany, Finland) -- good for GDPR if needed

**Concerns:**
- EU-only for ARM instances (no US regions)
- Price increase coming April 1, 2026 (amounts TBD, reportedly 30-40% on some tiers)
- No free tier -- costs from day one

**Why CAX21 over CAX11:**
- CAX11 (4 GB RAM) would leave only ~500 MB headroom for our 3.5 GB stack -- too tight
- CAX21 (8 GB RAM) gives ~4.5 GB headroom for growth, caching, and spikes
- CAX21 (80 GB NVMe) fits our ~66 GB storage estimate with room to spare

#### Oracle Cloud Always Free (RESERVE)

**Strengths:**
- Genuinely free forever (Always Free tier, not a trial)
- Massive resources: 4 OCPU, 24 GB RAM, 200 GB storage
- 10 TB/month egress (100x what AWS gives free)
- Additional free services: MySQL HeatWave (50 GB), Autonomous DB, Vault, certificates

**Concerns:**
- Idle instance reclamation if CPU + network + memory all below 20% for 7 days
- ARM capacity frequently unavailable in popular regions
- Must upgrade to Pay As You Go (credit card) for reliable ARM provisioning
- 200 GB storage shared across ALL VMs (boot + data)
- Home region lock -- cannot change after account creation

**Decision:** Keep in reserve. Too many operational gotchas to rely on as sole primary, but too generous to ignore entirely. Good for Tailscale relay, edge functions, or emergency failover.

#### Fly.io (REJECTED for infra backbone)

**Strengths:**
- Purpose-built for containers -- excellent developer experience
- Multi-region deployment is trivial
- Good for stateless, scale-to-zero workloads
- Built-in TLS, load balancing, private networking

**Why rejected:**
1. **Cost**: ~$32-35/mo for our stack (per-machine billing for 8 always-on services vs ~EUR7.49 for equivalent on Hetzner)
2. **No host access**: Netdata needs host-level metrics -- impossible on Fly.io
3. **Jenkins Docker builds**: Docker-in-Docker inside Fly Machines is problematic
4. **Tailscale conflict**: Fly.io has its own private networking (6PN/Flycast); running Tailscale inside Fly Machines creates dual-network complexity
5. **Inter-service latency**: Services on a VPS talk over localhost; on Fly.io they traverse internal network
6. **Vendor lock-in**: Moving off Fly.io means rearchitecting; moving off Hetzner just means `docker compose up` elsewhere
7. **No free tier**: Removed for new customers in 2024. Only a 2-hour trial remains.

**May revisit for:** Future stateless application deployments (Dark Matter client-facing services, API endpoints) where multi-region and auto-scaling matter.

#### DigitalOcean (REJECTED)

**Why rejected:**
- $4/mo gets only 512 MB / 1 vCPU / 10 GB -- not enough for our stack
- $12/mo for 2 GB / 1 vCPU / 50 GB -- still tight and more expensive than Hetzner CAX21
- No ARM instances available
- Per-second billing since Jan 2026 is nice but doesn't offset the resource gap

#### AWS t4g.small (REJECTED)

**Why rejected:**
- Instance is free through Dec 2026, but hidden costs add ~$6/mo:
  - EBS storage: ~$2.40/mo for 30 GB gp3
  - Public IPv4 address: $3.60/mo (since Feb 2024)
- Only 2 GB RAM -- insufficient for our 3.5 GB stack
- Trial expires Dec 31, 2026 -- then full pricing kicks in ($0.0168/hr = ~$12.26/mo)
- AWS complexity tax: IAM, security groups, VPC configuration overhead

#### Vercel Hobby (NOT APPLICABLE for compute)

Vercel is a static site / serverless hosting platform, not a general compute provider.

- Hobby plan: free but **non-commercial use only** -- cannot use for a company
- Pro plan: $20/mo -- more expensive than alternatives for what we need
- Cannot run Docker containers, databases, or infrastructure services

**Decision:** Use Cloudflare Pages instead (free, unlimited bandwidth, already integrated with our DNS).

## IRL-Specific Recommendations

### Selected Architecture

| Tier | Provider | What | Cost |
|------|----------|------|------|
| Primary compute | Hetzner CAX21 | All Docker Compose services | ~EUR7.49/mo |
| Website hosting | Cloudflare Pages | Static site (Astro output) | $0 |
| Observability backend | Grafana Cloud free tier | Managed Prometheus, Loki, Tempo | $0 |
| Error tracking | Sentry free dev tier | Error tracking | $0 |
| Reserve compute | Oracle Cloud Always Free | Tailscale relay, failover | $0 |
| **Total** | | | **~EUR7.49/mo (~$8 USD)** |

### Scaling Path

1. **Current**: Single Hetzner CAX21 (8 GB) handles everything through Phase 3
2. **If RAM-constrained**: Upgrade to CAX31 (16 GB, ~EUR14.99/mo) -- no migration needed, just resize
3. **If Proxmox arrives**: Migrate heavy services to on-prem, downsize or cancel Hetzner
4. **If Oracle ARM works**: Use it for lightweight edge services alongside Hetzner
