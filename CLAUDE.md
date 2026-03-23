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
| `ansible/` | Ansible | Homelab server configuration and service deployment |

Do NOT put Terraform files at the repo root -- they live under `terraform/`. Do NOT put Ansible files at the repo root -- they live under `ansible/`.

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

### Ansible

See `ansible/CLAUDE.md` for full Ansible documentation (layout, running, secrets, SSH access).

### Secrets Sync

`scripts/bw-sync.sh` syncs secrets from Bitwarden to Ansible Vault and Kubernetes. It is the only authorized write path to `vault.yml`.

```
scripts/
  bw-sync.sh          # Sync script -- reads BW, writes to ansible vault and/or K8s
  bw-sync-config.yaml # Mapping of BW item names to ansible_var and k8s_secret targets
```

Usage:

```bash
./scripts/bw-sync.sh --target both        # Sync to both Ansible Vault and Kubernetes
./scripts/bw-sync.sh --dry-run --target both  # Preview without writing
./scripts/bw-sync.sh --check-rotation     # Report secrets overdue for rotation
./scripts/bw-sync.sh --verify-k8s        # Diff K8s secrets against Bitwarden
```

Rotation policy: 180 days for infra secrets, 365 days for service secrets.
Full procedure: `ansible/docs/sops/rotate-secrets.md`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full guide on adding services, running Ansible/Terraform, secrets management, node labels, networking, and common gotchas.

## Testing

See [TESTING.md](TESTING.md) for the full acceptance test suite documentation.

Quick: `cd tests/ && task smoke` (17 smoke tests). Full: `task validate` (Goss + pytest + report).

## Research Protocol

- **Project-wide research**: `docs/plans/RESEARCH.md` tracks open technical questions and provider evaluations. Detailed outputs go in `docs/plans/resources/{slug}.md`.
- **Feature-scoped research**: `kitty-specs/{feature}/research.md` tracks research for a specific Spec Kitty feature.
- When a conversation surfaces an unresolved technical question (provider limits, tool comparisons, architecture trade-offs), capture it in `docs/plans/RESEARCH.md` as a new open item.
- Before starting infrastructure work that depends on an open research item, run a research round first. See the agent instructions inside `RESEARCH.md` for the workflow.
- Reference `docs/plans/infrastructure-roadmap.md` for the master plan and phase sequencing.
