---
work_package_id: "WP01"
title: "Root Configuration and Terraform Modules"
phase: "foundation"
lane: "planned"
assignee: ""
agent: ""
review_status: ""
dependencies: []
subtasks: ["T001", "T008", "T009", "T010", "T016"]
history:
  - date: "2026-02-24"
    action: "created"
    by: "planner"
---

# WP01: Root Configuration and Terraform Modules

## Implementation Command

```bash
spec-kitty implement WP01
```

No dependencies -- this is the first work package.

## Objectives & Success Criteria

**Objective**: Create the root Terragrunt configuration and all three reusable Terraform modules that form the foundation of the infrastructure project.

**Success criteria**:
- [ ] `root.hcl` exists at repository root with TFC `generate` block and provider version constraints
- [ ] `modules/cloudflare-zone/` validates with `terraform validate`
- [ ] `modules/porkbun-nameservers/` validates with `terraform validate`
- [ ] `modules/tfc-workspace/` validates with `terraform validate`
- [ ] `.gitignore` excludes Terraform/Terragrunt artifacts
- [ ] No secrets or credential values appear in any file

## Context & Constraints

**Project context**: This is a greenfield IaC project. No existing Terraform or Terragrunt files exist. You are creating the foundation that all subsequent work packages build on.

**Key architecture decisions** (from plan.md):
- Terraform Cloud org: `infinite-room-labs`
- TFC local execution mode (required -- Terragrunt `inputs` don't work with remote execution)
- Backend syntax: `cloud {}` block (not legacy `backend "remote"`)
- Backend generated via Terragrunt `generate` block (not `remote_state` -- TFC doesn't support auto-creation)
- Workspace names derived from directory path: `{env}-{provider}-{resource-group}`
- Cloudflare provider v5.17.0, Porkbun provider v0.2.1, TFE provider (latest)

**Constraints**:
- All credential handling via environment variables -- never hardcode secrets
- UTF-8 encoding only, no smart quotes or special characters
- Follow HCL formatting conventions (`terraform fmt` compatible)

## Subtasks & Detailed Guidance

### T001: Create `root.hcl` -- Root Terragrunt Configuration

**Purpose**: Establish the global Terragrunt config that all leaf `terragrunt.hcl` files include. This file generates the TFC backend config and sets provider version constraints.

**File**: `root.hcl` (repository root)

**Steps**:

1. Create `root.hcl` with a `locals` block that derives the workspace name from the directory path:
   ```hcl
   locals {
     # Derive workspace name from relative path: "environments/dev/cloudflare/zones" -> "dev-cloudflare-zones"
     # Strip the "environments/" prefix and replace "/" with "-"
     relative_path = path_relative_to_include()
     path_parts    = split("/", local.relative_path)
     # Skip "environments" prefix (first element)
     workspace_parts = slice(local.path_parts, 1, length(local.path_parts))
     workspace_name  = join("-", local.workspace_parts)
   }
   ```

2. Add a `generate "backend"` block that writes the `cloud {}` configuration:
   ```hcl
   generate "backend" {
     path      = "backend.tf"
     if_exists = "overwrite_terragrunt"
     contents  = <<-EOF
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

3. Add a `generate "providers"` block for required provider versions:
   ```hcl
   generate "providers" {
     path      = "providers.tf"
     if_exists = "overwrite_terragrunt"
     contents  = <<-EOF
       terraform {
         required_version = ">= 1.5"
         required_providers {
           cloudflare = {
             source  = "cloudflare/cloudflare"
             version = "~> 5.17"
           }
           porkbun = {
             source  = "jianyuan/porkbun"
             version = "~> 0.2"
           }
         }
       }
     EOF
   }
   ```

**Validation**:
- [ ] File is valid HCL (no syntax errors)
- [ ] `locals` block correctly derives workspace name from path
- [ ] `generate` blocks use `if_exists = "overwrite_terragrunt"`
- [ ] Organization is `infinite-room-labs`
- [ ] Provider versions match spec (cloudflare ~> 5.17, porkbun ~> 0.2)

**Edge cases**:
- The `global/tfc/workspaces/` bootstrap does NOT include `root.hcl` (it uses local state). The workspace name derivation only applies to environment resource groups.
- The path derivation assumes the directory structure `environments/{env}/{provider}/{resource-group}/`. If the structure changes, workspace names will change too.

---

### T008: Create `modules/tfc-workspace/` -- TFC Workspace Module

**Purpose**: Reusable module that creates a single Terraform Cloud workspace with configurable execution mode.

**Files**:
- `modules/tfc-workspace/main.tf` (~15 lines)
- `modules/tfc-workspace/variables.tf` (~20 lines)
- `modules/tfc-workspace/outputs.tf` (~8 lines)

**Steps**:

1. Create `variables.tf`:
   ```hcl
   variable "organization" {
     type        = string
     description = "Terraform Cloud organization name"
   }

   variable "workspace_name" {
     type        = string
     description = "Name for the TFC workspace"
   }

   variable "execution_mode" {
     type        = string
     default     = "local"
     description = "TFC execution mode (local or remote)"
   }
   ```

2. Create `main.tf`:
   ```hcl
   terraform {
     required_providers {
       tfe = {
         source  = "hashicorp/tfe"
         version = "~> 0.62"
       }
     }
   }

   resource "tfe_workspace" "this" {
     name           = var.workspace_name
     organization   = var.organization
     execution_mode = var.execution_mode
   }
   ```

3. Create `outputs.tf`:
   ```hcl
   output "workspace_id" {
     value       = tfe_workspace.this.id
     description = "The ID of the created TFC workspace"
   }

   output "workspace_name" {
     value       = tfe_workspace.this.name
     description = "The name of the created TFC workspace"
   }
   ```

**Validation**:
- [ ] `terraform validate` passes in `modules/tfc-workspace/`
- [ ] Module accepts `organization`, `workspace_name`, `execution_mode`
- [ ] Module outputs `workspace_id` and `workspace_name`
- [ ] TFE provider version constraint is set

---

### T009: Create `modules/cloudflare-zone/` -- Cloudflare Zone Module

**Purpose**: Reusable module that creates Cloudflare DNS zones for a list of domains and outputs the assigned nameservers.

**Files**:
- `modules/cloudflare-zone/main.tf` (~20 lines)
- `modules/cloudflare-zone/variables.tf` (~15 lines)
- `modules/cloudflare-zone/outputs.tf` (~20 lines)

**Steps**:

1. Create `variables.tf`:
   ```hcl
   variable "account_id" {
     type        = string
     description = "Cloudflare account ID"
   }

   variable "domains" {
     type        = list(string)
     description = "List of domain names to create Cloudflare zones for"
   }
   ```

2. Create `main.tf`:
   ```hcl
   resource "cloudflare_zone" "this" {
     for_each = toset(var.domains)

     account = {
       id = var.account_id
     }
     name = each.value
   }
   ```

   **CRITICAL**: Cloudflare provider v5.x uses `account = { id = "..." }` nested object syntax, NOT the flat `account_id` attribute from v4.x. This is a breaking change in v5. The resource attribute is `account.id`, passed as a nested block.

3. Create `outputs.tf`:
   ```hcl
   output "zone_ids" {
     value = {
       for domain, zone in cloudflare_zone.this : domain => zone.id
     }
     description = "Map of domain name to Cloudflare zone ID"
   }

   output "nameservers_map" {
     value = {
       for domain, zone in cloudflare_zone.this : domain => zone.name_servers
     }
     description = "Map of domain name to assigned Cloudflare nameservers"
   }
   ```

**Validation**:
- [ ] `terraform validate` passes in `modules/cloudflare-zone/`
- [ ] Uses `for_each = toset(var.domains)` for per-domain resources
- [ ] Uses `account = { id = var.account_id }` (v5 nested syntax, NOT `account_id`)
- [ ] Outputs `zone_ids` and `nameservers_map` as maps keyed by domain name
- [ ] `nameservers_map` output will feed into the Porkbun module's input

**Edge cases**:
- Zone type defaults to `"full"` (Cloudflare default) -- no need to set explicitly
- `name_servers` is a list, but the Porkbun module expects a set -- the conversion happens in the Terragrunt leaf `inputs` block

---

### T010: Create `modules/porkbun-nameservers/` -- Porkbun Nameserver Module

**Purpose**: Reusable module that updates nameserver delegation on Porkbun for each domain to point to Cloudflare-assigned nameservers.

**Files**:
- `modules/porkbun-nameservers/main.tf` (~15 lines)
- `modules/porkbun-nameservers/variables.tf` (~15 lines)
- `modules/porkbun-nameservers/outputs.tf` (~15 lines)

**Steps**:

1. Create `variables.tf`:
   ```hcl
   variable "domain_nameservers" {
     type = map(object({
       nameservers = set(string)
     }))
     description = "Map of domain name to its target nameservers (from Cloudflare zone outputs)"
   }
   ```

   The map key is the domain name (e.g., `"example.com"`), and the value contains the `nameservers` set. Using the domain as the map key enables clean `for_each`.

2. Create `main.tf`:
   ```hcl
   resource "porkbun_domain_nameservers" "this" {
     for_each = var.domain_nameservers

     domain      = each.key
     nameservers = each.value.nameservers
   }
   ```

3. Create `outputs.tf`:
   ```hcl
   output "domain_ns_status" {
     value = {
       for domain, ns in porkbun_domain_nameservers.this : domain => ns.nameservers
     }
     description = "Map of domain name to configured nameservers (for verification)"
   }
   ```

**Validation**:
- [ ] `terraform validate` passes in `modules/porkbun-nameservers/`
- [ ] Uses `for_each` over `var.domain_nameservers` map
- [ ] `nameservers` is typed as `set(string)` (matches Porkbun provider expectation)
- [ ] Domain name is used as `each.key` (the map key)

**Edge cases**:
- `nameservers` is a Set, not a List -- Terraform won't detect drift from nameserver reordering
- If a domain doesn't exist on Porkbun, the provider will error during plan/apply (expected behavior per spec)

---

### T016: Add `.gitignore` for Terraform/Terragrunt Artifacts

**Purpose**: Prevent Terraform and Terragrunt working files from being committed.

**File**: `.gitignore` (repository root -- append to existing or create)

**Steps**:

1. Check if `.gitignore` exists at the repository root. If it does, append the following entries. If not, create it.

2. Add these entries:
   ```gitignore
   # Terraform
   .terraform/
   *.tfstate
   *.tfstate.backup
   *.tfplan
   crash.log
   crash.*.log
   override.tf
   override.tf.json
   *_override.tf
   *_override.tf.json

   # Terragrunt
   .terragrunt-cache/

   # Terragrunt-generated files (recreated on init)
   backend.tf
   providers.tf

   # Environment variables (secrets)
   .env
   .env.*
   !.env.example
   !.envrc
   ```

**Validation**:
- [ ] `.gitignore` exists and contains all entries above
- [ ] `backend.tf` and `providers.tf` are ignored (generated by Terragrunt)
- [ ] `.envrc` is NOT ignored (it's a template, not secrets)

---

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Cloudflare provider v5 API differences from docs/examples | Use `account = { id = ... }` syntax, not `account_id`. Verify with `terraform validate` |
| TFE provider version incompatibility | Pin to `~> 0.62`, verify `tfe_workspace` resource schema |
| `path_relative_to_include()` not producing expected workspace names | Test with known paths: `environments/dev/cloudflare/zones` should yield `dev-cloudflare-zones` |

## Review Guidance

**Reviewer should verify**:
1. `root.hcl` workspace name derivation logic handles all expected paths correctly
2. All three modules pass `terraform validate`
3. No credentials or secrets appear in any file
4. Provider version constraints are correct (`~>` not `=`)
5. `.gitignore` covers all generated artifacts
6. Cloudflare zone resource uses v5 `account = { id = ... }` syntax

## Activity Log

- 2026-02-24: WP created by planner
