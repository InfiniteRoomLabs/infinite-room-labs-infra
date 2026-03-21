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

### Ansible layout

```
ansible/
  ansible.cfg                             # YAML output, pipelining, fact caching
  Dockerfile                              # Containerized runner (python:3.12-slim + ansible-core)
  run-ansible.sh                          # Runner wrapper (playbook/galaxy/vault/shell)
  requirements.yml                        # Galaxy collections and roles
  site.yml                                # Master orchestrator (imports playbooks in order)
  inventory/
    hosts.ini                             # Homelab via LAN or Tailscale IP
    group_vars/all/main.yml               # Global vars (domains, compose paths, services)
    group_vars/all/vault.yml              # Ansible Vault encrypted secrets
    group_vars/homelab/main.yml           # Homelab group vars (firewall ports)
    host_vars/homelab.yml                 # Resource-scaled params (RAM budgets, PG tuning)
  playbooks/                              # One playbook per concern, flat structure
  templates/                              # Jinja2 templates for configs and compose files
  files/                                  # Static files (dashboards, sanoid config)
  docs/sops/                              # Standard operating procedures
  docs/runbooks/                          # Incident runbooks
```

- **Runner**: Use `./ansible/run-ansible.sh playbook site.yml` to run from Docker. No local Ansible needed.
- **Playbooks** are flat (no roles). One per concern, imported by `site.yml` in dependency order.
- **Phases**: site.yml is tagged with phase0-phase5. Run a phase: `--tags phase0`.
- **Secrets**: `inventory/group_vars/all/vault.yml` must be encrypted before use. Populated via `bw-sync.sh` -- do not edit manually.
- **Compose stacks** deploy to `/opt/irl/{stack}/docker-compose.yml` on the server.

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

## Research Protocol

- **Project-wide research**: `docs/plans/RESEARCH.md` tracks open technical questions and provider evaluations. Detailed outputs go in `docs/plans/resources/{slug}.md`.
- **Feature-scoped research**: `kitty-specs/{feature}/research.md` tracks research for a specific Spec Kitty feature.
- When a conversation surfaces an unresolved technical question (provider limits, tool comparisons, architecture trade-offs), capture it in `docs/plans/RESEARCH.md` as a new open item.
- Before starting infrastructure work that depends on an open research item, run a research round first. See the agent instructions inside `RESEARCH.md` for the workflow.
- Reference `docs/plans/infrastructure-roadmap.md` for the master plan and phase sequencing.
