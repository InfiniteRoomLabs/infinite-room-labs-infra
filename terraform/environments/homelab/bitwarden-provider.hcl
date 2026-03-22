# Bitwarden provider configuration for homelab environment.
# Reads secrets from the IRL Bitwarden vault via the embedded client.
#
# Required env vars:
#   BW_PASSWORD      -- Bitwarden master password
#   BW_CLIENT_ID     -- API client ID (Settings > Security > Keys)
#   BW_CLIENT_SECRET -- API client secret
#
# Secrets are organized under IRL/ folder tree in Bitwarden.
# Use data.bitwarden_item_login or data.bitwarden_item_secure_note
# to read them at plan/apply time.

generate "provider-bitwarden" {
  path      = "provider-bitwarden.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    terraform {
      required_providers {
        bitwarden = {
          source  = "maxlaverse/bitwarden"
          version = "~> 0.9"
        }
      }
    }

    provider "bitwarden" {
      email           = "wes.gilleland@gmail.com"
      master_password = var.bw_password
      client_id       = var.bw_client_id
      client_secret   = var.bw_client_secret
      server          = "https://vault.bitwarden.com"
    }

    variable "bw_password" {
      type        = string
      description = "Bitwarden master password."
      sensitive   = true
      default     = ""
    }

    variable "bw_client_id" {
      type        = string
      description = "Bitwarden API client ID."
      sensitive   = true
      default     = ""
    }

    variable "bw_client_secret" {
      type        = string
      description = "Bitwarden API client secret."
      sensitive   = true
      default     = ""
    }
  EOF
}
