# Plan: IRL Helm Charts Meta Repository

## Context

Bitnami pulled all versioned Docker images from Docker Hub (Broadcom paywall, Sept 2025). Our homelab k3s deployment depends on Bitnami charts for PostgreSQL and Redis -- both are now broken. Rather than patching individual charts, the Chairman wants a proper chart repository that IRL owns, with subcharts for every service gap we identify in the ecosystem.

This repo serves double duty: (1) unblocks the homelab deployment immediately, and (2) becomes an open-source contribution back to the ecosystem (PostHog model -- open source everything).

## Architecture

```
helm-charts/                          # New repo: infinite-room-labs/helm-charts
  charts/
    irl-postgres/                     # CloudNativePG wrapper -- operator + Cluster CR
      Chart.yaml                      # depends on cnpg/cloudnative-pg
      values.yaml
      templates/
        cluster.yaml                  # CNPG Cluster custom resource
    irl-valkey/                       # Valkey (Redis replacement) with auth + tuning
      Chart.yaml                      # depends on valkey/valkey
      values.yaml
      templates/
    irl-platform/                     # Umbrella chart -- entire homelab stack
      Chart.yaml                      # depends on all service charts
      values.yaml                     # unified overrides
      templates/
        network-policies.yaml         # per-service NetworkPolicies
    irl-gitea/                        # Thin wrapper around gitea-charts/gitea
      Chart.yaml
      values.yaml
    irl-monitoring/                   # Umbrella: kube-prometheus-stack + loki
      Chart.yaml
      values.yaml
  .github/
    workflows/
      lint-test.yml                   # helm/chart-testing-action on PRs
      release.yml                     # chart-releaser-action on main push
  ct.yaml                            # chart-testing config
  renovate.json                       # auto-bump dependency versions
  CLAUDE.md
  CHANGELOG.md
```

### Chart Dependency Map

```mermaid
graph TD
    subgraph "IRL Cluster (homelab node)"
        PG["irl-postgres<br/>(CNPG operator + Cluster CR)"]
        VK["irl-valkey<br/>(Valkey standalone)"]
        GITEA["irl-gitea<br/>(wrapper)"]
        AUTH["goauthentik/authentik<br/>(direct)"]
        MON["irl-monitoring<br/>(umbrella)"]
        VAULT["hashicorp/vault<br/>(direct)"]
        OLLAMA["ollama-helm/ollama<br/>(direct)"]
        GARAGE["Garage S3<br/>(direct, ZFS-backed)"]
        OPENVIKING["OpenViking<br/>(direct, Gemini-backed)"]
        COREDNS["CoreDNS Internal<br/>(Split DNS resolver)"]
        TRAEFIK["traefik/traefik<br/>(direct, hostNetwork)"]
        VAULTWARDEN["Vaultwarden<br/>(direct, password manager)"]
        NEXTCLOUD["Nextcloud<br/>(direct, cloud storage)"]
        HOMEPAGE["Homepage<br/>(direct, dashboard)"]
    end

    subgraph "DO Node (public-internet only)"
        DO_NOTE["Reserved for future<br/>public-facing services<br/>(tainted NoSchedule)"]
    end

    subgraph "External SaaS"
        PLANE_SAAS["Plane SaaS<br/>(app.plane.so)"]
    end

    TRAEFIK -->|IngressRoutes| GITEA
    TRAEFIK -->|IngressRoutes| AUTH
    TRAEFIK -->|IngressRoutes| MON
    TRAEFIK -->|IngressRoutes| VAULT
    TRAEFIK -->|IngressRoutes| HOMEPAGE
    TRAEFIK -->|IngressRoutes| VAULTWARDEN
    TRAEFIK -->|IngressRoutes| NEXTCLOUD
    TRAEFIK -->|IngressRoutes| OPENVIKING
    TRAEFIK -->|IngressRoutes| GARAGE

    PG --> CNPG["cnpg/cloudnative-pg<br/>(upstream)"]
    VK --> VALKEY["valkey/valkey<br/>(upstream)"]
    GITEA --> GITEACHART["gitea-charts/gitea<br/>(upstream)"]
    MON --> KPS["prometheus-community/<br/>kube-prometheus-stack"]
    MON --> LOKI["grafana/loki<br/>(upstream)"]
    MON --> TEMPO["grafana/tempo<br/>(traces)"]
    MON --> OTEL["open-telemetry/<br/>opentelemetry-collector"]
```

