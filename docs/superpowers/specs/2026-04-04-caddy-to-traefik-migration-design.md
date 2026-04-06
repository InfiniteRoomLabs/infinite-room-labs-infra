# Caddy-to-Traefik Migration Design

**Date**: 2026-04-04
**Status**: Approved
**Scope**: Replace Caddy reverse proxy with Traefik in the homelab k3s cluster

## Motivation

Caddy is an HTTP-only (Layer 7) reverse proxy. It cannot proxy raw TCP protocols like SSH, which forces Gitea SSH access through `kubectl port-forward`. Traefik is a multi-protocol edge router with first-class Kubernetes integration (CRDs, auto-discovery) and native TCP/UDP routing. Migrating to Traefik:

- Eliminates the port-forward requirement for Gitea SSH
- Moves routing configuration from a centralized Ansible template into Kubernetes-native IngressRoute resources co-located with the services they route to
- Removes the need for a custom Docker image (no xcaddy build step)
- Aligns the ingress layer with Kubernetes conventions

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Deployment method | Own Helm release via Ansible | Consistent with existing deployment pipeline; avoids k3s-managed component on a different upgrade schedule |
| Route resources | Traefik IngressRoute CRDs | Needed for TCP routing (Gitea SSH); more expressive than standard Ingress; lock-in acceptable for single-cluster homelab |
| DNS management | Keep `irl_services` dict | Pragmatic; ExternalDNS requires etcd backend for CoreDNS or architectural rework; revisit later |
| Cutover strategy | Big-bang with pre-validation | 11 services is small enough; avoids split-brain complexity of gradual migration |
| Network mode | `hostNetwork: true` | Same as Caddy today; binds 80/443/2222 directly on node; bypasses NetworkPolicy (same security model) |

## Architecture

### Traefik Deployment

- **Chart**: `traefik/traefik` (upstream, no wrapper chart needed)
- **Values**: `ansible/helm/traefik/values.yaml`
- **Image**: Stock `traefik` from Docker Hub (no custom build)
- **Network**: `hostNetwork: true`, `dnsPolicy: ClusterFirstWithHostNet`
- **Node selector**: `irl.dev/tier: data`

### Entrypoints

| Name | Port | Protocol | Purpose |
|------|------|----------|---------|
| `web` | 80 | HTTP | Redirect to HTTPS |
| `websecure` | 443 | HTTPS | All HTTP services |
| `gitssh` | 2222 | TCP | Gitea SSH |

### TLS Configuration

- **ACME provider**: Let's Encrypt production
- **Challenge type**: DNS-01 via Cloudflare
- **Cloudflare token**: Existing Bitwarden item `cloudflare-caddy-dns01-token`, synced to Kubernetes secret `traefik-cloudflare-token` via `bw-sync.sh`
- **Certificate storage**: `/data/acme.json` on a PVC (ZFS-backed `local-path`, 1Gi)
- **Cert resolver name**: `letsencrypt`

### Monitoring

- Traefik exposes Prometheus metrics natively at `:9100/metrics`
- ServiceMonitor resource with `release: monitoring` label for kube-prometheus-stack discovery

### Global Middleware

A single `redirect-to-https` Middleware deployed with Traefik:

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: redirect-to-https
  namespace: irl
spec:
  redirectScheme:
    scheme: https
    permanent: true
```

All IngressRoutes on the `web` entrypoint reference this middleware.

## IngressRoute Placement

Each service gets an IngressRoute in the Helm chart or Ansible manifest that deploys it:

| Service | IngressRoute Location | Type |
|---------|----------------------|------|
| Gitea (HTTP) | `irl-gitea` chart | IngressRoute |
| Gitea (SSH) | `irl-gitea` chart | IngressRouteTCP |
| Authentik | Standalone Ansible manifest | IngressRoute |
| Grafana | `irl-monitoring` chart | IngressRoute |
| Prometheus | `irl-monitoring` chart | IngressRoute |
| Alertmanager | `irl-monitoring` chart | IngressRoute |
| Vault | Standalone Ansible manifest | IngressRoute |
| Homepage | Standalone Ansible manifest | IngressRoute |
| Vaultwarden | Standalone Ansible manifest | IngressRoute |
| OpenViking | `irl-openviking` chart | IngressRoute |
| Nextcloud | Standalone Ansible manifest | IngressRoute |
| Garage UI | `irl-garage` chart | IngressRoute |

### IngressRoute Template Pattern (chart-based)

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: {{ include "<chart>.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "<chart>.labels" . | nindent 4 }}
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`{{ .Values.ingress.host }}`)
      kind: Rule
      services:
        - name: {{ .Values.ingress.serviceName }}
          port: {{ .Values.ingress.servicePort }}
  tls:
    certResolver: letsencrypt
    domains:
      - main: {{ .Values.ingress.host }}
```

### IngressRoute Template Pattern (standalone Ansible)

```yaml
# ansible/templates/ingressroute-{{ svc_name }}.yaml.j2
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: {{ svc_name }}
  namespace: {{ irl_k8s_namespace }}
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`{{ svc.subdomain }}.{{ domain }}`)
      kind: Rule
      services:
        - name: {{ svc.cluster_svc }}
          port: {{ svc.cluster_port }}
  tls:
    certResolver: letsencrypt
    domains:
      - main: {{ svc.subdomain }}.{{ domain }}
```

