# Takes the public IRL website offline at the Cloudflare edge.
#
# The site itself is a Worker deployed from the irl-website repo (wrangler
# custom domains on infiniteroomlabs.com + www), which this repo does not
# manage. Rather than touch that deploy, a zone WAF custom rule blocks every
# request to those two hostnames. Other hostnames on the zone (tunnels, MCP
# endpoints) and email routing are unaffected.
#
# To bring the site back: delete this leaf (`terragrunt destroy`, then remove
# the directory). Leaving the Worker deployed keeps the restore a one-step op.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "provider" {
  path   = find_in_parent_folders("provider.hcl")
  expose = true
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
  source = "${get_repo_root()}/terraform/modules//cloudflare-waf-block-hosts"
}

inputs = {
  zone_id     = dependency.prod_zones.outputs.zone_ids["infiniteroomlabs.com"]
  hostnames   = ["infiniteroomlabs.com", "www.infiniteroomlabs.com"]
  name        = "website-offline"
  description = "IRL website offline: block all HTTP to the apex and www hosts"

  bootstrap_api_token = dependency.bootstrap_tokens.outputs.api_token
}
