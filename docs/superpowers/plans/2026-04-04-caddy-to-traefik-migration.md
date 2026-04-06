# Caddy-to-Traefik Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Caddy reverse proxy with Traefik, enabling Kubernetes-native routing via IngressRoute CRDs and native TCP proxying for Gitea SSH.

**Architecture:** Deploy the upstream `traefik/traefik` Helm chart via Ansible with `hostNetwork: true`. Each service gets an IngressRoute (in its Helm chart) or standalone Ansible-managed IngressRoute manifest. TLS via Let's Encrypt DNS-01 with Cloudflare. Big-bang cutover after pre-validation on temporary ports.

**Tech Stack:** Traefik v3, Helm, Ansible (kubernetes.core), IngressRoute CRDs, Let's Encrypt, Cloudflare DNS-01

**Design spec:** `docs/superpowers/specs/2026-04-04-caddy-to-traefik-migration-design.md`

---

## File Structure

### New Files
| File | Purpose |
|------|---------|
| `ansible/helm/traefik/values.yaml` | Traefik Helm values (entrypoints, TLS, hostNetwork, monitoring) |
| `ansible/templates/ingressroute-standalone.yaml.j2` | Single Jinja2 template for all standalone IngressRoutes (loops over services) |
| `ansible/templates/middleware-redirect-https.yaml.j2` | Global HTTP-to-HTTPS redirect middleware |
| `helm-charts/charts/irl-gitea/templates/ingressroute.yaml` | Gitea HTTP IngressRoute |
| `helm-charts/charts/irl-gitea/templates/ingressroutetcp.yaml` | Gitea SSH IngressRouteTCP |
| `helm-charts/charts/irl-monitoring/templates/ingressroute-grafana.yaml` | Grafana IngressRoute |
| `helm-charts/charts/irl-monitoring/templates/ingressroute-prometheus.yaml` | Prometheus IngressRoute |
| `helm-charts/charts/irl-monitoring/templates/ingressroute-alertmanager.yaml` | Alertmanager IngressRoute |
| `helm-charts/charts/irl-garage/templates/ingressroute.yaml` | Garage Web UI IngressRoute |
| `helm-charts/charts/irl-openviking/templates/ingressroute.yaml` | OpenViking IngressRoute |

### Modified Files
| File | Change |
|------|--------|
| `ansible/playbooks/helm-deploy.yml` | Add Traefik section (Phase 2.5), remove Caddy section |
| `ansible/inventory/group_vars/all/main.yml` | Remove `irl_caddy_*` vars, add `irl_traefik_*` vars, strip Caddy fields from `irl_services` |
| `ansible/inventory/group_vars/homelab/main.yml` | Add port 2222 to `irl_firewall_allowed_tcp_ports`, update comments |
| `ansible/templates/nftables.conf.j2` | Update output chain: rename Caddy rules to Traefik, add port 80 outbound for HTTP-01 fallback |
| `scripts/bw-sync-config.yaml` | Rename secret from `caddy-cloudflare-token` to `traefik-cloudflare-token` |
| `helm-charts/charts/irl-gitea/Chart.yaml` | Bump version 0.1.0 -> 0.2.0 |
| `helm-charts/charts/irl-gitea/values.yaml` | Add `ingress` values block |
| `helm-charts/charts/irl-monitoring/Chart.yaml` | Bump version 0.1.0 -> 0.2.0 |
| `helm-charts/charts/irl-monitoring/values.yaml` | Add `ingress` values block |
| `helm-charts/charts/irl-garage/Chart.yaml` | Bump version 0.1.0 -> 0.2.0 |
| `helm-charts/charts/irl-garage/values.yaml` | Add `ingress` values block |
| `helm-charts/charts/irl-openviking/Chart.yaml` | Bump version 0.4.0 -> 0.5.0 |
| `helm-charts/charts/irl-openviking/values.yaml` | Add `ingress` values block |

### Deleted Files
| File | Reason |
|------|--------|
| `ansible/templates/Caddyfile.j2` | No longer needed |
| `docker/caddy/Dockerfile` | No custom image needed for Traefik |
| `helm-charts/charts/irl-caddy/` | Entire chart directory |

---

## Task 1: Update bw-sync-config.yaml for Traefik secret

**Files:**
- Modify: `scripts/bw-sync-config.yaml:128-132`

This task renames the Kubernetes secret target so the Cloudflare API token gets synced to `traefik-cloudflare-token` instead of `caddy-cloudflare-token`. The Bitwarden item name stays the same.

- [ ] **Step 1: Update the secret mapping**

In `scripts/bw-sync-config.yaml`, change lines 128-132 from:

```yaml
  # ── Caddy (in-cluster reverse proxy) ──────────────────────────
  - bw_item: "cloudflare-caddy-dns01-token"
    ansible_var: "vault_cloudflare_caddy_dns01_token"
    k8s_secret: "caddy-cloudflare-token"
    k8s_key: "api-token"
```

to:

```yaml
  # ── Traefik (in-cluster reverse proxy) ────────────────────────
  - bw_item: "cloudflare-caddy-dns01-token"
    ansible_var: "vault_cloudflare_traefik_dns01_token"
    k8s_secret: "traefik-cloudflare-token"
    k8s_key: "api-token"
```

- [ ] **Step 2: Commit**

```bash
cd /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra
git add scripts/bw-sync-config.yaml
git commit -m "chore: rename Cloudflare DNS-01 secret target from Caddy to Traefik"
```

---

## Task 2: Add port 2222 to firewall and update nftables for Traefik

**Files:**
- Modify: `ansible/inventory/group_vars/homelab/main.yml`
- Modify: `ansible/templates/nftables.conf.j2`

