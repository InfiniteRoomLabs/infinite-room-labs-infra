---
work_package_id: WP02
title: TFC Workspace Bootstrap and Environment Configs
lane: planned
dependencies: []
subtasks: [T011, T002, T003, T018]
phase: foundation
assignee: ''
agent: ''
review_status: ''
history:
- date: '2026-02-24'
  action: created
  by: planner
---

# WP02: TFC Workspace Bootstrap and Environment Configs

## Implementation Command

```bash
spec-kitty implement WP02 --base WP01
```

Depends on WP01 (needs `modules/tfc-workspace/` and `root.hcl` to exist).

## Objectives & Success Criteria

**Objective**: Create the TFC workspace bootstrap layer that provisions all TFC workspaces, environment-level config files for dev and prod, and a direnv `.envrc` template.

**Success criteria**:
- [ ] `environments/global/tfc/workspaces/terragrunt.hcl` exists and uses local state (NOT TFC backend)
- [ ] `terragrunt validate` passes in `environments/global/tfc/workspaces/`
- [ ] `environments/dev/env.hcl` exports `environment`, `domains`, and `cloudflare_account_id` locals
- [ ] `environments/prod/env.hcl` exports matching locals with prod-specific values
- [ ] `.envrc` exists with all required environment variable placeholders
- [ ] Bootstrap creates exactly 4 workspaces: `dev-cloudflare-zones`, `dev-porkbun-nameservers`, `prod-cloudflare-zones`, `prod-porkbun-nameservers`

## Context & Constraints

**Why a bootstrap layer**: TFC workspaces must exist before any other resource group can `terragrunt init` (the `cloud {}` block references the workspace by name). Terragrunt does NOT auto-create TFC workspaces (unlike S3 buckets for `remote_state`).

**Why local state**: The bootstrap module creates the TFC workspaces that store state for other modules. It can't store its own state in a workspace that doesn't exist yet -- chicken-and-egg problem. Local state is the pragmatic solution.

**Key decisions** (from plan.md):
- TFC org: `infinite-room-labs`
- Execution mode: `local` for all workspaces
- `env.hcl` exports locals read by child `terragrunt.hcl` files via `read_terragrunt_config(find_in_parent_folders("env.hcl"))`
- `CLOUDFLARE_ACCOUNT_ID` sourced from environment variable via `get_env()`
- Domain lists are placeholders for now (user will add real domains when ready)

## Subtasks & Detailed Guidance

### T011: Create `environments/global/tfc/workspaces/terragrunt.hcl` -- Bootstrap

**Purpose**: Bootstrap all TFC workspaces needed by the project. This is applied once before any other infrastructure, and uses local state.

**File**: `environments/global/tfc/workspaces/terragrunt.hcl` (~60 lines)

**Steps**:

1. Create the directory structure:
   ```
   environments/global/tfc/workspaces/
   ```

2. Create `terragrunt.hcl` that does NOT include `root.hcl`:
   ```hcl
   # TFC Workspace Bootstrap
   # This resource group uses LOCAL state (not TFC) to avoid chicken-and-egg.
   # Apply this FIRST before any other resource group.

   terraform {
     source = "${get_repo_root()}/modules//tfc-workspace"
   }
   ```

   **CRITICAL**: Do NOT add `include "root"` -- this module must NOT get the generated `cloud {}` backend. It uses Terraform's default local state.

3. Define the workspace list and use `for_each`-like pattern. Since the `tfc-workspace` module creates a single workspace, you have two options:

   **Option A** (recommended): Modify the module call to handle multiple workspaces inline:
   ```hcl
   terraform {
     source = "${get_repo_root()}/modules//tfc-workspace"
   }

   inputs = {
     organization   = "infinite-room-labs"
     workspace_name = "placeholder"  # Overridden per workspace
     execution_mode = "local"
   }
   ```

   However, since the module creates ONE workspace, and we need FOUR, the cleanest approach is to have the bootstrap `terragrunt.hcl` use the TFE provider directly with a `for_each` local, rather than going through the single-workspace module.

   **Better approach**: Create a dedicated `main.tf` inline via `generate`, or create the bootstrap terragrunt to generate a local Terraform config:

   ```hcl
   # Bootstrap: creates all TFC workspaces
   # Uses LOCAL state -- do NOT include root.hcl

   generate "main" {
     path      = "main.tf"
     if_exists = "overwrite_terragrunt"
     contents  = <<-EOF
       terraform {
         required_providers {
           tfe = {
             source  = "hashicorp/tfe"
             version = "~> 0.62"
           }
         }
       }

       variable "organization" {
         type = string
       }

       variable "workspaces" {
         type = map(object({
           execution_mode = optional(string, "local")
         }))
       }

       resource "tfe_workspace" "this" {
         for_each       = var.workspaces
         name           = each.key
         organization   = var.organization
         execution_mode = each.value.execution_mode
       }

       output "workspace_ids" {
         value = { for name, ws in tfe_workspace.this : name => ws.id }
       }
     EOF
   }

   inputs = {
     organization = "infinite-room-labs"
     workspaces = {
       "dev-cloudflare-zones"       = {}
       "dev-porkbun-nameservers"    = {}
       "prod-cloudflare-zones"      = {}
       "prod-porkbun-nameservers"   = {}
     }
   }
   ```

   This approach keeps everything self-contained in the bootstrap `terragrunt.hcl` -- no external module reference needed for the bootstrap case.

