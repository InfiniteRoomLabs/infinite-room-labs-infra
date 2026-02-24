<!-- CCSM:START -->
## Secret Handling Protocol

This project uses Claude Code Secrets Manager (CCSM). Follow these rules:

1. NEVER read, cat, echo, print, or log secret values.
2. Use placeholder syntax in shell commands: `${{SECRET:credName}}`
3. Use the `authenticated_request` MCP tool for API calls with secrets.
4. Run `ccsm secret list` to see available credentials.
<!-- CCSM:END -->

## Repository Structure

This is a multi-tool IaC monorepo. Each IaC tool has its own top-level directory:

| Directory | Tool | Purpose |
|-----------|------|---------|
| `terraform/` | Terraform + Terragrunt | Cloud resource provisioning (domains, DNS, zones) |

More directories (e.g., `ansible/`) will be added over time. Do NOT put Terraform files at the repo root -- they live under `terraform/`.

### Terraform layout

```
terraform/
  root.hcl                              # Global Terragrunt config (TFC backend, provider versions)
  modules/                              # Reusable Terraform modules
  environments/{env}/{provider}/{rg}/   # Leaf terragrunt.hcl files per resource group
```

- **Modules** are in `terraform/modules/`. Module sources in leaf configs use `${get_repo_root()}/terraform/modules//module-name`.
- **Environments** follow `terraform/environments/{env}/{provider}/{resource-group}/`.
- **Domain lists** are in `terraform/environments/{env}/env.hcl`.
- **State** is in Terraform Cloud (org: `infinite-room-labs`). Workspace names derived from path relative to `root.hcl`.
- **Credentials** come from environment variables, never hardcoded. See `.env.example`.
