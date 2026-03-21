include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "provider" {
  path   = find_in_parent_folders("provider.hcl")
  expose = true
}

locals {
  env_config = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

dependency "bootstrap_tokens" {
  config_path = "${get_repo_root()}/terraform/environments/global/cloudflare/tokens"

  mock_outputs = {
    api_token = ""
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

# Look up the zone ID for infiniteroomlabs.cloud from the prod zones
dependency "prod_zones" {
  config_path = "${get_repo_root()}/terraform/environments/prod/cloudflare/zones"

  mock_outputs = {
    zone_ids = {
      "infiniteroomlabs.cloud" = "mock-zone-id"
    }
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

terraform {
  source = "${get_repo_root()}/terraform/modules//cloudflare-dns-records"
}

inputs = {
  zone_id             = dependency.prod_zones.outputs.zone_ids[local.env_config.locals.cloudflare_domain]
  records             = local.env_config.locals.homelab_dns_records
  bootstrap_api_token = dependency.bootstrap_tokens.outputs.api_token
}