**Validation**:
- [ ] `terragrunt.hcl` does NOT include `root.hcl`
- [ ] No `cloud {}` or `remote_state` configuration
- [ ] All 4 workspace names are listed: `dev-cloudflare-zones`, `dev-porkbun-nameservers`, `prod-cloudflare-zones`, `prod-porkbun-nameservers`
- [ ] Organization is `infinite-room-labs`
- [ ] All workspaces use `execution_mode = "local"`
- [ ] `terragrunt validate` passes

**Edge cases**:
- If a workspace already exists in TFC, `tfe_workspace` will error. Operator can import: `terraform import 'tfe_workspace.this["dev-cloudflare-zones"]' dev-cloudflare-zones`
- Adding new environment resource groups later requires adding workspace entries here

---

### T002: Create `environments/dev/env.hcl` -- Dev Environment Config

**Purpose**: Define dev environment variables that child resource groups inherit via `read_terragrunt_config()`.

**File**: `environments/dev/env.hcl` (~20 lines)

**Steps**:

1. Create `environments/dev/env.hcl`:
   ```hcl
   locals {
     environment = "dev"

     # Domains to onboard to Cloudflare in the dev environment.
     # Add domains here to create Cloudflare zones and update Porkbun nameservers.
     domains = [
       # "dev-example.com",  # Uncomment and replace with real domains
     ]

     # Sourced from CLOUDFLARE_ACCOUNT_ID environment variable.
     # Set this before running terragrunt.
     cloudflare_account_id = get_env("CLOUDFLARE_ACCOUNT_ID")
   }
   ```

**Validation**:
- [ ] `locals` block exports `environment`, `domains`, and `cloudflare_account_id`
- [ ] `domains` is an empty list with a commented example
- [ ] `cloudflare_account_id` uses `get_env("CLOUDFLARE_ACCOUNT_ID")`
- [ ] No hardcoded secrets or account IDs

---

### T003: Create `environments/prod/env.hcl` -- Prod Environment Config

**Purpose**: Define prod environment variables, mirroring dev structure.

**File**: `environments/prod/env.hcl` (~20 lines)

**Steps**:

1. Create `environments/prod/env.hcl`:
   ```hcl
   locals {
     environment = "prod"

     # Domains to onboard to Cloudflare in the prod environment.
     # Add domains here to create Cloudflare zones and update Porkbun nameservers.
     domains = [
       # "example.com",  # Uncomment and replace with real domains
     ]

     # Sourced from CLOUDFLARE_ACCOUNT_ID environment variable.
     cloudflare_account_id = get_env("CLOUDFLARE_ACCOUNT_ID")
   }
   ```

**Validation**:
- [ ] Structure mirrors `environments/dev/env.hcl` exactly
- [ ] `environment` is `"prod"` (not `"dev"`)
- [ ] `domains` list is empty with commented placeholder
- [ ] Same `get_env()` call for account ID

---

### T018: Create `.envrc` Template for direnv

**Purpose**: Provide a direnv `.envrc` file that documents all required environment variables and loads them from a `.env` file (which is gitignored).

**File**: `.envrc` (repository root, ~15 lines)

**Steps**:

1. Create `.envrc`:
   ```bash
   # Load environment variables from .env file (gitignored)
   # Copy .env.example to .env and fill in your values
   dotenv_if_exists .env

   # Required environment variables:
   #   CLOUDFLARE_API_TOKEN    - Cloudflare API token with zone management permissions
   #   CLOUDFLARE_ACCOUNT_ID   - Cloudflare account ID
   #   PORKBUN_API_KEY         - Porkbun API key
   #   PORKBUN_SECRET_KEY      - Porkbun API secret key
   #   TF_TOKEN_app_terraform_io - Terraform Cloud API token
   ```

2. Create `.env.example` (template, committed to repo):
   ```bash
   # Cloudflare
   CLOUDFLARE_API_TOKEN=
   CLOUDFLARE_ACCOUNT_ID=

   # Porkbun
   PORKBUN_API_KEY=
   PORKBUN_SECRET_KEY=

   # Terraform Cloud
   TF_TOKEN_app_terraform_io=
   ```

**Validation**:
- [ ] `.envrc` uses `dotenv_if_exists` (not `dotenv` -- won't error if `.env` doesn't exist)
- [ ] `.env.example` lists all 5 required variables with empty values
- [ ] `.env` is in `.gitignore` (handled by T016 in WP01)
- [ ] `.envrc` is NOT in `.gitignore` (it's documentation, not secrets)

---

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Bootstrap uses local state -- could be lost | Low risk: workspaces still exist in TFC; `terraform import` can recover |
| `get_env()` fails if env var not set | Terragrunt will surface a clear error message; `.envrc` documents the required vars |
| Bootstrap inline `generate` approach is unusual | Self-contained is better than adding module complexity; well-commented for future maintainers |

## Review Guidance

**Reviewer should verify**:
1. Bootstrap `terragrunt.hcl` does NOT include `root.hcl` or reference TFC backend
2. All 4 workspace names match the naming convention: `{env}-{provider}-{resource-group}`
3. `env.hcl` files use `get_env()` for `CLOUDFLARE_ACCOUNT_ID` (no hardcoded value)
4. `.envrc` and `.env.example` list all 5 required environment variables
5. No actual credentials or account IDs appear in committed files

## Activity Log

- 2026-02-24: WP created by planner
