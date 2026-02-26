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
