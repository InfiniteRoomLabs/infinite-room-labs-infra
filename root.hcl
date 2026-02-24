# Root Terragrunt Configuration
# Included by all leaf terragrunt.hcl files (except bootstrap).
# Generates TFC backend config and provider version constraints.

locals {
  # Derive workspace name from relative path:
  #   "environments/dev/cloudflare/zones" -> "dev-cloudflare-zones"
  relative_path   = path_relative_to_include()
  path_parts      = split("/", local.relative_path)
  workspace_parts = slice(local.path_parts, 1, length(local.path_parts))
  workspace_name  = join("-", local.workspace_parts)
}

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