- [ ] **Step 1: Add port 2222 to firewall allowed ports**

In `ansible/inventory/group_vars/homelab/main.yml`, change:

```yaml
# Firewall (nftables)
irl_firewall_allowed_tcp_ports:
  - 22     # SSH
  - 80     # HTTP (Caddy)
  - 443    # HTTPS (Caddy)
  - 6443   # k3s API server
  - 41641  # Tailscale direct connections
```

to:

```yaml
# Firewall (nftables)
irl_firewall_allowed_tcp_ports:
  - 22     # SSH
  - 80     # HTTP (Traefik)
  - 443    # HTTPS (Traefik)
  - 2222   # Gitea SSH (Traefik TCP)
  - 6443   # k3s API server
  - 41641  # Tailscale direct connections
```

- [ ] **Step 2: Update nftables output chain for Traefik**

In `ansible/templates/nftables.conf.j2`, replace the entire output chain (lines 57-77):

```nft
    chain output {
        type filter hook output priority filter; policy accept;

        # Compensating controls for Caddy hostNetwork pod (UID 1000).
        # hostNetwork pods bypass k8s NetworkPolicy, so we restrict
        # outbound at the nftables level.
        #
        # Allow Caddy -> k8s ClusterIP CIDR (upstream services)
        meta skuid 1000 ip daddr 10.43.0.0/16 accept
        # Allow Caddy -> pod CIDR (for direct pod routing)
        meta skuid 1000 ip daddr 10.42.0.0/16 accept
        # Allow Caddy -> DNS (cluster DNS + public resolvers for ACME)
        meta skuid 1000 udp dport 53 accept
        meta skuid 1000 tcp dport 53 accept
        # Allow Caddy -> HTTPS (Cloudflare API + LE ACME servers)
        meta skuid 1000 tcp dport 443 accept
        # Allow Caddy -> loopback (admin API health probes)
        meta skuid 1000 oif "lo" accept
        # Drop all other outbound from Caddy
        meta skuid 1000 log prefix "caddy-blocked: " level info drop
    }
```

with:

```nft
    chain output {
        type filter hook output priority filter; policy accept;

        # Compensating controls for Traefik hostNetwork pod (UID 65532).
        # hostNetwork pods bypass k8s NetworkPolicy, so we restrict
        # outbound at the nftables level.
        # Note: Traefik's stock image runs as UID 65532 (nonroot).
        #
        # Allow Traefik -> k8s ClusterIP CIDR (upstream services)
        meta skuid 65532 ip daddr 10.43.0.0/16 accept
        # Allow Traefik -> pod CIDR (for direct pod routing)
        meta skuid 65532 ip daddr 10.42.0.0/16 accept
        # Allow Traefik -> DNS (cluster DNS + public resolvers for ACME)
        meta skuid 65532 udp dport 53 accept
        meta skuid 65532 tcp dport 53 accept
        # Allow Traefik -> HTTPS (Cloudflare API + LE ACME servers)
        meta skuid 65532 tcp dport 443 accept
        # Allow Traefik -> HTTP (LE HTTP-01 fallback, cert status checks)
        meta skuid 65532 tcp dport 80 accept
        # Allow Traefik -> loopback (health probes, metrics)
        meta skuid 65532 oif "lo" accept
        # Drop all other outbound from Traefik
        meta skuid 65532 log prefix "traefik-blocked: " level info drop
    }
```

**Important:** The UID 65532 comes from Traefik's official Docker image which runs as the `nonroot` user. Verify this after deployment with `kubectl exec -n irl <traefik-pod> -- id`. If it differs, update the nftables template accordingly.

- [ ] **Step 3: Commit**

```bash
cd /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra
git add ansible/inventory/group_vars/homelab/main.yml ansible/templates/nftables.conf.j2
git commit -m "feat: update firewall for Traefik (port 2222, UID 65532 output rules)"
```

---

## Task 3: Create Traefik Helm values

**Files:**
- Create: `ansible/helm/traefik/values.yaml`

This is the core Traefik configuration. It uses temporary ports (8080/8443) during pre-validation, then gets updated to production ports (80/443) at cutover time.

- [ ] **Step 1: Create the values directory**

```bash
mkdir -p /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra/ansible/helm/traefik
```

- [ ] **Step 2: Create the Traefik values file**

Create `ansible/helm/traefik/values.yaml`:

