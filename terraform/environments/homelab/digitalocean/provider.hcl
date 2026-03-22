# DigitalOcean provider configuration for homelab environment.
# Token from DIGITALOCEAN_TOKEN environment variable.

generate "provider-digitalocean" {
  path      = "provider-digitalocean.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "digitalocean" {
      token = var.do_token
    }

    variable "do_token" {
      type        = string
      description = "DigitalOcean API token."
      sensitive   = true
      default     = ""
    }
  EOF
}
