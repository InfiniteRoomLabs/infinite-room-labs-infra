# Bootstrap Cloudflare API Token Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Automate Cloudflare API token creation in the bootstrap layer so downstream resource groups get their credentials from Terraform state with an env var fallback.

**Architecture:** A new bootstrap resource group at `terraform/environments/global/cloudflare/tokens/` creates a scoped token using a manually-provisioned bootstrap token. Downstream `zones/` layers read the token via Terragrunt `dependency`. A `scripts/bootstrap.sh` orchestrates the full bootstrap sequence.

**Tech Stack:** Terraform (Cloudflare provider ~> 5.17), Terragrunt, Bash

**Design doc:** `docs/plans/2026-02-26-bootstrap-api-token-design.md`

---

### Task 1: Create the env helper library

**Files:**
- Create: `scripts/includes/env.sh`

**Step 1: Create the directory structure**

```bash
mkdir -p scripts/includes
```

**Step 2: Write `scripts/includes/env.sh`**

```bash
#!/usr/bin/env bash
# scripts/includes/env.sh
# Shared environment helpers for bootstrap scripts.
# Source this file -- do not execute it directly.

# Locate the repo root relative to this file.
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$_SCRIPT_DIR/../.." && pwd)"

# load_env -- source the .env file at the repo root if it exists.
load_env() {
  local env_file="$REPO_ROOT/.env"
  if [[ -f "$env_file" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$env_file"
    set +a
  else
    echo "Warning: $env_file not found. Relying on existing environment." >&2
  fi
}

# require_vars VAR1 VAR2 ... -- exit with an error listing any unset or empty vars.
require_vars() {
  local missing=()
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("$var")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: the following required environment variables are not set:" >&2
    for var in "${missing[@]}"; do
      echo "  - $var" >&2
    done
    echo "" >&2
    echo "Copy .env.example to .env and fill in the values, or export them directly." >&2
    exit 1
  fi
}
```

**Step 3: Commit**

```bash
git add scripts/includes/env.sh
git commit -m "feat: add shared env helper library for bootstrap scripts"
```

---

### Task 2: Create the bootstrap script

**Files:**
- Create: `scripts/bootstrap.sh`

