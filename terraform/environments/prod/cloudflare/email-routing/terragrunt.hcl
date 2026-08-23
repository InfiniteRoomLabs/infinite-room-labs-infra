include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "provider" {
  path   = find_in_parent_folders("provider.hcl")
  expose = true
}

locals {
  env_config  = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  destination = local.env_config.locals.email_routing_destination
}

dependency "bootstrap_tokens" {
  config_path = "${get_repo_root()}/terraform/environments/global/cloudflare/tokens"

  mock_outputs = {
    api_token = ""
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "prod_zones" {
  config_path = "${get_repo_root()}/terraform/environments/prod/cloudflare/zones"

  mock_outputs = {
    zone_ids = {
      "infiniteroomlabs.com" = "mock-zone-id"
    }
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

terraform {
  source = "${get_repo_root()}/terraform/modules//cloudflare-email-routing"
}

# Dashboard-created state was imported 2026-08-22 (destination address, four
# forward rules, catch-all). Values below mirror live config exactly --
# dashboard edits from here on will show as drift. Rule names are the
# dashboard's auto-generated ones; changing them is a real (harmless) update.
inputs = {
  zone_id           = dependency.prod_zones.outputs.zone_ids["infiniteroomlabs.com"]
  account_id        = local.env_config.locals.cloudflare_account_id
  destination_email = local.destination

  rules = [
    { custom_address = "hello@infiniteroomlabs.com",   destination = local.destination, name = "" },
    { custom_address = "admin@infiniteroomlabs.com",   destination = local.destination, name = "Rule created at 2026-03-21T21:14:34.223Z" },
    { custom_address = "contact@infiniteroomlabs.com", destination = local.destination, name = "Rule created at 2026-03-21T21:14:10.427Z" },
    { custom_address = "wes@infiniteroomlabs.com",     destination = local.destination, name = "Rule created at 2026-02-12T21:49:54.452Z" },
    # Client DMARC aggregate reports (see docs/dmarc-client-reporting.md).
    { custom_address = "clients-dmarc@infiniteroomlabs.com", destination = local.destination, name = "clients-dmarc: client DMARC aggregate reports" },
  ]

  # Live catch-all is a disabled drop rule (Cloudflare default).
  catch_all = {
    name        = ""
    enabled     = false
    action_type = "drop"
  }

  bootstrap_api_token = dependency.bootstrap_tokens.outputs.api_token
}