### What Gets Its Own IRL Chart vs Direct Upstream

| Service | Why IRL chart? | Chart name | Status |
|---------|----------------|------------|--------|
| PostgreSQL | Bitnami dead. CNPG operator needs a Cluster CR template. | `irl-postgres` | Deployed |
| Redis/Valkey | Bitnami dead. Valkey chart needs auth + tuning defaults. | `irl-valkey` | Deployed |
| Gitea | Needs external PG/Redis config + LFS PVC wiring. | `irl-gitea` | Deployed |
| Monitoring | Umbrella: kube-prometheus-stack + Loki + Tempo + OTel Collector. | `irl-monitoring` | Deployed (Phase 1); Phase 2 in progress |
| Traefik | Upstream chart works. hostNetwork, DNS-01 via Cloudflare. | Direct (values only) | Deployed |
| Authentik | Official chart works, just needs values. | Direct (values only) | Deployed |
| Vault | Official chart works. | Direct (values only) | Deployed |
| Jenkins | **SKIPPED** -- plugin version incompatibility, parking until needed. | Deferred | -- |
| Plane | **REMOVED** -- migrated to SaaS at `app.plane.so/infinite-room-labs/`. | N/A (external) | SaaS |
| Ollama | Community chart works. | Direct (values only) | Deployed |
| Garage | S3-compatible object storage. ZFS-backed on homelab node. | Direct (PV + Deployment) | Deployed |
| OpenViking | Agent memory/RAG context database. Gemini embeddings + VLM. | Direct (PV + Deployment) | Deployed |
| CoreDNS Internal | Tailscale Split DNS resolver. hostNetwork port 53. | Direct (Deployment) | Deployed |
| Vaultwarden | Self-hosted password manager. SendGrid email. | Direct (values only) | Deployed |
| Nextcloud | Self-hosted cloud storage. ZFS-backed user data. | Direct (values only) | Deployed |
| Homepage | Homelab dashboard. | Direct (values only) | Deployed |

## File Changes

### New repository: `infinite-room-labs/helm-charts`

Create via `gh repo create infinite-room-labs/helm-charts --public` from the IRL template-repo.

