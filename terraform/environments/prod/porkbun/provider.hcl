# Porkbun provider configuration
# Auth via PORKBUN_API_KEY and PORKBUN_SECRET_KEY environment variables

generate "porkbun_provider" {
  path      = "provider-porkbun.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "porkbun" {
      # API key and secret sourced from PORKBUN_API_KEY and
      # PORKBUN_SECRET_KEY env vars automatically
    }
  EOF
}
