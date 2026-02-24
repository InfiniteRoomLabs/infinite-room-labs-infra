locals {
  environment = "dev"

  # Domains to onboard to Cloudflare in the dev environment.
  # Add domains here to create Cloudflare zones and update Porkbun nameservers.
  domains = [
    "infiniteroomlabs.net",
    "infiniteroomlabs.dev",
  ]

  # Sourced from CLOUDFLARE_ACCOUNT_ID environment variable.
  # Set this before running terragrunt.
  cloudflare_account_id = get_env("CLOUDFLARE_ACCOUNT_ID", "")
}
