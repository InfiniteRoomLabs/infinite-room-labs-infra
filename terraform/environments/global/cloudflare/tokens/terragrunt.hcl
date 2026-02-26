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

    # Well-known Cloudflare permission group IDs.
    # The bootstrap token lacks permission to query these dynamically,
    # so we hardcode the stable UUIDs.
    # Source: https://gist.github.com/f3l1x/13d3e43933e6d770aabee95410f8ee1d
    locals {
      perm_zone_read  = "c8fed203ed3043cba015a93ad1616f1f"
      perm_zone_write = "e6d2666161e84845a636613608cee8d5"
    }

    resource "cloudflare_api_token" "infra" {
      name = "infinite-room-labs-infra"

      policies = [
        {
          effect = "allow"
          permission_groups = [
            { id = local.perm_zone_read },
            { id = local.perm_zone_write },
          ]
          resources = jsonencode({
            "com.cloudflare.api.account.$${var.account_id}" = "*"
          })
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
