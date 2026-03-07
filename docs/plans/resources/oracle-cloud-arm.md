# Oracle Cloud ARM Free Tier -- Research Detail

- **Date researched**: 2026-03-07
- **Roadmap reference**: Phase 1-3 (primary compute for Vault, Git, Jenkins, databases, observability, website)
- **Status**: done

## Sources

- [OCI Always Free Resources (official docs)](https://docs.oracle.com/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm) -- updated 2025-08-05
- [Oracle Cloud Free Tier (landing page)](https://www.oracle.com/cloud/free/)
- [Oracle Cloud Free Tier FAQ](https://www.oracle.com/cloud/free/faq)
- [Full Metal Brackets - OCI Free Tier Breakdown](https://fullmetalbrackets.com/blog/oci-free-tier-breakdown) -- Jan 6, 2026
- [Reddit r/oraclecloud - A1.Flex Always Free confirmation](https://www.reddit.com/r/oraclecloud/comments/1nxycai/) -- Oct 2025

## Summary

Oracle Cloud's Always Free tier is the most generous free compute offering from any major cloud provider. The Ampere A1 ARM allocation (4 OCPUs, 24 GB RAM) is sufficient to run the entire IRL infrastructure stack through Phase 3. The primary constraint is the 200 GB block storage limit, not RAM or CPU. Idle instance reclamation is a real operational concern that requires keeping services actively utilized. Upgrading to Pay As You Go is strongly recommended to guarantee ARM provisioning availability.

## Detailed Findings

### Compute -- ARM (VM.Standard.A1.Flex)

| Attribute | Value |
|-----------|-------|
| Shape | VM.Standard.A1.Flex |
| Processor | Ampere A1 (ARM64 / aarch64) |
| Total OCPUs | 4 |
| Total RAM | 24 GB |
| Allocation model | Flexible -- split across 1-4 VMs in any combination |
| Expressed as | 3,000 OCPU-hours + 18,000 GB-hours per month |
| OS options | Oracle Linux, Ubuntu, CentOS |
| Region restriction | Must be created in home region |

The hours-based accounting works out to exactly 4 OCPUs + 24 GB running 24/7/31:
- 4 OCPUs x 24 hrs x 31 days = 2,976 OCPU-hours (under 3,000 limit)
- 24 GB x 744 hrs/month = 17,856 GB-hours (under 18,000 limit)

Possible allocation patterns:

| VMs | OCPUs per VM | RAM per VM | Boot Volume per VM | Remaining Storage |
|-----|-------------|-----------|-------------------|-------------------|
| 1 | 4 | 24 GB | 50 GB | 150 GB |
| 2 | 2 | 12 GB | 50 GB each (100 GB) | 100 GB |
| 4 | 1 | 6 GB | 47 GB each (188 GB) | 12 GB |

### Compute -- AMD (VM.Standard.E2.1.Micro)

| Attribute | Value |
|-----------|-------|
| Shape | VM.Standard.E2.1.Micro |
| Processor | AMD (x86_64) |
| CPU | 1/8 OCPU baseline, burstable to 1 full OCPU |
| RAM | 1 GB |
| Instances | Up to 2 |
| Network | 50 Mbps public, 480 Mbps private |
| OS options | Oracle Linux, Oracle Linux Cloud Developer, Ubuntu, CentOS |

These are very small but useful for lightweight tasks (Tailscale relay, cron jobs, health checks).

### Block Storage

| Attribute | Value |
|-----------|-------|
| Total capacity | 200 GB (boot volumes + block volumes combined) |
| Default boot volume | 50 GB per VM (minimum 47 GB) |
| Volume backups | 5 total (boot + block combined) |
| Custom boot volume | Up to 200 GB (but uses full storage allotment) |

**This is the tightest constraint.** With a single VM (50 GB boot), you get 150 GB for data. With 4 VMs (4 x 47 GB), you only get 12 GB for additional storage.

### Object & Archive Storage

| Attribute | Value |
|-----------|-------|
| Total capacity | 20 GB (shared across Standard, Infrequent Access, Archive) |
| API requests | 50,000/month |
| S3 compatibility | Yes (OCI Object Storage has S3-compatible API) |

### Networking

| Resource | Always Free Amount |
|----------|-------------------|
| Virtual Cloud Networks (VCNs) | 2 (IPv4 + IPv6) |
| Flexible Load Balancer | 1 (10 Mbps) |
| Network Load Balancer | 1 |
| Outbound data transfer | **10 TB/month** |
| Inbound data transfer | Unlimited, free |
| Site-to-Site VPN | 50 IPSec connections |
| VCN Flow Logs | 10 GB/month |

The 10 TB/month egress is exceptionally generous. AWS offers 100 GB free; OCI offers 100x that.

### Databases (included, separate from compute)

| Database | Instances | Storage | Notes |
|----------|-----------|---------|-------|
| Autonomous Database | 2 | 20 GB each | Oracle DB, 1 OCPU, 20 concurrent sessions |
| MySQL HeatWave | 1 standalone | 50 GB data + 50 GB backup | Could serve Ghost CMS or other apps |
| NoSQL | 1, up to 3 tables | 25 GB per table | 133M reads + writes/month |

The **free MySQL HeatWave** is notable -- it could replace self-hosted MySQL/Postgres for lightweight apps like Ghost CMS, saving RAM on the ARM instance.

### Security & Management

| Service | Always Free Amount |
|---------|-------------------|
| OCI Vault | All software keys free; 20 HSM key versions; 150 secrets |
| Certificates | 5 private CAs, 150 private TLS certificates |
| Bastions | 5 SSH bastions |
| Resource Manager (Terraform) | 100 stacks, 2 concurrent jobs |
| Console Dashboards | 100 dashboards |

### Observability (OCI built-in)

| Service | Always Free Amount |
|---------|-------------------|
| Monitoring | 500M ingestion datapoints, 1B retrieval datapoints |
| Logging | 10 GB/month |
| APM | 1,000 tracing events/hour, 10 Synthetic Monitor runs/hour |
| Notifications | 1M HTTPS/month, 1,000 email/month |
| Email Delivery | 100 emails/day (3,000/month) |

### Gotchas and Operational Concerns

#### 1. Idle Instance Reclamation

Oracle reclaims Always Free instances if ALL three conditions are true over a 7-day period:
- CPU utilization for 95th percentile < 20%
- Network utilization < 20%
- Memory utilization < 20% (A1 shapes only)

**Mitigation**: Run actual workloads (our services should be active enough). If concerned, a lightweight cron job generating CPU/memory activity can keep metrics above threshold. Active Docker containers running services like OTel Collector, databases, and web servers should naturally stay above these thresholds.

#### 2. ARM Capacity Shortage

ARM instances are notoriously difficult to provision in popular regions. "Out of capacity" errors are common.

**Mitigation**: Upgrade to **Pay As You Go** account. This requires a credit card (temporary $100 hold, refunded). PAYG dramatically improves ARM availability while still using Always Free resources at no cost. You are only charged for usage exceeding Always Free limits.

#### 3. Home Region Lock

Always Free resources must be created in your tenancy's **home region**. Choose your home region carefully at account creation -- it cannot be changed later. Pick a region with good ARM availability (check community reports).

#### 4. Account Verification

New accounts sometimes face verification delays. Oracle may request additional identity verification before enabling the Always Free tier. This can take 1-3 business days.

#### 5. Free Trial vs Always Free

The 30-day Free Trial ($300 credit) is separate from Always Free. When the trial expires, unused credits disappear, but Always Free resources persist indefinitely. If you have more than 20 GB in Object Storage when the trial ends, Oracle deletes all objects.

## IRL-Specific Recommendations

### Recommended VM Allocation

Use a **single ARM VM** (4 OCPU / 24 GB RAM / 50 GB boot + 150 GB block volume) for simplicity:
- All services run as Docker Compose stacks on one host
- Tailscale provides private networking to external services
- 150 GB available storage is sufficient for databases, container images, logs
- Single point of management (one host to SSH into, one set of Ansible plays)

Keep the 2x AMD micro VMs available for:
- Tailscale exit node / relay
- Lightweight health check services
- Emergency fallback / bastion host

### Storage Budget (Single VM, 150 GB available)

| Use | Estimated Size |
|-----|---------------|
| Docker images + layers | ~30 GB |
| PostgreSQL data | ~10 GB |
| Ghost CMS content | ~5 GB |
| Prometheus TSDB (if self-hosted later) | ~20 GB |
| Loki log data (if self-hosted later) | ~20 GB |
| Container logs | ~5 GB |
| Misc (configs, backups, tmp) | ~10 GB |
| **Total estimated** | **~100 GB** |
| **Headroom** | **~50 GB** |

### Alternative: Use OCI Free MySQL HeatWave for Ghost

Instead of running self-hosted MySQL/Postgres on the ARM VM, Ghost CMS could use the free MySQL HeatWave instance (50 GB). This saves ~512 MB RAM on the ARM box and provides managed backups. Trade-off: adds a network dependency between Ghost and the managed DB, and the managed DB isn't on the Tailscale mesh (would need a proxy or direct OCI VCN connectivity).