**Step 1: Write `scripts/bootstrap.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

# scripts/bootstrap.sh
# Bootstraps the infrastructure by creating TFC workspaces and a scoped
# Cloudflare API token. All configuration comes from environment variables
# (12-factor). See .env.example for required values.
#
# Usage:
#   scripts/bootstrap.sh [OPTIONS]
#
# Options:
#   -h, --help       Show this help message and exit
#   -p, --plan       Run terragrunt plan instead of apply (dry run)
#   -s, --skip-tfc   Skip the TFC workspace bootstrap step

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=includes/env.sh
source "$SCRIPT_DIR/includes/env.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
ACTION="apply"
SKIP_TFC=false

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
usage() {
  cat <<HELP
Usage: $(basename "$0") [OPTIONS]

Bootstrap Infinite Room Labs infrastructure.

Creates Terraform Cloud workspaces and a scoped Cloudflare API token that
downstream resource groups use for zone and DNS management.

Prerequisites:
  Fill in .env (see .env.example) with at minimum:
    CLOUDFLARE_BOOTSTRAP_API_TOKEN  Cloudflare token with "API Tokens Write"
    CLOUDFLARE_ACCOUNT_ID           Cloudflare account ID
    TF_TOKEN_app_terraform_io       Terraform Cloud API token

Options:
  -h, --help       Show this help message and exit
  -p, --plan       Run terragrunt plan instead of apply (dry run)
  -s, --skip-tfc   Skip the TFC workspace bootstrap step

Examples:
  # Full bootstrap
  scripts/bootstrap.sh

  # Dry run -- preview what would change
  scripts/bootstrap.sh --plan

  # Re-run only the Cloudflare token step
  scripts/bootstrap.sh --skip-tfc
HELP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)   usage; exit 0 ;;
    -p|--plan)   ACTION="plan"; shift ;;
    -s|--skip-tfc) SKIP_TFC=true; shift ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Load and validate environment
# ---------------------------------------------------------------------------
load_env

REQUIRED_VARS=(CLOUDFLARE_BOOTSTRAP_API_TOKEN CLOUDFLARE_ACCOUNT_ID TF_TOKEN_app_terraform_io)
if [[ "$SKIP_TFC" == true ]]; then
  # TFC token not needed when skipping that step
  REQUIRED_VARS=(CLOUDFLARE_BOOTSTRAP_API_TOKEN CLOUDFLARE_ACCOUNT_ID)
fi
require_vars "${REQUIRED_VARS[@]}"

# ---------------------------------------------------------------------------
# Step 1: TFC workspaces
# ---------------------------------------------------------------------------
TFC_DIR="$REPO_ROOT/terraform/environments/global/tfc/workspaces"
if [[ "$SKIP_TFC" == false ]]; then
  echo "==> Step 1/2: Bootstrapping TFC workspaces"
  pushd "$TFC_DIR" > /dev/null
  terragrunt init -input=false
  terragrunt "$ACTION" -input=false
  popd > /dev/null
  echo ""
else
  echo "==> Step 1/2: Skipping TFC workspaces (--skip-tfc)"
  echo ""
fi

# ---------------------------------------------------------------------------
# Step 2: Cloudflare API token
# ---------------------------------------------------------------------------
TOKENS_DIR="$REPO_ROOT/terraform/environments/global/cloudflare/tokens"
echo "==> Step 2/2: Bootstrapping Cloudflare API token"
pushd "$TOKENS_DIR" > /dev/null
terragrunt init -input=false
terragrunt "$ACTION" -input=false
popd > /dev/null
echo ""

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
if [[ "$ACTION" == "apply" ]]; then
  echo "Bootstrap complete."
  echo ""
  echo "The Cloudflare infra token is stored in Terraform state at:"
  echo "  $TOKENS_DIR/terraform.tfstate"
  echo ""
  echo "Downstream resource groups will read it automatically via Terragrunt dependency."
  echo "To see the token value:  cd $TOKENS_DIR && terragrunt output -raw api_token"
else
  echo "Plan complete. Re-run without --plan to apply."
fi
```

**Step 2: Make it executable**

```bash
chmod +x scripts/bootstrap.sh
```

**Step 3: Commit**

```bash
git add scripts/bootstrap.sh
git commit -m "feat: add bootstrap script for TFC workspaces and Cloudflare token"
```

---

### Task 3: Create the Cloudflare token bootstrap resource group

**Files:**
- Create: `terraform/environments/global/cloudflare/tokens/terragrunt.hcl`

**Step 1: Create the directory**

```bash
mkdir -p terraform/environments/global/cloudflare/tokens
```

**Step 2: Write `terraform/environments/global/cloudflare/tokens/terragrunt.hcl`**

This follows the same pattern as `global/tfc/workspaces/terragrunt.hcl` -- standalone with local state, inline `generate "main"` block, no `root.hcl` include.

```hcl
# Cloudflare API Token Bootstrap
# This resource group uses LOCAL state (not TFC) to avoid chicken-and-egg.
# Apply this AFTER TFC workspaces and BEFORE any environment resource groups.
#
# Required env vars:
#   CLOUDFLARE_BOOTSTRAP_API_TOKEN - token with "API Tokens Write" permission
#   CLOUDFLARE_ACCOUNT_ID          - Cloudflare account ID

generate "main" {
  path      = "main.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    terraform {
      required_version = ">= 1.5"
      required_providers {
        cloudflare = {
          source  = "cloudflare/cloudflare"
          version = "~> 5.17"
        }
      }
    }

    variable "bootstrap_api_token" {
      type        = string
      sensitive   = true
      description = "Cloudflare API token with 'API Tokens Write' permission"
    }

    variable "account_id" {
      type        = string
      description = "Cloudflare account ID"
    }

    provider "cloudflare" {
      api_token = var.bootstrap_api_token
    }

    data "cloudflare_api_token_permission_groups" "all" {}

    locals {
      permissions = data.cloudflare_api_token_permission_groups.all.permissions
    }

    resource "cloudflare_api_token" "infra" {
      name = "infinite-room-labs-infra"

      policies = [
        {
          effect = "allow"
          permission_groups = [
            { id = local.permissions["Zone Read"] },
            { id = local.permissions["Zone Write"] },
          ]
          resources = {
            "com.cloudflare.api.account.$${var.account_id}" = jsonencode("*")
          }
        }
      ]
    }

    output "api_token" {
      value     = cloudflare_api_token.infra.value
      sensitive = true
    }
  EOF
}

inputs = {
  bootstrap_api_token = get_env("CLOUDFLARE_BOOTSTRAP_API_TOKEN")
  account_id          = get_env("CLOUDFLARE_ACCOUNT_ID")
}
```

