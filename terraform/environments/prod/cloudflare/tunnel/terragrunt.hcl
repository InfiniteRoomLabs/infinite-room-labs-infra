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
  source = "${get_repo_root()}/terraform/modules//cloudflare-tunnel"
}

inputs = {
  account_id = local.env_config.locals.cloudflare_account_id
  zone_id    = dependency.prod_zones.outputs.zone_ids["infiniteroomlabs.com"]

  tunnel_name = "irl-jobops"
  hostname    = "jops.infiniteroomlabs.com"
  app_name    = "JobOps"

  # cloudflared sidecar reaches the app over pod-localhost (no in-cluster Service).
  app_service = "http://localhost:3001"

  # MCP portal route (codifies the rule the dashboard MCP Server setup created).
  mcp_hostname = "jops-mcp.infiniteroomlabs.com"

  # Single operator allowed through Access.
  operator_email = "wes.gilleland@gmail.com"

  # 1 month (Access max). Matches the dashboard-managed MCP portal + MCP server
  # apps (set via API 2026-08-07) -- the claude.ai connector's OAuth session
  # follows the portal's Access session, so 24h anywhere = daily re-auth.
  session_duration = "730h"

  # Provider auth: bootstrap token from the global tokens dependency, falling back
  # to CLOUDFLARE_API_TOKEN via the generated provider (see cloudflare/provider.hcl).
  bootstrap_api_token = dependency.bootstrap_tokens.outputs.api_token
}
