# SOP: Deploy a New Service

## Prerequisites
- SSH access to homelab via Tailscale
- Ansible runner built (`./ansible/run-ansible.sh shell` works)

## Steps

1. **Create compose template**: `ansible/templates/compose/{stack}/docker-compose.yml.j2`
2. **Add variables**: Add any new vars to `inventory/group_vars/all/main.yml`
3. **Add secrets**: Add any passwords to `inventory/group_vars/all/vault.yml` and re-encrypt
4. **Create playbook**: `ansible/playbooks/{service}.yml`
5. **Add to site.yml**: Import the playbook in the correct phase
6. **Add to Caddyfile**: Update `irl_services` in group_vars if the service needs HTTP access
7. **Add DNS record**: Update `homelab_dns_records` in `terraform/environments/homelab/env.hcl`
8. **Dry run**: `./run-ansible.sh playbook playbooks/{service}.yml --check --diff`
9. **Apply**: `./run-ansible.sh playbook playbooks/{service}.yml`
10. **Verify**: Check service health at the assigned URL

## Rollback

```bash
ssh wes@homelab
cd /opt/irl/{stack}
sudo docker compose down
```
