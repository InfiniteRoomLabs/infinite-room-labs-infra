---
name: tg-plan
description: Run terragrunt plan for a specific environment leaf module with output summary
disable-model-invocation: true
---

# Terragrunt Plan

Run `terragrunt plan` for a leaf module under `terraform/environments/`.

## Available Leaf Modules

| Environment | Provider | Resource Group | Path |
|-------------|----------|----------------|------|
| dev | cloudflare | zones | `dev/cloudflare/zones/` |
| dev | porkbun | nameservers | `dev/porkbun/nameservers/` |
| global | cloudflare | tokens | `global/cloudflare/tokens/` |
| global | dockerhub | repos | `global/dockerhub/repos/` |
| global | tfc | workspaces | `global/tfc/workspaces/` |
| homelab | cloudflare | dns-records | `homelab/cloudflare/dns-records/` |
| homelab | digitalocean | k3s-agent | `homelab/digitalocean/k3s-agent/` |
| homelab | tailscale | acl | `homelab/tailscale/acl/` |
| homelab | tailscale | split-dns | `homelab/tailscale/split-dns/` |
| prod | cloudflare | dns-records | `prod/cloudflare/dns-records/` |
| prod | cloudflare | zones | `prod/cloudflare/zones/` |
| prod | porkbun | nameservers | `prod/porkbun/nameservers/` |
| prod | sendgrid | config | `prod/sendgrid/config/` |

## Workflow

1. Ask the user which leaf module to plan if not provided as an argument. Accept shorthand like "homelab dns" or "prod zones".
2. Resolve the path to the full leaf directory under `terraform/environments/`.
3. Run the plan:
   ```bash
   cd terraform/environments/<env>/<provider>/<resource-group> && terragrunt plan
   ```
4. Summarize the plan output for the user:
   - Resources to add, change, or destroy
   - Any warnings or errors
5. If the user wants to apply, confirm explicitly before running `terragrunt apply`.

## Notes

- State lives in Terraform Cloud (org: `infinite-room-labs`). No local state files.
- Provider credentials come from environment variables (sourced via direnv from `.envrc`).
- The Terraform MCP server is available for looking up provider docs and module details.
- Never run `terragrunt apply` without explicit user confirmation.