**charts/irl-postgres/**
- `Chart.yaml` -- depends on `cnpg/cloudnative-pg` operator chart
- `values.yaml` -- defaults: PG 16, standalone, 2Gi mem, existingSecret pattern
- `templates/cluster.yaml` -- CNPG `Cluster` CR with configurable instances, storage, PG params
- `templates/scheduled-backup.yaml` -- optional CNPG `ScheduledBackup` CR

**charts/irl-valkey/**
- `Chart.yaml` -- depends on `valkey/valkey`
- `values.yaml` -- defaults: standalone, 256Mi, requirepass via existingSecret, allkeys-lru
- `templates/network-policy.yaml` -- allow ingress only from labeled consumers

**charts/irl-gitea/**
- `Chart.yaml` -- depends on `gitea-charts/gitea`
- `values.yaml` -- defaults: external PG + Valkey, LFS on ZFS PVC, metrics enabled, mirror config
- `templates/lfs-pvc.yaml` -- PVC for LFS storage on zfs-local StorageClass

**charts/irl-monitoring/**
- `Chart.yaml` -- depends on `prometheus-community/kube-prometheus-stack` + `grafana/loki` + `grafana/tempo`
- `values.yaml` -- unified monitoring config: retention, NodePorts, dashboards
- `templates/dashboards-configmap.yaml` -- pre-built Grafana dashboards
- `templates/otel-collector.yaml` -- OpenTelemetry Collector DaemonSet (OTLP ingestion)

**charts/irl-platform/**
- `Chart.yaml` -- depends on all IRL charts + direct upstream charts
- `values.yaml` -- global overrides (domain, namespace, storage class)
- `templates/network-policies.yaml` -- inter-service allow rules
- `templates/namespace.yaml` -- irl namespace with labels

**Root files:**
- `.github/workflows/lint-test.yml` -- `helm/chart-testing-action` on PRs
- `.github/workflows/release.yml` -- `helm/chart-releaser-action` on main merge
- `ct.yaml` -- chart-testing config (target-branch: main, chart-dirs: charts)
- `renovate.json` -- auto-bump `Chart.yaml` dependency versions
- `CLAUDE.md` -- chart conventions, values patterns, contribution guide

### Modified in `infinite-room-labs-infra`

| File | Change |
|------|--------|
| `ansible/playbooks/helm-deploy.yml` | Replace bitnami/postgresql + bitnami/redis with IRL chart repo references |
| `ansible/helm/postgres/values.yaml` | Rewrite for CNPG Cluster CR (not Bitnami) |
| `ansible/helm/redis/values.yaml` | Rewrite for Valkey (not Bitnami Redis) |
| `ansible/inventory/group_vars/all/main.yml` | Add `irl_helm_repo` URL |

### Modified in parent CLAUDE.md

Add `helm-charts/` repo entry to the Current Repositories section.

## Implementation Order

1. ~~**Create the repo** from template-repo, add CLAUDE.md + CI workflows~~ DONE
2. ~~**irl-postgres chart** -- CNPG operator + Cluster CR~~ DONE
3. ~~**irl-valkey chart** -- Valkey standalone with auth~~ DONE
4. ~~**Update infra repo** -- swap Bitnami refs for IRL chart repo~~ DONE
5. ~~**Test** -- `helm install` both charts on the live k3s cluster~~ DONE
6. ~~**irl-gitea, irl-monitoring** -- wrapper charts~~ DONE
7. ~~**Reverse proxy migration** -- Caddy into k8s, then replaced by Traefik with DNS-01~~ DONE (PR #4, PR #7)
8. ~~**Additional services** -- Vaultwarden, Nextcloud, Homepage~~ DONE
9. **Observability Phase 2** -- Add Tempo + OTel Collector to irl-monitoring (IN PROGRESS)
10. **Observability Phase 3** -- Enable Traefik tracing, document app instrumentation status
11. **irl-platform umbrella** -- deferred, individual charts are proven and working

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-03-20 | Docker Compose -> k3s + Helm | Compose was reimplementing K8s poorly (shared networks, wait_for deps, hand-rolled health checks) |
| 2026-03-20 | Calico -> stock Flannel + kube-router | Single node doesn't need mesh CNI. Calico poisoned iptables state. Flannel just works. |
| 2026-03-20 | Bitnami -> CNPG + Valkey | Bitnami pulled all versioned images from Docker Hub (Broadcom paywall). CNPG is CNCF, Valkey is Linux Foundation. |
| 2026-03-20 | `--node-ip` uses LAN IP (192.168.2.2), not Tailscale | Tailscale IP on a different interface breaks pod-to-API routing (kernel can't route from cni0 to tailscale0). Tailscale IP added as `--tls-san` for external kubectl access. |
| 2026-03-20 | nftables must allow cni0 + flannel.1 in INPUT chain | Pod traffic arrives on cni0, not tailscale0. Default-deny INPUT was silently dropping all pod-to-API-server packets. Root cause of the entire k3s networking debug. |
| 2026-03-21 | CNPG manages its own superuser credentials | Can't use external secrets for postgres superuser. Database creation done via kubectl exec, not Helm Jobs. |
| 2026-03-21 | OpenTelemetry Collector + Tempo added to irl-monitoring | Complete the three pillars (metrics, logs, traces). Deploy monitoring stack first, layer OTel after services are generating traffic. Collector runs as DaemonSet, receives OTLP, routes to Prometheus/Loki/Tempo. |
| 2026-03-21 | NFS stays as home SAN | Chairman uses it as network storage for the household. Not moving to Tailscale-only access. |
| 2026-03-21 | Vault handles secrets + signing CA | HashiCorp Vault is the long-term secrets backend and certificate authority. Ansible Vault + bw-sync.sh is the bootstrap path. |
| 2026-03-21 | Jenkins skipped | Plugin version incompatibility (chart installs 2.479, plugins need 2.479.1+). Not critical for initial deployment. Revisit when CI/CD is needed -- may use Gitea Actions instead. |
| 2026-03-22 | Oracle Cloud abandoned, switched to DigitalOcean | ARM capacity unavailable on Oracle Cloud (Always Free tier perpetually out of stock) + Larry Ellison tax. DigitalOcean s-4vcpu-8gb in NYC3 at $48/mo selected instead. |
| 2026-03-22 | Flannel VXLAN over Tailscale networking | Requires `flannel-iface: tailscale0` on BOTH server and agent nodes + `flannel-mtu: 1230` to avoid encapsulation overhead. Without both settings, cross-node pod networking silently fails. |
| 2026-03-22 | Garage S3 replaces MinIO for Plane file storage | Garage runs on the homelab node (ZFS-backed), lightweight alternative to MinIO. Plane configured with external S3 credentials pointing to Garage. |
| 2026-03-22 | Tailscale Split DNS via CoreDNS | CoreDNS deployed with hostNetwork on port 53, registered as Tailscale Split DNS resolver. Eliminates /etc/hosts management for `*.lab.infiniteroomlabs.cloud` and `*.internal.lab.infiniteroomlabs.cloud`. |
| 2026-03-22 | OpenViking deployed for agent memory/RAG (Phase 1) | Context database for AI agent persistent memory and RAG retrieval. Deployed alongside nomic-embed-text model in Ollama. |
| 2026-03-22 | Node label taxonomy (irl.dev/*) for workload scheduling | Labels: provider, tier, storage, network, cost, persistence, gpu, memory-class. Enables nodeSelector-based scheduling across homelab and cloud nodes. |
| 2026-03-22 | Acceptance test suite added | Task + pytest + Goss framework. `task smoke` runs 17 smoke tests, `task validate` runs full suite with Goss system checks and HTML report generation. |
| 2026-03-24 | Caddy moved into k8s (PR #4) | Eliminate bare-metal dependency, enable LE DNS-01 via Cloudflare. Two Deployments: Caddy + config ConfigMap. |
| 2026-03-25 | k8s ndots:5 + Alpine/musl DNS workaround | Alpine pods fail external DNS resolution due to musl resolver + k8s default ndots:5. Workaround: use FQDN trailing dot for external hosts. |
| 2026-03-25 | Plane moved from DO node to homelab | Reduce cross-node latency to PG/Valkey. DO node reserved for future public-internet services. |
| 2026-03-27 | Plane removed, migrated to SaaS | Reduce homelab resource usage. Plane SaaS free for small teams. Dashboard link at `app.plane.so/infinite-room-labs/`. |
| 2026-03-29 | Vaultwarden added to stack | Self-hosted Bitwarden-compatible password manager. SendGrid for email delivery. FQDN workaround for SMTP (ndots:5 issue). |
| 2026-03-29 | Nextcloud added to stack | Self-hosted cloud storage. ZFS-backed user data PVC. External PG + Valkey. |
| 2026-04-04 | OpenViking switched to Gemini embeddings + VLM | Google AI API replaces local Ollama models. gemini-embedding-001 (3072d) for embeddings, Gemini 2.5 Flash for VLM. Lower latency, higher quality, no local GPU needed. |
| 2026-04-06 | Caddy replaced by Traefik (PR #7) | Native IngressRoute CRD, better k8s integration, built-in ACME DNS-01, ServiceMonitor for Prometheus, native OTel tracing support. irl-caddy chart deprecated. |
| 2026-04-06 | DO node reserved for public-internet services only | Taint `irl.dev/cloud=digitalocean:NoSchedule` prevents all scheduling. Only DaemonSets (node-exporter) run there. Future: public-facing services with tolerations. |
| 2026-04-06 | NFS exports extended to Tailscale CIDR | `100.64.0.0/10` added to NFS exports for cross-node access over Tailscale. Per-subnet mode config (rw for Tailscale, ro for LAN). |

## Observability Architecture (Decided 2026-03-21)

```mermaid
graph LR
    subgraph "Services"
        APPS["Gitea, Plane, Jenkins,<br/>custom apps"]
    end

    subgraph "Ingestion"
        OTELC["OTel Collector<br/>(DaemonSet)"]
        PROMTAIL["Promtail<br/>(log shipper)"]
    end

    subgraph "Storage"
        PROM["Prometheus<br/>(metrics)"]
        LOKI["Loki<br/>(logs)"]
        TEMPO["Tempo<br/>(traces)"]
    end

    subgraph "Visualization"
        GRAFANA["Grafana<br/>(dashboards)"]
    end

    APPS -->|OTLP| OTELC
    APPS -->|stdout/stderr| PROMTAIL
    OTELC -->|remote_write| PROM
    OTELC -->|loki exporter| LOKI
    OTELC -->|otlp| TEMPO
    PROMTAIL --> LOKI
    PROM --> GRAFANA
    LOKI --> GRAFANA
    TEMPO --> GRAFANA
```

**Phase 1 (COMPLETE)**: kube-prometheus-stack v65.8.1 (Prometheus + Grafana + Alertmanager) + Loki v6.24.1 + Promtail
**Phase 2 (IN PROGRESS)**: Tempo v1.24.4 (traces backend, single-binary, 7d retention) + OTel Collector v0.147.1 (Deployment mode, OTLP receiver, fan-out to Tempo/Prometheus/Loki)
**Phase 3 (PARTIAL)**: Traefik native OTel tracing (zero app changes). OpenViking Python SDK instrumentation (future). Most off-the-shelf services lack OTLP support -- see instrumentation table below.

### Phase 3 Instrumentation Assessment

| Service | OTLP Support | Effort | Priority | Status |
|---------|-------------|--------|----------|--------|
| Traefik | Native | Values only | High | Done |
| OpenViking | Python OTel SDK | App code changes | Medium | Future |
| Grafana | Built-in toggle | Values only | Low | Future |
| Gitea | None | Custom build required | Skip | -- |
| Nextcloud | None | PHP OTel extension | Skip | -- |
| Vaultwarden | None | Rust, no OTel crate | Skip | -- |
| Authentik | Django (theoretically possible) | Custom image | Skip | -- |
| Vault | None native | Audit log only | Skip | -- |
| Ollama | None | No tracing support | Skip | -- |

**OpenViking instrumentation** (when ready): Add `opentelemetry-api`, `opentelemetry-sdk`, `opentelemetry-exporter-otlp` to Python deps. Set env vars `OTEL_EXPORTER_OTLP_ENDPOINT=http://monitoring-opentelemetry-collector.irl.svc.cluster.local:4317` and `OTEL_SERVICE_NAME=openviking`.

## Verification

1. `helm repo add irl https://infinite-room-labs.github.io/helm-charts/`
2. `helm install postgresql irl/irl-postgres -n irl` -- CNPG operator installs, Cluster CR creates a running PG 16 pod
3. `helm install valkey irl/irl-valkey -n irl` -- Valkey pod running, auth working
4. `kubectl exec` into a test pod and connect to both services
5. CI: push a chart version bump, chart-releaser-action creates a GitHub release and updates index.yaml
