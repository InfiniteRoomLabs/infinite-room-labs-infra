# SOP: Add a DNS Record

## For Homelab Services (*.lab.infiniteroomlabs.cloud)

1. Add the service to `ansible/inventory/group_vars/all/main.yml`:
   ```yaml
   irl_services:
     newservice:
       subdomain: "svc"
       port: 8888
       internal: false
   ```

2. Add the DNS record to `terraform/environments/homelab/env.hcl`:
   ```hcl
   { name = "svc.lab", type = "A", content = local.homelab_tailscale_ip, proxied = false },
   ```

3. Apply Terraform:
   ```bash
   cd terraform/environments/homelab/cloudflare/dns-records
   terragrunt apply
   ```

4. Update Caddy (re-run playbook -- Caddyfile is templated from irl_services):
   ```bash
   ./run-ansible.sh playbook playbooks/caddy.yml
   ```

5. Verify: `dig svc.lab.infiniteroomlabs.cloud`
