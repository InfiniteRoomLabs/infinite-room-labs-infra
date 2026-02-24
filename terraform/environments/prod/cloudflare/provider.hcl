# Cloudflare provider configuration
# Auth via CLOUDFLARE_API_TOKEN environment variable (no config needed)

generate "cloudflare_provider" {
  path      = "provider-cloudflare.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "cloudflare" {
      # API token sourced from CLOUDFLARE_API_TOKEN env var automatically
    }
  EOF
}