```yaml
# ansible/helm/traefik/values.yaml
# =================================
# Traefik reverse proxy with Let's Encrypt DNS-01 via Cloudflare.
# Deployed via upstream traefik/traefik chart.
#
# During initial deployment, web/websecure use temporary ports (8080/8443)
# to allow pre-validation while Caddy still serves production traffic.
# After validation, update to ports 80/443 and re-deploy.

# -- hostNetwork binds entrypoint ports directly on the node
hostNetwork: true
dnsPolicy: ClusterFirstWithHostNet

# -- Entrypoints (listeners)
ports:
  web:
    port: 8080
    exposedPort: 80
    protocol: TCP
  websecure:
    port: 8443
    exposedPort: 443
    protocol: TCP
    tls:
      enabled: true
      certResolver: letsencrypt
      domains:
        - main: "lab.infiniteroomlabs.cloud"
          sans:
            - "*.lab.infiniteroomlabs.cloud"
            - "*.internal.lab.infiniteroomlabs.cloud"
  gitssh:
    port: 2222
    exposedPort: 2222
    protocol: TCP

# -- ACME / Let's Encrypt certificate resolver
certResolvers:
  letsencrypt:
    email: admin@infiniteroomlabs.cloud
    caServer: https://acme-v02.api.letsencrypt.org/directory
    dnsChallenge:
      provider: cloudflare
      resolvers:
        - "1.1.1.1:53"
    storage: /data/acme.json

# -- Cloudflare API token from Kubernetes secret
env:
  - name: CF_DNS_API_TOKEN
    valueFrom:
      secretKeyRef:
        name: traefik-cloudflare-token
        key: api-token

# -- Persistence for ACME cert storage
persistence:
  enabled: true
  name: traefik-data
  size: 1Gi
  storageClass: local-path
  path: /data

# -- Enable Traefik CRDs (IngressRoute, Middleware, etc.)
ingressRoute:
  dashboard:
    enabled: false  # We don't expose the Traefik dashboard

# -- Prometheus metrics
metrics:
  prometheus:
    entryPoint: metrics
    addEntryPointsLabels: true
    addRoutersLabels: true
    addServicesLabels: true

# -- Service for Prometheus scraping
service:
  enabled: true
  type: ClusterIP

# -- ServiceMonitor for kube-prometheus-stack
serviceMonitor:
  enabled: true
  additionalLabels:
    release: monitoring

# -- Resource limits
resources:
  requests:
    memory: "64Mi"
    cpu: "50m"
  limits:
    memory: "256Mi"
    cpu: "500m"

# -- Node scheduling
nodeSelector:
  irl.dev/tier: data

# -- Security context (Traefik image runs as UID 65532)
securityContext:
  capabilities:
    add:
      - NET_BIND_SERVICE
    drop:
      - ALL
  readOnlyRootFilesystem: true
  runAsNonRoot: true

# -- Single replica (single-node homelab)
replicas: 1

# -- Deployment strategy
updateStrategy:
  type: Recreate

# -- Logging
logs:
  general:
    level: INFO
    format: json
  access:
    enabled: true
    format: json
```

- [ ] **Step 3: Commit**

```bash
cd /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra
git add ansible/helm/traefik/values.yaml
git commit -m "feat: add Traefik Helm values with DNS-01 and hostNetwork"
```

---

## Task 4: Add IngressRoute templates to irl-gitea chart

**Files:**
- Create: `helm-charts/charts/irl-gitea/templates/ingressroute.yaml`
- Create: `helm-charts/charts/irl-gitea/templates/ingressroutetcp.yaml`
- Modify: `helm-charts/charts/irl-gitea/values.yaml`
- Modify: `helm-charts/charts/irl-gitea/Chart.yaml`

- [ ] **Step 1: Add ingress values to values.yaml**

Append to `helm-charts/charts/irl-gitea/values.yaml` after line 77:

```yaml

# Traefik IngressRoute
ingress:
  enabled: true
  host: "git.lab.infiniteroomlabs.cloud"
  # Gitea SSH via Traefik TCP routing
  ssh:
    enabled: true
    port: 22
```

- [ ] **Step 2: Create the HTTP IngressRoute template**

Create `helm-charts/charts/irl-gitea/templates/ingressroute.yaml`:

```yaml
{{- if .Values.ingress.enabled }}
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: {{ .Release.Name }}-http
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "irl-gitea.labels" . | nindent 4 }}
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`{{ .Values.ingress.host }}`)
      kind: Rule
      services:
        - name: {{ .Release.Name }}-http
          port: 3000
  tls:
    certResolver: letsencrypt
    domains:
      - main: {{ .Values.ingress.host }}
{{- end }}
```

- [ ] **Step 3: Create the SSH IngressRouteTCP template**

Create `helm-charts/charts/irl-gitea/templates/ingressroutetcp.yaml`:

```yaml
{{- if and .Values.ingress.enabled .Values.ingress.ssh.enabled }}
apiVersion: traefik.io/v1alpha1
kind: IngressRouteTCP
metadata:
  name: {{ .Release.Name }}-ssh
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "irl-gitea.labels" . | nindent 4 }}
spec:
  entryPoints:
    - gitssh
  routes:
    - match: HostSNI(`*`)
      services:
        - name: {{ .Release.Name }}-ssh
          port: {{ .Values.ingress.ssh.port }}
{{- end }}
```

- [ ] **Step 4: Bump chart version**

In `helm-charts/charts/irl-gitea/Chart.yaml`, change line 6:

```yaml
version: 0.1.0
```

to:

```yaml
version: 0.2.0
```

- [ ] **Step 5: Commit (in helm-charts submodule)**

```bash
cd /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra/helm-charts
git add charts/irl-gitea/
git commit -m "feat(irl-gitea): add Traefik IngressRoute and IngressRouteTCP for HTTP + SSH"
```

---

## Task 5: Add IngressRoute templates to irl-monitoring chart

**Files:**
- Create: `helm-charts/charts/irl-monitoring/templates/ingressroute-grafana.yaml`
- Create: `helm-charts/charts/irl-monitoring/templates/ingressroute-prometheus.yaml`
- Create: `helm-charts/charts/irl-monitoring/templates/ingressroute-alertmanager.yaml`
- Modify: `helm-charts/charts/irl-monitoring/values.yaml`
- Modify: `helm-charts/charts/irl-monitoring/Chart.yaml`

- [ ] **Step 1: Add ingress values to values.yaml**

Append to `helm-charts/charts/irl-monitoring/values.yaml` (after the loki section, at the end of the file):

```yaml

# Traefik IngressRoutes for monitoring services
ingress:
  grafana:
    enabled: true
    host: "grafana.lab.infiniteroomlabs.cloud"
    serviceName: "monitoring-grafana"
    servicePort: 80
  prometheus:
    enabled: true
    host: "metrics.internal.lab.infiniteroomlabs.cloud"
    serviceName: "monitoring-kube-prometheus-prometheus"
    servicePort: 9090
  alertmanager:
    enabled: true
    host: "alerts.internal.lab.infiniteroomlabs.cloud"
    serviceName: "monitoring-kube-prometheus-alertmanager"
    servicePort: 9093
```