Standalone manifests are applied via `kubernetes.core.k8s` in `helm-deploy.yml` after Traefik is deployed.

### Gitea SSH IngressRouteTCP

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRouteTCP
metadata:
  name: gitea-ssh
  namespace: irl
spec:
  entryPoints:
    - gitssh
  routes:
    - match: HostSNI(`*`)
      services:
        - name: gitea-ssh
          port: 22
```

## Cutover Procedure

### Phase 1: Pre-deploy (no downtime)

1. Add `traefik` Helm repo to Ansible
2. Create `traefik-cloudflare-token` Kubernetes secret (update `bw-sync-config.yaml`)
3. Create Traefik PVC for cert storage
4. Deploy Traefik with temporary entrypoints (8080/8443/2222)
5. Deploy all IngressRoute resources (chart upgrades + standalone manifests)
6. Traefik begins issuing LE certs

### Phase 2: Validation (no downtime)

Test every service through Traefik on temporary ports:

```bash
# HTTP services (repeat for all 11)
curl -k --resolve git.lab.infiniteroomlabs.cloud:8443:100.86.213.22 \
  https://git.lab.infiniteroomlabs.cloud:8443/api/v1/version

# Gitea SSH
ssh -T -p 2222 git@100.86.213.22
```

If any service fails, fix before proceeding. Caddy is still serving production.

### Phase 3: Cutover (~30 seconds downtime)

1. Scale Caddy to 0: `kubectl scale deployment/caddy -n irl --replicas=0`
2. Update Traefik values: entrypoints to 80/443
3. `helm upgrade traefik` -- rebinds to production ports
4. Verify all services on 80/443

### Phase 4: Cleanup (no downtime)

1. Delete Caddy Helm release (`helm uninstall caddy -n irl`)
2. Delete `caddy-config` ConfigMap, `caddy-data-pvc` PVC, `caddy-cloudflare-token` secret
3. Remove from `irl_services`: `caddy_proxy` flag, legacy `port` fields, `health_path` (keep `subdomain`, `internal`, `cluster_svc`, `cluster_port` -- still used by standalone IngressRoute templates and DNS generation)
4. Delete `ansible/templates/Caddyfile.j2`
5. Delete `docker/caddy/Dockerfile`
6. Remove Caddy build/deploy tasks from `helm-deploy.yml`
7. Remove `irl_caddy_*` vars from `group_vars/all/main.yml`
8. Update comments referencing Caddy throughout the repo
9. Consider removing `--disable traefik` from k3s flags (cosmetic; k3s bundled Traefik won't conflict with the separately-deployed one if left disabled)

### Rollback

Scale Traefik to 0, scale Caddy to 1. Caddy's ConfigMap and PVC are untouched until Phase 4. Rollback time: ~10 seconds.

## File Changes Summary

### New

- `ansible/helm/traefik/values.yaml` -- Traefik Helm values
- `ansible/templates/ingressroute-*.yaml.j2` -- Standalone IngressRoute manifests for Vault, Authentik, Homepage, Vaultwarden, Nextcloud
- `helm-charts/charts/irl-gitea/templates/ingressroute.yaml` -- Gitea HTTP IngressRoute
- `helm-charts/charts/irl-gitea/templates/ingressroutetcp.yaml` -- Gitea SSH IngressRouteTCP
- `helm-charts/charts/irl-monitoring/templates/ingressroute-grafana.yaml`
- `helm-charts/charts/irl-monitoring/templates/ingressroute-prometheus.yaml`
- `helm-charts/charts/irl-monitoring/templates/ingressroute-alertmanager.yaml`
- `helm-charts/charts/irl-garage/templates/ingressroute.yaml`
- `helm-charts/charts/irl-openviking/templates/ingressroute.yaml`

### Modified

- `ansible/playbooks/helm-deploy.yml` -- Add Traefik section, remove Caddy section
- `ansible/inventory/group_vars/all/main.yml` -- Strip Caddy vars, clean up `irl_services`
- `scripts/bw-sync-config.yaml` -- Rename secret target to `traefik-cloudflare-token`
- `ansible/playbooks/k3s.yml` -- Optionally remove `--disable traefik`
- Each modified chart: bump `Chart.yaml` version
- `ansible/inventory/group_vars/homelab/main.yml` -- Add port 2222 to nftables if not already open

### Deleted

- `ansible/templates/Caddyfile.j2`
- `docker/caddy/Dockerfile`
- `helm-charts/charts/irl-caddy/` (entire directory)

## Risks

- **Cert issuance delay**: Let's Encrypt DNS-01 can take 1-2 minutes per cert. With 11 services, initial cert issuance could take 10-15 minutes. Phase 2 validation accounts for this.
- **Cloudflare token permissions**: The existing token was scoped for Caddy. Verify it has Zone:DNS:Edit for the `infiniteroomlabs.cloud` zone -- Traefik uses the same Cloudflare API, so the same permissions should work.
- **nftables**: Port 2222 for Gitea SSH may need to be opened in the host firewall. Check `nftables.conf.j2`.

## Out of Scope

- ExternalDNS integration (DNS stays Ansible-managed via `irl_services`)
- Authentik forward-auth middleware (can be added later as a Traefik Middleware CRD)
- Wildcard certificates (individual per-service certs for now)
- Removing `--disable traefik` from k3s install (cosmetic, low priority)
