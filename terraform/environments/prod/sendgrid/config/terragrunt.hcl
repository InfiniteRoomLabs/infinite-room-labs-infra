# SendGrid config leaf
# Uses local state (not TFC) because SENDGRID_API_KEY is only available locally.
# Same pattern as global/cloudflare/tokens.

generate "providers" {
  path      = "providers.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    terraform {
      required_version = ">= 1.11"
      required_providers {
        sendgrid = {
          source  = "kenzo0107/sendgrid"
          version = "~> 2.7"
        }
      }
    }

    provider "sendgrid" {}
  EOF
}

terraform {
  source = "${get_repo_root()}/terraform/modules//sendgrid-config"
}

inputs = {
  domain     = "infiniteroomlabs.com"
  from_email = "no-reply@infiniteroomlabs.com"
  from_name  = "Infinite Room Labs"

  company_address = {
    address = "Infinite Room Labs"
    city    = "Remote"
    country = "US"
  }
}
