# SOP: Deploy a New Service

## Prerequisites
- SSH access to homelab via Tailscale
- Ansible venv set up (`cd ansible && uv sync`)

## Steps

1. **Create Helm chart or values file**: If using an IRL chart, add to `helm-charts/charts/irl-{name}/`. If using an upstream chart, create `ansible/helm/{name}/values.yaml` with overrides.
2. **Add variables**: Add the service to `irl_services` in `inventory/group_vars/all/main.yml` with `subdomain`, `internal`, `health_path`, `cluster_svc`, and `cluster_port`.
3. **Add secrets**: Create in Bitwarden under `IRL/`, add mapping to `scripts/bw-sync-config.yaml`, run `bw-sync.sh --target both`.
4. **Add deploy tasks**: Add Helm deploy task to `playbooks/helm-deploy.yml` in the correct phase, tagged with the service name.
5. **Update Caddy**: The Caddyfile template auto-generates a block from `irl_services`. Re-run `--tags caddy` to update the ConfigMap.
6. **Add DNS record**: Add subdomain to CoreDNS zone file via `irl_services` (auto-generated). If using a new base domain, update `terraform/environments/homelab/env.hcl`.
7. **Dry run**: `uv run ansible-playbook playbooks/helm-deploy.yml --tags {service} --check --diff`
8. **Apply**: `uv run ansible-playbook playbooks/helm-deploy.yml --tags {service},caddy`
9. **Verify**: `curl https://{subdomain}.lab.infiniteroomlabs.cloud{health_path}`

## Rollback

```bash
helm uninstall {release-name} -n irl --kubeconfig ~/.kube/homelab.yaml
# Then re-run --tags caddy to regenerate the Caddyfile without the removed service
```