- [ ] **Step 2: Create Grafana IngressRoute**

Create `helm-charts/charts/irl-monitoring/templates/ingressroute-grafana.yaml`:

```yaml
{{- if .Values.ingress.grafana.enabled }}
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: {{ .Release.Name }}-grafana
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "irl-monitoring.labels" . | nindent 4 }}
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`{{ .Values.ingress.grafana.host }}`)
      kind: Rule
      services:
        - name: {{ .Values.ingress.grafana.serviceName }}
          port: {{ .Values.ingress.grafana.servicePort }}
  tls:
    certResolver: letsencrypt
    domains:
      - main: {{ .Values.ingress.grafana.host }}
{{- end }}
```

- [ ] **Step 3: Create Prometheus IngressRoute**

Create `helm-charts/charts/irl-monitoring/templates/ingressroute-prometheus.yaml`:

```yaml
{{- if .Values.ingress.prometheus.enabled }}
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: {{ .Release.Name }}-prometheus
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "irl-monitoring.labels" . | nindent 4 }}
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`{{ .Values.ingress.prometheus.host }}`)
      kind: Rule
      services:
        - name: {{ .Values.ingress.prometheus.serviceName }}
          port: {{ .Values.ingress.prometheus.servicePort }}
  tls:
    certResolver: letsencrypt
    domains:
      - main: {{ .Values.ingress.prometheus.host }}
{{- end }}
```

- [ ] **Step 4: Create Alertmanager IngressRoute**

Create `helm-charts/charts/irl-monitoring/templates/ingressroute-alertmanager.yaml`:

```yaml
{{- if .Values.ingress.alertmanager.enabled }}
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: {{ .Release.Name }}-alertmanager
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "irl-monitoring.labels" . | nindent 4 }}
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`{{ .Values.ingress.alertmanager.host }}`)
      kind: Rule
      services:
        - name: {{ .Values.ingress.alertmanager.serviceName }}
          port: {{ .Values.ingress.alertmanager.servicePort }}
  tls:
    certResolver: letsencrypt
    domains:
      - main: {{ .Values.ingress.alertmanager.host }}
{{- end }}
```

- [ ] **Step 5: Bump chart version**

In `helm-charts/charts/irl-monitoring/Chart.yaml`, change line 6:

```yaml
version: 0.1.0
```

to:

```yaml
version: 0.2.0
```

- [ ] **Step 6: Commit (in helm-charts submodule)**

```bash
cd /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra/helm-charts
git add charts/irl-monitoring/
git commit -m "feat(irl-monitoring): add Traefik IngressRoutes for Grafana, Prometheus, Alertmanager"
```

---

## Task 6: Add IngressRoute templates to irl-garage and irl-openviking charts

**Files:**
- Create: `helm-charts/charts/irl-garage/templates/ingressroute.yaml`
- Modify: `helm-charts/charts/irl-garage/values.yaml`
- Modify: `helm-charts/charts/irl-garage/Chart.yaml`
- Create: `helm-charts/charts/irl-openviking/templates/ingressroute.yaml`
- Modify: `helm-charts/charts/irl-openviking/values.yaml`
- Modify: `helm-charts/charts/irl-openviking/Chart.yaml`

- [ ] **Step 1: Add ingress values to irl-garage values.yaml**

Append to `helm-charts/charts/irl-garage/values.yaml` after line 98:

```yaml

# Traefik IngressRoute (Web UI only; S3 API stays ClusterIP-only)
ingress:
  enabled: true
  host: "storage.internal.lab.infiniteroomlabs.cloud"
  serviceName: "garage-webui"
  servicePort: 3909
```

- [ ] **Step 2: Create irl-garage IngressRoute**

Create `helm-charts/charts/irl-garage/templates/ingressroute.yaml`:

```yaml
{{- if .Values.ingress.enabled }}
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: {{ .Release.Name }}-webui
  namespace: {{ .Release.Namespace }}
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
{{- end }}
```

- [ ] **Step 3: Bump irl-garage chart version**

In `helm-charts/charts/irl-garage/Chart.yaml`, change line 5:

```yaml
version: 0.1.0
```

to:

```yaml
version: 0.2.0
```

- [ ] **Step 4: Add ingress values to irl-openviking values.yaml**

Append to `helm-charts/charts/irl-openviking/values.yaml` after line 101:

```yaml

# Traefik IngressRoute
ingress:
  enabled: true
  host: "context.internal.lab.infiniteroomlabs.cloud"
  serviceName: "openviking"
  servicePort: 1933
```

- [ ] **Step 5: Create irl-openviking IngressRoute**

Create `helm-charts/charts/irl-openviking/templates/ingressroute.yaml`:

```yaml
{{- if .Values.ingress.enabled }}
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
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
{{- end }}
```

- [ ] **Step 6: Bump irl-openviking chart version**

In `helm-charts/charts/irl-openviking/Chart.yaml`, change line 5:

```yaml
version: 0.4.0
```

to:

```yaml
version: 0.5.0
```

- [ ] **Step 7: Commit (in helm-charts submodule)**

```bash
cd /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra/helm-charts
git add charts/irl-garage/ charts/irl-openviking/
git commit -m "feat(irl-garage, irl-openviking): add Traefik IngressRoutes"
```

- [ ] **Step 8: Update submodule pointer in infra repo**

```bash
cd /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra
git add helm-charts
git commit -m "chore: update helm-charts submodule (Traefik IngressRoutes)"
```

---

## Task 7: Create standalone IngressRoute templates and HTTPS redirect middleware

