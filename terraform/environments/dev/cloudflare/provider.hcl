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
