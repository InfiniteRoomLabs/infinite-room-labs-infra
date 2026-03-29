---
name: helm-deploy
description: Deploy or redeploy a homelab k3s service via the Ansible Helm playbook with post-deploy health checks
disable-model-invocation: true
---

# Helm Deploy

Deploy a service to the IRL homelab k3s cluster.

## Available Services

| Service | Tag | Phase | Notes |
|---------|-----|-------|-------|
| PostgreSQL | `postgres` | 2 | CNPG operator |
| Redis/Valkey | `redis` | 2 | |
| Vault | `vault` | 2 | May need unseal after restart |
| Gitea | `gitea` | 3 | |
| Authentik | `authentik` | 3 | |
| Monitoring | `monitoring` | 3 | Prometheus + Grafana |
| Loki | `loki` | 3 | Log aggregation |
| Vaultwarden | `vaultwarden` | 3 | Password manager (Bitwarden-compatible) |
| Caddy | `caddy` | - | Ingress proxy |
| CoreDNS | `coredns` | - | Internal split DNS |
| Homepage | `homepage` | - | Dashboard |
| Jenkins | `jenkins` | 4 | |
| Ollama | `ollama` | 5 | LLM inference |

## Workflow

1. Ask the user which service to deploy if not provided as an argument
2. Confirm the deployment target with the user before proceeding
3. Run the deployment:
   ```bash
   cd ansible && uv run ansible-playbook playbooks/helm-deploy.yml --tags <service>
   ```
4. Verify post-deploy health:
   ```bash
   kubectl get pods -n irl -l app.kubernetes.io/name=<service> --no-headers
   ```
5. If pods are not Ready within 60 seconds, check logs:
   ```bash
   kubectl logs -n irl -l app.kubernetes.io/name=<service> --tail=30
   ```
6. Report deployment status to the user

## Special Cases

- **Vault**: After a pod restart, Vault re-seals. Remind the user to unseal with 3 of 5 keys from Bitwarden (`IRL/Services/Vault`).
- **PostgreSQL**: Uses CNPG operator. Check cluster status with `kubectl get cluster -n irl`.
- **Full deploy**: Omit `--tags` to deploy all services in phase order. Confirm with the user first -- this is a large operation.

## Values Overrides

Environment-specific Helm values live in `ansible/helm/<service>/values.yaml`. Charts are sourced from the `helm-charts/` submodule or upstream repos.