**Files:**
- Create: `ansible/templates/ingressroute-standalone.yaml.j2`
- Create: `ansible/templates/middleware-redirect-https.yaml.j2`

These Jinja2 templates handle services that don't have IRL-owned Helm chart wrappers: Authentik, Vault, Homepage, Vaultwarden, and Nextcloud. Rather than creating 5 separate template files, we use a single template that takes the service details as variables.

- [ ] **Step 1: Create the standalone IngressRoute template**

Create `ansible/templates/ingressroute-standalone.yaml.j2`:

```yaml
# {{ ansible_managed }}
# Standalone IngressRoute for {{ svc_name }}
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: {{ svc_name }}
  namespace: {{ irl_k8s_namespace }}
  labels:
    app.kubernetes.io/name: {{ svc_name }}
    app.kubernetes.io/managed-by: ansible
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`{{ svc_subdomain }}.{{ svc_domain }}`)
      kind: Rule
      services:
        - name: {{ svc_cluster_svc }}
          port: {{ svc_cluster_port }}
  tls:
    certResolver: letsencrypt
    domains:
      - main: {{ svc_subdomain }}.{{ svc_domain }}
```

- [ ] **Step 2: Create the HTTPS redirect middleware template**

Create `ansible/templates/middleware-redirect-https.yaml.j2`:

```yaml
# {{ ansible_managed }}
# Global HTTP-to-HTTPS redirect middleware
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: redirect-to-https
  namespace: {{ irl_k8s_namespace }}
spec:
  redirectScheme:
    scheme: https
    permanent: true
```

- [ ] **Step 3: Commit**

```bash
cd /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra
git add ansible/templates/ingressroute-standalone.yaml.j2 ansible/templates/middleware-redirect-https.yaml.j2
git commit -m "feat: add Ansible templates for standalone IngressRoutes and HTTPS redirect"
```

---

## Task 8: Update group_vars for Traefik

**Files:**
- Modify: `ansible/inventory/group_vars/all/main.yml`

- [ ] **Step 1: Replace Caddy vars with Traefik vars**

In `ansible/inventory/group_vars/all/main.yml`, replace lines 11-13:

```yaml
# Single-node k3s. Traefik disabled -- Caddy (bare-metal) handles ingress.
# Services exposed as NodePorts; Caddy proxies localhost:{nodePort}.
irl_k3s_namespace: "irl"
```

with:

```yaml
# Single-node k3s. Traefik deployed via Helm (hostNetwork, LE DNS-01).
# Services use ClusterIP; Traefik routes via IngressRoute CRDs.
irl_k3s_namespace: "irl"
```

- [ ] **Step 2: Replace the Caddy config section with Traefik config**

Replace lines 159-163:

```yaml
# ── Caddy (in-cluster) ──────────────────────────────────────────
irl_caddy_le_email: "admin@infiniteroomlabs.cloud"
irl_caddy_le_staging: false          # true for staging, false for production LE certs
irl_caddy_image: "irl-caddy:2.11.2-custom"
irl_k8s_namespace: "irl"
```

with:

```yaml
# ── Traefik (in-cluster reverse proxy) ──────────────────────────
irl_traefik_le_email: "admin@infiniteroomlabs.cloud"
# Services that need standalone IngressRoutes (no IRL-owned chart).
# Services with their own irl-* chart define IngressRoutes in the chart.
irl_traefik_standalone_services:
  authentik:
    subdomain: "auth"
    domain: "{{ irl_public_domain }}"
    cluster_svc: "authentik-server"
    cluster_port: 80
  vault:
    subdomain: "vault"
    domain: "{{ irl_public_domain }}"
    cluster_svc: "vault"
    cluster_port: 8200
  homepage:
    subdomain: "home"
    domain: "{{ irl_public_domain }}"
    cluster_svc: "homepage"
    cluster_port: 3000
  vaultwarden:
    subdomain: "passwords"
    domain: "{{ irl_public_domain }}"
    cluster_svc: "vaultwarden"
    cluster_port: 80
  nextcloud:
    subdomain: "cloud"
    domain: "{{ irl_public_domain }}"
    cluster_svc: "nextcloud"
    cluster_port: 8080
```

- [ ] **Step 3: Clean up irl_services -- remove Caddy-specific fields**

In `ansible/inventory/group_vars/all/main.yml`, update the `irl_services` dict header comment (line 54) from:

```yaml
# ── Service subdomains (used in Caddyfile + DNS records) ─────────────
# Service dictionary. Caddy proxies each service via either ClusterIP DNS name
# (cluster_svc + cluster_port) or NodePort fallback (port). During migration,
# services without cluster_svc still use localhost:{nodePort}.
```

to:

```yaml
# ── Service subdomains (used in DNS records) ─────────────────────────
# Service dictionary. Used by CoreDNS zone template for DNS record generation.
# Routing is handled by Traefik IngressRoutes (in Helm charts or Ansible).
```

Then for each service entry, remove: `port` (legacy NodePort), `health_path`, and `caddy_proxy` fields. Keep: `subdomain`, `internal`, `cluster_svc`, `cluster_port`.

The cleaned-up `irl_services` dict should look like:

