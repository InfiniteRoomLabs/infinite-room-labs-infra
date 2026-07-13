# Homelab Service Access Guide

Last updated: 2026-03-23

## Prerequisites

- **Tailscale** installed and connected to the IRL tailnet
- Homelab server (HP Z600) reachable at `100.86.213.22` (Tailscale IP)
- DigitalOcean agent node reachable at its Tailscale IP (s-4vcpu-8gb, NYC3)
- **kubectl** installed (`/usr/local/bin/kubectl`)
- **KUBECONFIG** set to `~/.kube/homelab.yaml` (done automatically in fish + bashrc)

DNS resolution is handled automatically via Tailscale Split DNS. CoreDNS runs on the homelab node (hostNetwork, port 53) and resolves `*.lab.infiniteroomlabs.cloud` and `*.internal.lab.infiniteroomlabs.cloud`. No `/etc/hosts` changes needed.

## Cluster Nodes

| Node | Location | Tailscale IP | Spec | Role |
|------|----------|--------------|------|------|
| HP Z600 (homelab) | On-prem | 100.86.213.22 | Dual Xeon, 48GB RAM, ZFS | k3s server, stateful workloads |
| DigitalOcean (do-agent) | NYC3 | Via Tailscale | 4 vCPU, 8GB RAM ($48/mo) | k3s agent |

## Service Access Table

All services are accessed via Caddy reverse proxy with internal TLS (Tailscale-only access). Public-facing services use `*.lab.infiniteroomlabs.cloud`, internal services use `*.internal.lab.infiniteroomlabs.cloud`.

| Service | URL | Node | Credentials |
|---------|-----|------|-------------|
| **Gitea** (git server) | https://git.lab.infiniteroomlabs.cloud | Homelab | Admin: `admin` / password in BW `IRL/Services/Gitea` |
| **Grafana** (dashboards) | https://grafana.lab.infiniteroomlabs.cloud | Homelab | Admin: `admin` / password in BW `IRL/Services/Grafana` |
| **Vault** (secrets mgmt) | https://vault.lab.infiniteroomlabs.cloud | Homelab | Root token in BW `IRL/Services/Vault` |
| **Authentik** (SSO) | https://auth.lab.infiniteroomlabs.cloud | Homelab | Bootstrap password in BW `IRL/Services/Authentik` |
| **Garage** (S3 storage) | https://garage.internal.lab.infiniteroomlabs.cloud | Homelab | Admin token in BW `IRL/Services/Garage` |
| **OpenViking** (agent memory/RAG) | https://openviking.internal.lab.infiniteroomlabs.cloud | Homelab | No auth (internal) |
| **Prometheus** (metrics) | https://metrics.internal.lab.infiniteroomlabs.cloud | Homelab | No auth (internal) |
| **Alertmanager** (alerts) | https://alerts.internal.lab.infiniteroomlabs.cloud | Homelab | No auth (internal) |
| **Karakeep** (bookmarks) | https://bookmarks.lab.infiniteroomlabs.cloud | Homelab | Single admin `wes@infiniteroomlabs.com`, password in BW `IRL/Services/Karakeep` (signups disabled) |
| **CoreDNS** (Split DNS) | N/A (hostNetwork port 53) | Homelab | No UI -- DNS resolver only |
| **Ollama** (LLM inference) | ClusterIP only | Homelab | See kubectl access below |

## Accessing Ollama (ClusterIP-only)

Ollama is intentionally not exposed via NodePort. Access it via port-forward:

```bash
# Forward local port 11434 to Ollama
kubectl port-forward -n irl svc/ollama 11434:11434

# In another terminal, test it
curl http://localhost:11434/api/tags   # List available models
curl -X POST http://localhost:11434/api/generate -d '{"model":"llama3.2","prompt":"Hello"}'
```

Models available: `llama3.2`, `codellama`, `nomic-embed-text`

## Gitea SSH Access

Gitea SSH is exposed on NodePort 30022:

```bash
# Add to ~/.ssh/config for convenient git operations:
Host gitea
    HostName 100.86.213.22
    Port 30022
    User git
```

Then clone repos with: `git clone gitea:org/repo.git`

## Vault CLI Access

```bash
export VAULT_ADDR='https://vault.lab.infiniteroomlabs.cloud'
export VAULT_TOKEN='<root-token-from-bitwarden>'
vault status
vault secrets list
```

## Garage S3 Access

Garage provides S3-compatible object storage. Data is ZFS-backed on the homelab node.

```bash
# Configure AWS CLI or s3cmd with Garage credentials from Bitwarden
aws configure --profile garage
# Endpoint: https://garage.internal.lab.infiniteroomlabs.cloud
# Access Key / Secret Key: from BW IRL/Services/Garage
```

## Troubleshooting

```bash
# Check all pods
kubectl get pods -n irl

# Check a specific service's logs
kubectl logs -n irl -l app.kubernetes.io/name=gitea --tail=50

# Check node resources
kubectl top nodes
kubectl top pods -n irl

# Check cross-node networking (flannel over Tailscale)
kubectl get nodes -o wide   # Verify both nodes are Ready
kubectl exec -n irl <pod-on-homelab> -- ping <pod-ip-on-do>

# Vault re-seal after restart (need 3 of 5 unseal keys from BW)
kubectl exec -n irl vault-0 -- vault operator unseal <key>

# Check Split DNS resolution
dig @100.86.213.22 git.lab.infiniteroomlabs.cloud
```
