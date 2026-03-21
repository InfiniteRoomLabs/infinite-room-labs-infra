# Tailscale provider configuration
# Auth via TAILSCALE_API_KEY and TAILSCALE_TAILNET environment variables

generate "tailscale_provider" {
  path      = "provider-tailscale.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "tailscale" {
      # Reads TAILSCALE_API_KEY and TAILSCALE_TAILNET from environment
    }
  EOF
}