```yaml
irl_services:
  gitea:
    subdomain: "git"
    internal: false
    cluster_svc: "gitea-http"
    cluster_port: 3000
  authentik:
    subdomain: "auth"
    internal: false
    cluster_svc: "authentik-server"
    cluster_port: 80
  grafana:
    subdomain: "grafana"
    internal: false
    cluster_svc: "monitoring-grafana"
    cluster_port: 80
  vault:
    subdomain: "vault"
    internal: false
    cluster_svc: "vault"
    cluster_port: 8200
  prometheus:
    subdomain: "metrics"
    internal: true
    cluster_svc: "monitoring-kube-prometheus-prometheus"
    cluster_port: 9090
  alertmanager:
    subdomain: "alerts"
    internal: true
    cluster_svc: "monitoring-kube-prometheus-alertmanager"
    cluster_port: 9093
  garage:
    subdomain: "storage"
    internal: true
    cluster_svc: "garage-webui"
    cluster_port: 3909
  garage-s3:
    subdomain: "s3"
    internal: true
    cluster_only: true  # No external routing, cluster-internal only
  homepage:
    subdomain: "home"
    internal: false
    cluster_svc: "homepage"
    cluster_port: 3000
  vaultwarden:
    subdomain: "passwords"
    internal: false
    cluster_svc: "vaultwarden"
    cluster_port: 80
  openviking:
    subdomain: "context"
    internal: true
    cluster_svc: "openviking"
    cluster_port: 1933
  nextcloud:
    subdomain: "cloud"
    internal: false
    cluster_svc: "nextcloud"
    cluster_port: 8080
```

- [ ] **Step 4: Commit**

```bash
cd /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra
git add ansible/inventory/group_vars/all/main.yml
git commit -m "refactor: replace Caddy vars with Traefik config, clean irl_services dict"
```

---

## Task 9: Update helm-deploy.yml -- replace Caddy with Traefik

**Files:**
- Modify: `ansible/playbooks/helm-deploy.yml:50-65` (add Traefik repo)
- Modify: `ansible/playbooks/helm-deploy.yml:410-533` (replace Caddy section with Traefik)

This is the largest task. It replaces the entire Caddy deployment section with Traefik deployment, including standalone IngressRoutes.

- [ ] **Step 1: Add Traefik to the Helm repo list**

In `ansible/playbooks/helm-deploy.yml`, add to the `loop` in the "Add Helm repositories" task (after line 64):

```yaml
        - { name: traefik, url: "https://traefik.github.io/charts" }
```

- [ ] **Step 2: Replace the entire Caddy section (lines 410-533) with the Traefik section**

Delete everything from line 410 (`# Phase 2.5: Caddy Reverse Proxy`) through line 533 (`tags: [phase2, caddy]`), and replace with:

```yaml
    # ══════════════════════════════════════════════════════════════
    # Phase 2.5: Traefik Reverse Proxy (in-cluster, hostNetwork)
    # ══════════════════════════════════════════════════════════════

    - name: "Traefik: Deploy traefik chart"
      kubernetes.core.helm:
        name: traefik
        chart_ref: traefik/traefik
        release_namespace: "{{ k3s_namespace }}"
        create_namespace: false
        kubeconfig: "{{ kubeconfig }}"
        values_files:
          - "{{ playbook_dir }}/../../ansible/helm/traefik/values.yaml"
        wait: true
        timeout: "3m0s"
      tags: [phase2, traefik]

    - name: "Traefik: Wait for pod to be ready"
      ansible.builtin.command:
        cmd: >
          kubectl rollout status deployment/traefik
          -n {{ k3s_namespace }} --timeout=120s
          --kubeconfig {{ kubeconfig }}
      changed_when: false
      tags: [phase2, traefik]

    - name: "Traefik: Deploy HTTPS redirect middleware"
      kubernetes.core.k8s:
        state: present
        kubeconfig: "{{ kubeconfig }}"
        template: ../templates/middleware-redirect-https.yaml.j2
      tags: [phase2, traefik]

    - name: "Traefik: Deploy standalone IngressRoutes"
      kubernetes.core.k8s:
        state: present
        kubeconfig: "{{ kubeconfig }}"
        template: ../templates/ingressroute-standalone.yaml.j2
      vars:
        svc_name: "{{ item.key }}"
        svc_subdomain: "{{ item.value.subdomain }}"
        svc_domain: "{{ item.value.domain }}"
        svc_cluster_svc: "{{ item.value.cluster_svc }}"
        svc_cluster_port: "{{ item.value.cluster_port }}"
      loop: "{{ irl_traefik_standalone_services | dict2items }}"
      loop_control:
        label: "{{ item.key }}"
      tags: [phase2, traefik]
```

- [ ] **Step 3: Commit**

```bash
cd /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra
git add ansible/playbooks/helm-deploy.yml
git commit -m "feat: replace Caddy deployment with Traefik in helm-deploy.yml"
```

---

## Task 10: Pre-validation -- deploy Traefik on temporary ports

This task is executed on the live cluster. Caddy is still running on ports 80/443. Traefik starts on 8080/8443/2222.

- [ ] **Step 1: Sync the new Cloudflare secret to Kubernetes**

```bash
cd /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra
./scripts/bw-sync.sh --target k8s
```

Verify the secret exists:

```bash
kubectl get secret traefik-cloudflare-token -n irl --kubeconfig ~/.kube/homelab.yaml
```

Expected: secret listed (no error).

- [ ] **Step 2: Push helm-charts submodule changes**

```bash
cd /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra/helm-charts
git push origin main
```

- [ ] **Step 3: Run the Traefik deployment via Ansible**

```bash
cd /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra/ansible
uv run ansible-playbook playbooks/helm-deploy.yml --tags traefik
```

Expected: all tasks succeed, Traefik pod running.

- [ ] **Step 4: Upgrade IRL Helm charts with IngressRoutes**

```bash
cd /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra/ansible
uv run ansible-playbook playbooks/helm-deploy.yml --tags gitea
uv run ansible-playbook playbooks/helm-deploy.yml --tags monitoring
uv run ansible-playbook playbooks/helm-deploy.yml --tags garage
uv run ansible-playbook playbooks/helm-deploy.yml --tags openviking
```

