# Implementation Plan: Porkbun-to-Cloudflare Domain Onboarding

**Branch**: `001-porkbun-cloudflare-domain-onboarding` | **Date**: 2026-02-24 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `kitty-specs/001-porkbun-cloudflare-domain-onboarding/spec.md`

## Summary

Scaffold a greenfield Terragrunt + Terraform project that onboards Porkbun-registered domains to Cloudflare. For each domain listed in an environment variable, the system creates a Cloudflare zone and updates the domain's Porkbun nameservers to match Cloudflare's assigned nameservers. State is stored in Terraform Cloud (org: `infinite-room-labs`, local execution mode). A bootstrap layer manages TFC workspace creation. The project follows the `environments/{env}/{provider}/{resource-group}/` directory hierarchy with reusable modules in `modules/`.

## Technical Context

**Language/Version**: HCL (Terraform >= 1.5, Terragrunt >= 0.55)
**Primary Dependencies**:
  - Terraform provider `cloudflare/cloudflare` v5.17.0
  - Terraform provider `jianyuan/porkbun` v0.2.1
  - Terraform provider `hashicorp/tfe` (latest, for TFC workspace bootstrap)
**Storage**: Terraform Cloud (org `infinite-room-labs`, local execution mode)
**Testing**: `terragrunt plan` dry-runs; manual verification via Cloudflare dashboard and `dig NS <domain>`
**Target Platform**: CLI-driven infrastructure; operator runs from local machine
**Project Type**: Infrastructure-as-code (Terraform + Terragrunt)
**Constraints**: TFC local execution mode required (Terragrunt `inputs` don't work with remote execution)

## Constitution Check

*No constitution file found. Skipping constitution gates.*

The project constitution is defined informally via the parent CLAUDE.md:
- Directory hierarchy: `environments/{env}/provider/resource-group/` -- **COMPLIANT**
- Reusable modules in `modules/` -- **COMPLIANT**
- UTF-8 encoding, no smart quotes -- **WILL ENFORCE**
- No secrets in code -- **COMPLIANT** (env vars for all credentials)

## Project Structure

### Documentation (this feature)

```
kitty-specs/001-porkbun-cloudflare-domain-onboarding/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0 research (completed)
├── data-model.md        # Entity definitions (completed)
├── research/
│   ├── evidence-log.csv
│   └── source-register.csv
└── tasks.md             # Work packages (next phase)
```

### Source Code (repository root)

```
# Root Terragrunt configuration
root.hcl                              # Global settings: TFC backend, provider versions

# Reusable Terraform modules
modules/
├── cloudflare-zone/
│   ├── main.tf                       # cloudflare_zone resource (for_each over domains)
│   ├── variables.tf                  # account_id, domains list
│   └── outputs.tf                    # zone_ids map, nameservers map
├── porkbun-nameservers/
│   ├── main.tf                       # porkbun_domain_nameservers resource (for_each)
│   ├── variables.tf                  # domain-to-nameservers map
│   └── outputs.tf                    # domain_ns_status map
└── tfc-workspace/
    ├── main.tf                       # tfe_workspace + tfe_workspace_settings resources
    ├── variables.tf                  # org, workspace name, execution mode
    └── outputs.tf                    # workspace_id

# Environment hierarchy
environments/
├── global/
│   └── tfc/
│       └── workspaces/
│           └── terragrunt.hcl        # Bootstrap: creates all TFC workspaces (LOCAL state)
├── dev/
│   ├── env.hcl                       # Environment config: domains list, env name
│   ├── cloudflare/
│   │   ├── provider.hcl              # Cloudflare provider config
│   │   └── zones/
│   │       └── terragrunt.hcl        # Creates Cloudflare zones for dev domains
│   └── porkbun/
│       ├── provider.hcl              # Porkbun provider config
│       └── nameservers/
│           └── terragrunt.hcl        # Updates Porkbun NS for dev domains
└── prod/
    ├── env.hcl                       # Same structure as dev, different domain list
    ├── cloudflare/
    │   ├── provider.hcl
    │   └── zones/
    │       └── terragrunt.hcl
    └── porkbun/
        ├── provider.hcl
        └── nameservers/
            └── terragrunt.hcl
```

**Structure Decision**: Infrastructure-as-code layout following the project's established `environments/{env}/{provider}/{resource-group}/` convention. The `global/tfc/workspaces/` path is a new addition for the TFC bootstrap layer, sitting outside environment-specific directories since it manages cross-cutting workspace resources.

## Architecture Decisions

### AD-001: Terragrunt Configuration Hierarchy

Three levels of DRY config files handle variable inheritance:

| File | Scope | Contents |
|------|-------|----------|
| `root.hcl` | Global | TFC `cloud {}` generate block, required provider versions, common tags |
| `env.hcl` | Per environment | `environment` name, `domains` list, `cloudflare_account_id` |
| `provider.hcl` | Per provider | Provider-specific settings (currently none beyond what env vars provide) |
| `terragrunt.hcl` (leaf) | Per resource group | Module source, inputs from parent configs, dependencies |

Leaf `terragrunt.hcl` files include parents via:
```hcl
include "root" {
  path = find_in_parent_folders("root.hcl")
}
```
And read environment config via:
```hcl
locals {
  env_config = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}
```

### AD-002: TFC Backend via `generate` Block

Terragrunt `remote_state` doesn't support TFC auto-creation. Instead, `root.hcl` uses a `generate` block to write a `backend.tf` file containing the `cloud {}` block:

```hcl
generate "backend" {
  path      = "backend.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
terraform {
  cloud {
    organization = "infinite-room-labs"
    workspaces {
      name = "${local.workspace_name}"
    }
  }
}
EOF
}
```

Workspace names derived from directory path: `{env}-{provider}-{resource-group}` (e.g., `dev-cloudflare-zones`).

### AD-003: TFC Workspace Bootstrap (Local State)

The `environments/global/tfc/workspaces/` resource group:
- Uses the `hashicorp/tfe` provider to create TFC workspaces
- Stores its own state **locally** (in a `terraform.tfstate` file) to avoid the chicken-and-egg problem
- Must be applied **before** any other resource group
- Creates workspaces with `execution_mode = "local"`
- Lists all workspaces needed across all environments

This is the only resource group that does NOT use TFC remote state.

### AD-004: Cross-Provider Dependency Chain

Apply order enforced by Terragrunt `dependency` blocks:

```
TFC Workspaces (bootstrap, one-time)
        │
        ▼
Cloudflare Zones (per environment)
        │
        ▼
Porkbun Nameservers (per environment, reads zone outputs)
```

The Porkbun `terragrunt.hcl` declares:
```hcl
dependency "cloudflare_zones" {
  config_path = "../../cloudflare/zones"
}
```
And passes `dependency.cloudflare_zones.outputs.nameservers_map` into the module's inputs.

### AD-005: Module Design -- for_each over Domains

Both `cloudflare-zone` and `porkbun-nameservers` modules iterate over a list/map of domains using `for_each`. This means:
- Adding a domain = adding a string to the `domains` list in `env.hcl`
- Removing a domain = removing the string (Terraform plans destruction, operator approves)
- Each domain gets its own resource instance in state (independent lifecycle)

### AD-006: Credential Management

All credentials via environment variables, never in code:

| Variable | Purpose | Required By |
|----------|---------|-------------|
| `CLOUDFLARE_API_TOKEN` | Cloudflare API authentication | Cloudflare provider |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare account targeting | `env.hcl` via `get_env()` |
| `PORKBUN_API_KEY` | Porkbun API authentication | Porkbun provider |
| `PORKBUN_SECRET_KEY` | Porkbun API secret | Porkbun provider |
| `TF_TOKEN_app_terraform_io` | TFC API token | Terraform `cloud {}` block |

## Module Specifications

### Module: `modules/cloudflare-zone`

**Purpose**: Create Cloudflare DNS zones for a list of domains.

**Inputs**:
- `account_id` (string, required) -- Cloudflare account ID
- `domains` (list(string), required) -- Domain names to create zones for

**Resources**:
- `cloudflare_zone.this` (for_each over `domains`) -- Creates a zone per domain

**Outputs**:
- `zone_ids` (map: domain -> zone_id) -- For use by other Cloudflare resources
- `nameservers_map` (map: domain -> list(nameserver)) -- Fed to Porkbun module

### Module: `modules/porkbun-nameservers`

**Purpose**: Update Porkbun domain nameserver delegation to match Cloudflare-assigned nameservers.

**Inputs**:
- `domain_nameservers` (map(object({ domain = string, nameservers = set(string) })), required) -- Map of domain to its target nameservers

**Resources**:
- `porkbun_domain_nameservers.this` (for_each) -- Updates NS records per domain

**Outputs**:
- `domain_ns_status` (map: domain -> nameservers set) -- For verification

### Module: `modules/tfc-workspace`

**Purpose**: Create and configure a single TFC workspace.

**Inputs**:
- `organization` (string, required) -- TFC org name
- `workspace_name` (string, required) -- Workspace name
- `execution_mode` (string, default "local") -- TFC execution mode

**Resources**:
- `tfe_workspace.this` -- Creates the workspace

**Outputs**:
- `workspace_id` (string) -- TFC workspace identifier

## Apply Sequence (Operator Runbook)

### First-time setup (one-time):

1. Set environment variables: `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, `PORKBUN_API_KEY`, `PORKBUN_SECRET_KEY`, `TF_TOKEN_app_terraform_io`
2. Bootstrap TFC workspaces:
   ```bash
   cd environments/global/tfc/workspaces
   terragrunt init
   terragrunt apply
   ```
3. Apply per-environment (e.g., dev):
   ```bash
   cd environments/dev
   terragrunt run-all init
   terragrunt run-all apply
   ```
   Terragrunt handles ordering: Cloudflare zones first, then Porkbun nameservers.

### Adding a new domain:

1. Add domain string to `environments/{env}/env.hcl` `domains` list
2. Add corresponding workspace entries if needed in `environments/global/tfc/workspaces/terragrunt.hcl`
3. Run `terragrunt run-all apply` from the environment directory

### Removing a domain:

1. Remove domain from `domains` list in `env.hcl`
2. Run `terragrunt run-all plan` to review destruction plan
3. Approve and apply

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Porkbun provider immaturity (v0.2.1, community) | NS updates may fail on edge cases | Simple schema (2 resources), test with dev domain first |
| Cloudflare zone pending status delay | Zone not active until NS propagation verified | Expected behavior, not a Terraform concern; document for operators |
| TFC workspace naming drift | Wrong state backend if naming convention changes | Derive names programmatically from directory path in `root.hcl` |
| Bootstrap local state loss | Can't manage TFC workspaces | Low risk (workspaces still exist in TFC); re-import if needed |
| Rate limiting on bulk zone creation | Apply fails partway through | Terraform retries; reduce parallelism with `-parallelism=2` if needed |

## Complexity Tracking

No constitution violations to justify. The architecture is straightforward:
- 3 reusable modules (all simple, single-resource)
- 1 bootstrap layer (necessary for TFC workspace management)
- Standard Terragrunt hierarchy with variable inheritance
