locals {
  environment = "prod"

  # Domains to onboard to Cloudflare in the prod environment.
  # Add domains here to create Cloudflare zones and update Porkbun nameservers.
  domains = [
    "infiniteroomlabs.com",
    "infiniteroomlabs.cloud",
  ]

  # Sourced from CLOUDFLARE_ACCOUNT_ID environment variable.
  # Set this before running terragrunt.
  cloudflare_account_id = get_env("CLOUDFLARE_ACCOUNT_ID", "")
}
