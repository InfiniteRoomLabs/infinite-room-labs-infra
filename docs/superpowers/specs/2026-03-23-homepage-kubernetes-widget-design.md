# Homepage Kubernetes Widget Fix -- Design Spec

**Date**: 2026-03-23
**Status**: Approved
**Scope**: Fix broken Kubernetes widget on Homepage dashboard + add per-service pod stats

## Problem

The Homepage dashboard's Kubernetes widget displays `Error getting nodes: NaN undefined undefined` every ~3 seconds. The widget shows 0% CPU and 0 B memory. Three root causes were identified:

1. **Widget API URLs used external domains** -- the Homepage pod couldn't reach services via `https://*.lab.infiniteroomlabs.cloud` because port 443 isn't reachable from inside the cluster (Caddy terminates TLS on the host, not in-cluster). **Fixed in prior commit.**
2. **PostgreSQL used Docker integration** -- `server: main` / `container: postgresql` references Docker socket, which doesn't exist in k8s. **Fixed in prior commit.**
3. **Kubernetes API unreachable from pod** -- the `default-deny-all` NetworkPolicy in the `irl` namespace blocks all egress except intra-namespace and DNS. The Homepage pod cannot reach the Kubernetes API server at `10.43.0.1:443` (ClusterIP) or `100.86.213.22:6443` / `192.168.2.2:6443` (node endpoints). Confirmed via `wget` from inside the pod: `Connection refused`.

## Design

### 1. Fix NaN Error (Root Cause: NetworkPolicy)

The `irl` namespace has three NetworkPolicies:
- `default-deny-all` -- blocks all ingress and egress
- `allow-intra-namespace` -- allows pod-to-pod within `irl`
- `allow-dns-egress` -- allows UDP/TCP 53 for DNS resolution

The Kubernetes API server lives outside the `irl` namespace (it's a system service). Homepage's `@kubernetes/client-node` library calls `https://10.43.0.1:443` which kube-proxy routes to `100.86.213.22:6443`. Both are blocked by the deny-all policy.

**Fix**: Add a new NetworkPolicy `allow-homepage-kube-api` in `ansible/playbooks/k3s.yml` that allows the Homepage pod (matched by `app.kubernetes.io/name: homepage`) egress to:
- `10.43.0.1/32` on TCP 443 (ClusterIP)
- `192.168.2.2/32` on TCP 6443 (node LAN IP)
- `100.86.213.22/32` on TCP 6443 (node Tailscale IP)

This is scoped only to the Homepage pod -- no other pods get API access.

### 2. Pin Image Version

Change `tag: latest` to `tag: v1.2.0` (matching the deployed chart version `homepage-2.1.0`).

Rationale: Prevents future mystery breakage from upstream changes. Manual bumps until idea 087 (Container Image Lifecycle Operator) is implemented. Upgrading to a newer version (e.g., v1.11.0) is a separate task that should be evaluated once the widget is confirmed working.

### 3. Cluster + Node Widget Config

No changes needed. The existing config is correct:

```yaml
widgets:
  - kubernetes:
      cluster:
        show: true
        cpu: true
        memory: true
        showLabel: true
        label: "IRL Homelab"
      nodes:
        show: true
        cpu: true
        memory: true
        showLabel: true
```

Once the NetworkPolicy fix is applied, this displays:
- Aggregate CPU/memory bar across both nodes (labeled "IRL Homelab")
- Per-node CPU/memory bars for `home` and `do-k3s-agent-01`

### 4. Per-Service Pod Stats

Add `namespace: irl` and `app: <label>` to each service entry so Homepage shows inline pod CPU/memory.

Pod label mapping (verified via `kubectl get pods -n irl`):

| Service | Label Key | Label Value | Notes |
|---------|-----------|-------------|-------|
| PostgreSQL | `app.kubernetes.io/name` | `postgresql` | CNPG operator |
| Valkey | `app.kubernetes.io/name` | `valkey` | |
| Vault | `app.kubernetes.io/name` | `vault` | |
| Garage S3 | `app.kubernetes.io/name` | `garage` | |
| CoreDNS | `app.kubernetes.io/name` | `coredns` | |
| Gitea | `app.kubernetes.io/name` | `gitea` | |
| Authentik | `app.kubernetes.io/name` | `authentik` | Covers server + worker pods |
| Grafana | `app.kubernetes.io/name` | `grafana` | |
| Prometheus | `app.kubernetes.io/name` | `prometheus` | |
| Alertmanager | `app.kubernetes.io/name` | `alertmanager` | |
| Ollama | `app.kubernetes.io/name` | `ollama` | |
| OpenViking | `app.kubernetes.io/name` | `openviking` | |
| Plane | `app.name` | various | Non-standard labels; use `podSelector` |

Standard services use Homepage's `app` field (maps to `app.kubernetes.io/name`):

```yaml
- PostgreSQL:
    icon: postgres
    href: ""
    description: "CNPG operator -- 5 databases"
    namespace: irl
    app: postgresql
```

Plane uses non-standard `app.name` labels, so it needs `podSelector`:

```yaml
- Plane:
    icon: plane
    href: "https://plane.lab.infiniteroomlabs.cloud"
    description: "Project management (on DO node)"
    namespace: irl
    podSelector: "app.name in (irl-plane-api, irl-plane-web, irl-plane-admin, irl-plane-live, irl-plane-space, irl-plane-worker, irl-plane-beat-worker, irl-plane-rabbitmq)"
```

All 8 Plane pods are included for full visibility.

### 5. Widget API Keys (Out of Scope)

Gitea and Authentik widgets require API keys to display stats (notifications, issues, users, login events). This spec does not cover API key provisioning -- those widgets will show the service link but not stats until keys are configured in a follow-up.

## Changes Summary

| File | Change |
|------|--------|
| `ansible/playbooks/k3s.yml` | Add `allow-homepage-kube-api` NetworkPolicy |
| `ansible/helm/homepage/values.yaml` | Pin `image.tag` to `v1.2.0` |
| `ansible/helm/homepage/values.yaml` | Add `namespace: irl` + `app`/`podSelector` to all 13 service entries |

## Deployment

```bash
# 1. Apply the NetworkPolicy
cd ansible && uv run ansible-playbook playbooks/k3s.yml --tags k3s

# 2. Redeploy Homepage with updated values
cd ansible && uv run ansible-playbook playbooks/helm-deploy.yml --tags homepage
```

## Verification

1. NetworkPolicy exists: `kubectl get networkpolicy allow-homepage-kube-api -n irl`
2. Pod restarts cleanly: `kubectl get pods -n irl -l app.kubernetes.io/name=homepage`
3. API reachable from pod: `kubectl exec -n irl <pod> -- wget -q -O- --no-check-certificate https://10.43.0.1/version`
4. No `NaN undefined undefined` in pod logs: `kubectl logs -n irl <pod> --tail=20`
5. Cluster bar shows real CPU/memory percentages
6. Per-node bars show `home` and `do-k3s-agent-01` individually
7. Each service entry shows inline pod CPU/memory stats
8. Browse to `https://home.lab.infiniteroomlabs.cloud` and visually confirm
