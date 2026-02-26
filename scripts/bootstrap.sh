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
# Helpers
# ---------------------------------------------------------------------------

# reconcile_imports DIR RESOURCE_TYPE IMPORT_ID_FN
#
# Compares planned creates against current state and imports any resources
# that already exist upstream but are missing from local state. This handles
# the common case where a previous apply partially succeeded or resources
# were created outside Terraform.
#
# Arguments:
#   DIR            - working directory containing the terragrunt.hcl
#   RESOURCE_TYPE  - Terraform resource type to reconcile (e.g. tfe_workspace)
#   IMPORT_ID_FN   - a function that receives a resource key and prints the
#                    import ID (e.g. "infinite-room-labs/dev-cloudflare-zones")
reconcile_imports() {
  local dir="$1"
  local resource_type="$2"
  local import_id_fn="$3"

  local state_list plan_output
  state_list=$(terragrunt state list 2>/dev/null || echo "")

  # Run plan to discover which resources would be created
  plan_output=$(terragrunt plan -no-color -input=false 2>&1)

  # Extract resource keys from lines like:
  #   # tfe_workspace.this["dev-cloudflare-zones"] will be created
  local keys
  keys=$(echo "$plan_output" \
    | grep -oP "# ${resource_type}\\.this\\[\"\\K[^\"]+(?=\"\\] will be created)" \
    || true)

  [[ -z "$keys" ]] && return 0

  while IFS= read -r key; do
    local addr="${resource_type}.this[\"${key}\"]"

    # Skip if already tracked in state
    if echo "$state_list" | grep -qF "$addr"; then
      continue
    fi

    local import_id
    import_id=$("$import_id_fn" "$key")

    echo "  Importing existing resource: $addr -> $import_id"
    local import_stderr
    if import_stderr=$(terragrunt import -input=false "$addr" "$import_id" 2>&1); then
      echo "  Imported successfully."
    else
      # If the import failed because the resource doesn't exist upstream,
      # that's expected -- apply will create it. Otherwise surface the error.
      if echo "$import_stderr" | grep -qi "not found\|does not exist\|no workspace found"; then
        echo "  Not found upstream; apply will create it."
      else
        echo "  Import failed:" >&2
        echo "$import_stderr" >&2
      fi
    fi
  done <<< "$keys"
}

# ---------------------------------------------------------------------------
# Step 1: TFC workspaces
# ---------------------------------------------------------------------------
# The tfe provider reads TFE_TOKEN, not the CLI credential variable.
export TFE_TOKEN="${TFE_TOKEN:-$TF_TOKEN_app_terraform_io}"

TFC_ORG="infinite-room-labs"
tfc_workspace_import_id() { echo "${TFC_ORG}/$1"; }

TFC_DIR="$REPO_ROOT/terraform/environments/global/tfc/workspaces"
if [[ "$SKIP_TFC" == false ]]; then
  echo "==> Step 1/2: Bootstrapping TFC workspaces"
  pushd "$TFC_DIR" > /dev/null
  terragrunt init -input=false
  if [[ "$ACTION" == "apply" ]]; then
    reconcile_imports . tfe_workspace tfc_workspace_import_id
  fi
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
