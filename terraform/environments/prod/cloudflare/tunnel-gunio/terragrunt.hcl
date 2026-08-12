# Cloudflare Tunnel + Access for gunio-mcp (the unofficial gun.io MCP server),
# public at https://gunio-mcp.infiniteroomlabs.com/mcp. Mirrors the jobops
# tunnel/ leaf; same module, second instance. `{name}-mcp.infiniteroomlabs.com`
# is the naming convention for future exposed MCP servers (JobOps' jops-mcp.
# already follows it): FIRST-level labels ride the free Universal SSL cert --
# a `*.mcp.` hierarchy would need paid ACM/Total TLS for edge TLS.

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

  tunnel_name     = "irl-gunio"
  hostname        = "gunio-mcp.infiniteroomlabs.com"
  dns_record_name = "gunio-mcp"
  app_name        = "gunio MCP"

  # cloudflared sidecar reaches gunio-mcp (--serve, bound to 127.0.0.1:8000)
  # over pod-localhost (no in-cluster Service).
  app_service = "http://localhost:8000"

  # No separate MCP-portal hostname: unlike JobOps (app on the main hostname,
  # MCP portal on a second one), this hostname IS the MCP endpoint. The
  # dashboard MCP Server entry points at https://gunio-mcp.infiniteroomlabs.com/mcp.
  mcp_hostname = null

  # Single operator allowed through Access (same as the jobops leaf).
  operator_email = "wes.gilleland@gmail.com"

  # HomeOauth (Google, dashboard-managed IdP) alongside the module's OTP --
  # same IdP id as the jobops leaf. The module creates a second OTP IdP for
  # this app (JobOps precedent; Access IdPs are cheap and per-app OTP keeps
  # the leaves independent).
  extra_idp_ids = ["8edd7e06-6a95-42de-bcdf-7fc9e77f0b3f"]

  # 1 month (Access max), matching the jobops leaf -- the claude.ai
  # connector's OAuth session follows the Access session.
  session_duration = "730h"

  # Connector-token storage DIVERGES from the module docs for this instance:
  # the module comments say Bitwarden (true for JobOps), but gunio-mcp is the
  # first Vault + ESO workload -- its token lives at Vault
  # irl/gunio-mcp/cloudflared (key `token`), synced into k8s Secret
  # gunio-cloudflared-token by an ExternalSecret. The read_connector_token
  # bootstrap flow is unchanged: flip to true, apply,
  # `terraform output -raw connector_token | vault kv put irl/gunio-mcp/cloudflared token=-`,
  # flip back to false, re-apply (purges it from state).

  # Provider auth: bootstrap token from the global tokens dependency, falling back
  # to CLOUDFLARE_API_TOKEN via the generated provider (see cloudflare/provider.hcl).
  bootstrap_api_token = dependency.bootstrap_tokens.outputs.api_token
}
