# Homelab Service Access Guide

Last updated: 2026-03-21

## Prerequisites

- **Tailscale** installed and connected to the IRL tailnet
- Homelab server is reachable at `100.86.213.22` (Tailscale IP)
- **kubectl** installed (`/usr/local/bin/kubectl`)
- **KUBECONFIG** set to `~/.kube/homelab.yaml` (done automatically in fish + bashrc)

No additional programs or DNS changes needed for direct access. All services are reachable via `http://100.86.213.22:{nodePort}` over Tailscale.

## Service Access Table

| Service | URL | Credentials |
|---------|-----|-------------|
| **Gitea** (git server) | http://100.86.213.22:30300 | Admin: `admin` / password in BW `IRL/Services/Gitea` |
| **Grafana** (dashboards) | http://100.86.213.22:30001 | Admin: `admin` / password in BW `IRL/Services/Grafana` |
| **Vault** (secrets mgmt) | http://100.86.213.22:30200 | Root token in BW `IRL/Services/Vault` |
| **Authentik** (SSO) | http://100.86.213.22:30080 | Bootstrap password in BW `IRL/Services/Authentik` |
| **Prometheus** (metrics) | http://100.86.213.22:30090 | No auth (internal) |
| **Alertmanager** (alerts) | http://100.86.213.22:30093 | No auth (internal) |
| **Plane** (project mgmt) | TBD -- deploying | First-run setup wizard |
| **Ollama** (LLM inference) | ClusterIP only | See kubectl access below |

## Accessing Ollama (ClusterIP-only)

Ollama is intentionally not exposed via NodePort. Access it via port-forward:

```bash
# Forward local port 11434 to Ollama
kubectl port-forward -n irl svc/ollama 11434:11434

# In another terminal, test it
curl http://localhost:11434/api/tags   # List available models
curl -X POST http://localhost:11434/api/generate -d '{"model":"llama3.2","prompt":"Hello"}'
```

Models available: `llama3.2`, `codellama`

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
export VAULT_ADDR='http://100.86.213.22:30200'
export VAULT_TOKEN='<root-token-from-bitwarden>'
vault status
vault secrets list
```

## Future: DNS + TLS Access

Once Caddy is configured on the server, services will be accessible via proper domains:

| Service | Domain | TLS |
|---------|--------|-----|
| Gitea | `git.lab.infiniteroomlabs.cloud` | Let's Encrypt |
| Grafana | `grafana.lab.infiniteroomlabs.cloud` | Let's Encrypt |
| Vault | `vault.lab.infiniteroomlabs.cloud` | Let's Encrypt |
| Authentik | `auth.lab.infiniteroomlabs.cloud` | Let's Encrypt |
| Prometheus | `metrics.internal.lab.infiniteroomlabs.cloud` | Internal CA |
| Alertmanager | `alerts.internal.lab.infiniteroomlabs.cloud` | Internal CA |

This requires:
1. Cloudflare DNS records (A records pointing to Tailscale IP or CNAME to tailnet hostname)
2. Caddy deployment playbook (`playbooks/caddy.yml`)
3. Caddyfile template is already in `ansible/templates/Caddyfile.j2`

## Troubleshooting

```bash
# Check all pods
kubectl get pods -n irl

# Check a specific service's logs
kubectl logs -n irl -l app.kubernetes.io/name=gitea --tail=50

# Check node resources
kubectl top nodes
kubectl top pods -n irl

# Vault re-seal after restart (need 3 of 5 unseal keys from BW)
kubectl exec -n irl vault-0 -- vault operator unseal <key>
```