**Note on `$$`:** Inside a Terragrunt `generate` heredoc, `$${var.account_id}` produces the literal `${var.account_id}` in the generated `.tf` file so Terraform (not Terragrunt) performs the interpolation.

**Step 3: Validate syntax**

```bash
cd terraform/environments/global/cloudflare/tokens
terragrunt init -input=false
terragrunt validate
```

Expected: no errors.

**Step 4: Commit**

```bash
git add terraform/environments/global/cloudflare/tokens/terragrunt.hcl
git commit -m "feat: add Cloudflare API token bootstrap resource group"
```

---

### Task 4: Update the downstream Cloudflare provider config

**Files:**
- Modify: `terraform/environments/dev/cloudflare/provider.hcl`
- Modify: `terraform/environments/prod/cloudflare/provider.hcl`

Both files are identical today and get the same change.

**Step 1: Replace the provider config in both files**

The new content for both `dev/cloudflare/provider.hcl` and `prod/cloudflare/provider.hcl`:

```hcl
# Cloudflare provider configuration
# Auth priority: bootstrap token from Terragrunt dependency > CLOUDFLARE_API_TOKEN env var

generate "cloudflare_provider" {
  path      = "provider-cloudflare.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    variable "bootstrap_api_token" {
      type        = string
      default     = ""
      sensitive   = true
      description = "Cloudflare API token from bootstrap. Falls back to CLOUDFLARE_API_TOKEN env var when empty."
    }

    provider "cloudflare" {
      api_token = var.bootstrap_api_token != "" ? var.bootstrap_api_token : null
    }
  EOF
}
```

**Step 2: Validate one of the downstream modules**

```bash
cd terraform/environments/dev/cloudflare/zones
terragrunt validate
```

Expected: passes (provider falls back to env var since no dependency output yet).

**Step 3: Commit**

```bash
git add terraform/environments/dev/cloudflare/provider.hcl \
        terraform/environments/prod/cloudflare/provider.hcl
git commit -m "feat: add bootstrap token fallback to Cloudflare provider config"
```

---

### Task 5: Wire the dependency in downstream zones

**Files:**
- Modify: `terraform/environments/dev/cloudflare/zones/terragrunt.hcl`
- Modify: `terraform/environments/prod/cloudflare/zones/terragrunt.hcl`

Both files are identical today and get the same change.

**Step 1: Add the dependency block and update inputs**

Append the dependency and update `inputs` in both files. The full file becomes:

```hcl
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "provider" {
  path   = find_in_parent_folders("provider.hcl")
  expose = true
}

locals {
  env_config = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

dependency "bootstrap_tokens" {
  config_path = "${get_repo_root()}/terraform/environments/global/cloudflare/tokens"

  mock_outputs = {
    api_token = ""
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

terraform {
  source = "${get_repo_root()}/terraform/modules//cloudflare-zone"
}

inputs = {
  account_id          = local.env_config.locals.cloudflare_account_id
  domains             = local.env_config.locals.domains
  bootstrap_api_token = dependency.bootstrap_tokens.outputs.api_token
}
```

**Step 2: Validate both environments**

```bash
cd terraform/environments/dev/cloudflare/zones
terragrunt validate
```

```bash
cd terraform/environments/prod/cloudflare/zones
terragrunt validate
```

