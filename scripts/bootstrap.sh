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
# The tfe provider reads TFE_TOKEN, not the CLI credential variable.
export TFE_TOKEN="${TFE_TOKEN:-$TF_TOKEN_app_terraform_io}"

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