- [ ] **Step 5: Verify IngressRoutes are registered**

```bash
kubectl get ingressroute -n irl --kubeconfig ~/.kube/homelab.yaml
kubectl get ingressroutetcp -n irl --kubeconfig ~/.kube/homelab.yaml
kubectl get middleware -n irl --kubeconfig ~/.kube/homelab.yaml
```

Expected: one IngressRoute per service, one IngressRouteTCP for Gitea SSH, one Middleware for HTTPS redirect.

- [ ] **Step 6: Wait for cert issuance (up to 15 minutes)**

```bash
kubectl logs deployment/traefik -n irl --kubeconfig ~/.kube/homelab.yaml | grep -i "acme\|certificate"
```

Watch for successful cert issuance messages. DNS-01 can take 1-2 minutes per cert.

- [ ] **Step 7: Test each service through Traefik on temporary ports**

```bash
# Gitea
curl -sk --resolve git.lab.infiniteroomlabs.cloud:8443:100.86.213.22 \
  https://git.lab.infiniteroomlabs.cloud:8443/api/v1/version

# Authentik
curl -sk --resolve auth.lab.infiniteroomlabs.cloud:8443:100.86.213.22 \
  https://auth.lab.infiniteroomlabs.cloud:8443/

# Grafana
curl -sk --resolve grafana.lab.infiniteroomlabs.cloud:8443:100.86.213.22 \
  https://grafana.lab.infiniteroomlabs.cloud:8443/api/health

# Vault
curl -sk --resolve vault.lab.infiniteroomlabs.cloud:8443:100.86.213.22 \
  https://vault.lab.infiniteroomlabs.cloud:8443/v1/sys/health

# Homepage
curl -sk --resolve home.lab.infiniteroomlabs.cloud:8443:100.86.213.22 \
  https://home.lab.infiniteroomlabs.cloud:8443/

# Vaultwarden
curl -sk --resolve passwords.lab.infiniteroomlabs.cloud:8443:100.86.213.22 \
  https://passwords.lab.infiniteroomlabs.cloud:8443/alive

# Nextcloud
curl -sk --resolve cloud.lab.infiniteroomlabs.cloud:8443:100.86.213.22 \
  https://cloud.lab.infiniteroomlabs.cloud:8443/status.php

# Prometheus
curl -sk --resolve metrics.internal.lab.infiniteroomlabs.cloud:8443:100.86.213.22 \
  https://metrics.internal.lab.infiniteroomlabs.cloud:8443/-/healthy

# Alertmanager
curl -sk --resolve alerts.internal.lab.infiniteroomlabs.cloud:8443:100.86.213.22 \
  https://alerts.internal.lab.infiniteroomlabs.cloud:8443/-/healthy

# Garage WebUI
curl -sk --resolve storage.internal.lab.infiniteroomlabs.cloud:8443:100.86.213.22 \
  https://storage.internal.lab.infiniteroomlabs.cloud:8443/

# OpenViking
curl -sk --resolve context.internal.lab.infiniteroomlabs.cloud:8443:100.86.213.22 \
  https://context.internal.lab.infiniteroomlabs.cloud:8443/

# Gitea SSH
ssh -T -p 2222 -o StrictHostKeyChecking=no git@100.86.213.22
```

Expected: all HTTP services return a successful response (200 or redirect). Gitea SSH returns a Gitea banner message.

**If any service fails:** Debug via `kubectl logs deployment/traefik -n irl` and `kubectl describe ingressroute <name> -n irl`. Fix before proceeding. Caddy is still serving production.

---

## Task 11: Cutover -- switch Traefik to production ports

- [ ] **Step 1: Scale Caddy to 0**

```bash
kubectl scale deployment/caddy -n irl --replicas=0 --kubeconfig ~/.kube/homelab.yaml
```

Verify: `kubectl get pods -n irl -l app.kubernetes.io/name=irl-caddy` shows no running pods.

- [ ] **Step 2: Update Traefik values to production ports**

In `ansible/helm/traefik/values.yaml`, change the `ports` section:

```yaml
ports:
  web:
    port: 8080
    exposedPort: 80
```

to:

```yaml
ports:
  web:
    port: 80
    exposedPort: 80
```

and:

```yaml
  websecure:
    port: 8443
    exposedPort: 443
```

to:

```yaml
  websecure:
    port: 443
    exposedPort: 443
```

- [ ] **Step 3: Apply the port change via Ansible**

```bash
cd /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra/ansible
uv run ansible-playbook playbooks/helm-deploy.yml --tags traefik
```

- [ ] **Step 4: Verify all services on production ports**

```bash
curl -sk https://git.lab.infiniteroomlabs.cloud/api/v1/version
curl -sk https://auth.lab.infiniteroomlabs.cloud/
curl -sk https://grafana.lab.infiniteroomlabs.cloud/api/health
curl -sk https://vault.lab.infiniteroomlabs.cloud/v1/sys/health
curl -sk https://home.lab.infiniteroomlabs.cloud/
curl -sk https://passwords.lab.infiniteroomlabs.cloud/alive
curl -sk https://cloud.lab.infiniteroomlabs.cloud/status.php
curl -sk https://metrics.internal.lab.infiniteroomlabs.cloud/-/healthy
curl -sk https://alerts.internal.lab.infiniteroomlabs.cloud/-/healthy
curl -sk https://storage.internal.lab.infiniteroomlabs.cloud/
curl -sk https://context.internal.lab.infiniteroomlabs.cloud/
```

Expected: all return successful responses.

- [ ] **Step 5: Test Gitea SSH without port-forward**