Expected: passes (mock outputs used since bootstrap has not been applied).

**Step 3: Commit**

```bash
git add terraform/environments/dev/cloudflare/zones/terragrunt.hcl \
        terraform/environments/prod/cloudflare/zones/terragrunt.hcl
git commit -m "feat: wire bootstrap token dependency into downstream zones"
```

---

### Task 6: Update README.md

**Files:**
- Modify: `README.md`

**Step 1: Update the credential table**

In the `### 1. Configure credentials` section, replace the credential table with:

| Variable | Where to get it |
|----------|----------------|
| `CLOUDFLARE_BOOTSTRAP_API_TOKEN` | Cloudflare dashboard > My Profile > API Tokens > Create Token > custom token with "API Tokens: Edit" under User permissions |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare dashboard > any domain > Overview > right sidebar under "API" |
| `PORKBUN_API_KEY` | Porkbun > Account > API Access |
| `PORKBUN_SECRET_KEY` | Porkbun > Account > API Access (generated with the API key) |
| `TF_TOKEN_app_terraform_io` | Terraform Cloud > User Settings > Tokens > Create an API token |

Note: `CLOUDFLARE_API_TOKEN` is no longer required for setup -- the bootstrap creates it. It can still be set as a fallback.

**Step 2: Replace the "First-time setup" section**

Replace everything from `### First-time setup` through the end of `#### 2. Apply an environment` with:

```markdown
### First-time setup

#### 1. Bootstrap (TFC workspaces + Cloudflare API token)

The bootstrap script creates Terraform Cloud workspaces and a scoped Cloudflare API token. It uses local state (chicken-and-egg problem with TFC). Only needed once.

```bash
scripts/bootstrap.sh
```

Preview what the bootstrap will do without applying:

```bash
scripts/bootstrap.sh --plan
```

Re-run only the Cloudflare token step (e.g., after changing token permissions):

```bash
scripts/bootstrap.sh --skip-tfc
```

Run `scripts/bootstrap.sh --help` for all options.

#### 2. Apply an environment

Terragrunt handles ordering automatically (Cloudflare zones first, then Porkbun nameservers). The zones layer reads the API token from the bootstrap state automatically.

```bash
cd terraform/environments/dev
terragrunt run-all apply
```
```

**Step 3: Update the structure tree**

Add the new paths to the structure tree in the Terraform section:

```
terraform/
  root.hcl                                  # Global: TFC backend, provider versions
  modules/
    cloudflare-zone/                        # Creates Cloudflare zones for a list of domains
    porkbun-nameservers/                    # Updates Porkbun NS to match Cloudflare
    tfc-workspace/                          # Creates a single TFC workspace
  environments/
    global/
      tfc/workspaces/                       # Bootstrap: creates all TFC workspaces (local state)
      cloudflare/tokens/                    # Bootstrap: creates scoped Cloudflare API token (local state)
    dev/
      ...
    prod/
      ...
scripts/
  bootstrap.sh                              # Orchestrates full bootstrap sequence
  includes/
    env.sh                                  # Shared env loading and validation helpers
```

**Step 4: Commit**

```bash
git add README.md
git commit -m "docs: add bootstrap script and Cloudflare token to README"
```

---

### Task 7: End-to-end validation

**Step 1: Run the bootstrap in plan mode**

```bash
scripts/bootstrap.sh --plan
```

Expected: both steps show a plan without errors. The Cloudflare token step shows 1 resource to add.

**Step 2: Run the bootstrap for real**

```bash
scripts/bootstrap.sh
```

Expected: TFC workspaces created (or no changes if already exist), Cloudflare API token created.

**Step 3: Verify downstream can read the token**

```bash
cd terraform/environments/dev/cloudflare/zones
terragrunt plan
```

Expected: plan runs using the token from bootstrap state (no `CLOUDFLARE_API_TOKEN` env var needed).

**Step 4: Commit any generated files if needed**

No generated files should be committed -- `.gitignore` should already exclude `.terraform/` and `*.tfstate`. Verify:

```bash
git status
```

Expected: clean working tree.
