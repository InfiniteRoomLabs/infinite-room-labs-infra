# TFC Workspace Bootstrap
# This resource group uses LOCAL state (not TFC) to avoid chicken-and-egg.
# Apply this FIRST before any other resource group.

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

    provider "tfe" {}

    variable "organization" {
      type = string
    }

    variable "workspaces" {
      type = map(object({
        execution_mode = optional(string, "local")
      }))
    }

    resource "tfe_workspace" "this" {
      for_each     = var.workspaces
      name         = each.key
      organization = var.organization
    }

    resource "tfe_workspace_settings" "this" {
      for_each       = var.workspaces
      workspace_id   = tfe_workspace.this[each.key].id
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
    "dev-cloudflare-zones"     = {}
    "dev-porkbun-nameservers"  = {}
    "prod-cloudflare-zones"    = {}
    "prod-porkbun-nameservers" = {}
  }
}