Update `~/.ssh/config` on the laptop. Change the Gitea SSH entry from `localhost:2222` (port-forward) to `100.86.213.22:2222` (direct Traefik TCP):

```
Host git.lab.infiniteroomlabs.cloud
  HostName 100.86.213.22
  Port 2222
  User git
```

Test:

```bash
ssh -T git@git.lab.infiniteroomlabs.cloud
```

Expected: Gitea banner message. No `kubectl port-forward` needed.

- [ ] **Step 6: Commit the production port values**

```bash
cd /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra
git add ansible/helm/traefik/values.yaml
git commit -m "feat: switch Traefik to production ports 80/443"
```

**Rollback if needed:** Scale Traefik to 0, scale Caddy to 1:

```bash
kubectl scale deployment/traefik -n irl --replicas=0 --kubeconfig ~/.kube/homelab.yaml
kubectl scale deployment/caddy -n irl --replicas=1 --kubeconfig ~/.kube/homelab.yaml
```

---

## Task 12: Cleanup -- remove Caddy

Only proceed after confirming all services work through Traefik on production ports.

- [ ] **Step 1: Delete Caddy Helm release**

```bash
helm uninstall caddy -n irl --kubeconfig ~/.kube/homelab.yaml
```

- [ ] **Step 2: Delete Caddy ConfigMap and PVC**

```bash
kubectl delete configmap caddy-config -n irl --kubeconfig ~/.kube/homelab.yaml
kubectl delete pvc caddy-data-pvc -n irl --kubeconfig ~/.kube/homelab.yaml
kubectl delete pv pv-caddy-data --kubeconfig ~/.kube/homelab.yaml
```

- [ ] **Step 3: Delete old Cloudflare secret**

```bash
kubectl delete secret caddy-cloudflare-token -n irl --kubeconfig ~/.kube/homelab.yaml
```

- [ ] **Step 4: Delete Caddy source files**

```bash
cd /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra
rm ansible/templates/Caddyfile.j2
rm docker/caddy/Dockerfile
rm -rf helm-charts/charts/irl-caddy/
```

- [ ] **Step 5: Remove fish shell aliases for gitea port-forward**

If `gitea-connect` / `gitea-disconnect` fish functions exist in `~/.config/fish/`, they are no longer needed since Gitea SSH is now routed through Traefik. Remove or archive them.

- [ ] **Step 6: Update k3s.yml install comment**

In `ansible/playbooks/k3s.yml`, change line 146:

```yaml
    - name: Install k3s (hardened, stock Flannel CNI, Caddy as ingress)
```

to:

```yaml
    - name: Install k3s (hardened, stock Flannel CNI, Traefik as ingress)
```

- [ ] **Step 7: Commit cleanup**

```bash
cd /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra
git add -A
git commit -m "chore: remove Caddy -- Traefik is now the ingress proxy

Remove Caddy Helm chart, Dockerfile, Caddyfile template, and
legacy NodePort/health_path fields from irl_services. Traefik
handles all HTTP and TCP routing via IngressRoute CRDs."
```

- [ ] **Step 8: Push helm-charts submodule (removal of irl-caddy)**

```bash
cd /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra/helm-charts
git add -A
git commit -m "chore: remove irl-caddy chart (replaced by Traefik)"
git push origin main
cd ..
git add helm-charts
git commit -m "chore: update helm-charts submodule (irl-caddy removed)"
```

---

## Task 13: Update documentation

**Files:**
- Modify: `CLAUDE.md` (repo root)
- Modify: `ansible/CLAUDE.md` (if it references Caddy)
- Modify: `CONTRIBUTING.md` (if it references Caddy)

- [ ] **Step 1: Update repo CLAUDE.md**

In the repo-root `CLAUDE.md`, update the "Repository Structure" table to replace references to Caddy with Traefik. Update the service table to show Traefik as the ingress proxy.

Search for all occurrences of "Caddy" and "caddy" in the file and update to describe Traefik.

- [ ] **Step 2: Grep for remaining Caddy references**

```bash
cd /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra
grep -ri "caddy" --include="*.md" --include="*.yml" --include="*.yaml" --include="*.j2" .
```

Update any remaining references that are not historical (git commit messages, changelogs are fine to leave).

- [ ] **Step 3: Commit documentation updates**

```bash
cd /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra
git add -A
git commit -m "docs: update all references from Caddy to Traefik"
```

---

## Task 14: Apply nftables and verify firewall

This task applies the updated firewall rules on the homelab server.

- [ ] **Step 1: Apply the nftables update via Ansible**

```bash
cd /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra/ansible
uv run ansible-playbook playbooks/security-hardening.yml --tags nftables
```

- [ ] **Step 2: Verify the Traefik UID on the running pod**

```bash
kubectl exec -n irl deployment/traefik --kubeconfig ~/.kube/homelab.yaml -- id
```

Expected: `uid=65532(nonroot)` or similar. If the UID differs, update `ansible/templates/nftables.conf.j2` with the correct UID and re-apply.

- [ ] **Step 3: Verify Traefik can still reach backends after nftables update**

```bash
curl -sk https://git.lab.infiniteroomlabs.cloud/api/v1/version
curl -sk https://grafana.lab.infiniteroomlabs.cloud/api/health
```

Expected: successful responses. If they fail, check `journalctl -k | grep traefik-blocked` on the homelab for dropped packets.

- [ ] **Step 4: Verify outbound is restricted**

```bash
# On the homelab server, check that Traefik can't reach arbitrary destinations
# (the nftables rules should drop non-allowed traffic and log it)
journalctl -k | grep traefik-blocked | tail -5
```

No output expected during normal operation (Traefik shouldn't be trying to reach anything unexpected).
