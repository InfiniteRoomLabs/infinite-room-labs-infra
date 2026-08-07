# Cloudflare Tunnel + Access fronting the self-hosted JobOps deployment.
#
# Topology: cloudflared runs as a sidecar in the JobOps pod (there is NO in-cluster
# Service). The connector dials Cloudflare's edge outbound and forwards requests for
# var.hostname to the app over pod-localhost:3001. Access sits in front of the
# hostname and gates it to a single operator email via one-time PIN.

# ── Tunnel ────────────────────────────────────────────────────────────────────
# config_src = "cloudflare" -> ingress is managed remotely (dashboard/API/Terraform)
# via the cloudflared_config resource below, not by a local YAML on the origin.
resource "cloudflare_zero_trust_tunnel_cloudflared" "this" {
  account_id = var.account_id
  name       = var.tunnel_name
  config_src = "cloudflare"
}

# ── Tunnel ingress configuration (remotely managed) ───────────────────────────
# One hostname rule for JobOps, an optional MCP-portal route, then a terminal
# catch-all that 404s anything else. The MCP rule carries the route the
# Cloudflare MCP Server setup created out-of-band (2026-07): the portal
# reaches the app's MCP endpoint via mcp_hostname + path ^/mcp. Its DNS CNAME
# (jops-mcp -> tunnel) remains dashboard-managed, out of Terraform.
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "this" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.this.id
  source     = "cloudflare"

  config = {
    ingress = concat(
      [
        {
          hostname = var.hostname
          service  = var.app_service
        },
      ],
      var.mcp_hostname != null ? [
        {
          hostname = var.mcp_hostname
          path     = "^/mcp"
          service  = var.app_service
        },
      ] : [],
      # Terminal catch-all: required last rule, must have no hostname.
      [
        {
          service = "http_status:404"
        },
      ],
    )
  }
}

# ── Public DNS: proxied CNAME -> tunnel ───────────────────────────────────────
# Points the hostname at the tunnel's cfargotunnel.com target. Must be proxied
# (orange-cloud) for the tunnel + Access to work; proxied records use ttl = 1.
resource "cloudflare_dns_record" "tunnel" {
  zone_id = var.zone_id
  name    = var.dns_record_name
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.this.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

# ── Access identity provider: one-time PIN ────────────────────────────────────
# onetimepin needs no OAuth config; the config block is required but stays empty.
resource "cloudflare_zero_trust_access_identity_provider" "otp" {
  account_id = var.account_id
  name       = var.idp_name
  type       = "onetimepin"
  config     = {}
}

# ── Access policy: allow a single operator email ──────────────────────────────
resource "cloudflare_zero_trust_access_policy" "operator" {
  account_id = var.account_id
  name       = "${var.app_name} operator"
  decision   = "allow"

  include = [
    {
      email = {
        email = var.operator_email
      }
    },
  ]
}

# ── Access application: gate the hostname ─────────────────────────────────────
# Self-hosted app over the tunnel hostname. The module-owned OTP IdP is always
# allowed; extra_idp_ids admits dashboard-managed IdPs (e.g. Google) too.
# Auto-redirect only works with a single IdP -- with extras, Access shows a
# login-method picker instead. The email-based operator policy applies
# identically regardless of which IdP asserted the identity.
resource "cloudflare_zero_trust_access_application" "this" {
  account_id                = var.account_id
  name                      = var.app_name
  domain                    = var.hostname
  type                      = "self_hosted"
  session_duration          = var.session_duration
  allowed_idps              = concat([cloudflare_zero_trust_access_identity_provider.otp.id], var.extra_idp_ids)
  auto_redirect_to_identity = length(var.extra_idp_ids) == 0

  policies = [
    {
      id         = cloudflare_zero_trust_access_policy.operator.id
      precedence = 1
    },
    {
      id         = cloudflare_zero_trust_access_policy.mcp_service.id
      precedence = 2
    },
  ]
}

# ── Connector token (out-of-band; disabled by default) ────────────────────────
# See variables.tf / outputs.tf. Gated off so the token is never written to state
# during normal applies. When bootstrapping (read_connector_token = true), this
# reads the token so it can be copied into Bitwarden, then disabled again.
data "cloudflare_zero_trust_tunnel_cloudflared_token" "this" {
  count = var.read_connector_token ? 1 : 0

  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.this.id
}

# ── Access service token: headless MCP agents ────────────────────────────────
# MCP clients (Claude Code/Desktop, codex, opencode) cannot complete the OTP
# browser flow. They authenticate to Access with this service token via the
# CF-Access-Client-Id / CF-Access-Client-Secret headers; the app's own API-key
# auth still applies behind it (defense in depth, Authorization: Bearer <key>).
resource "cloudflare_zero_trust_access_service_token" "mcp_agents" {
  account_id = var.account_id
  name       = "${var.app_name} mcp agents"
  duration   = "8760h" # 1 year; rotate via terraform taint/apply
}

# non_identity: requests presenting the service token pass Access without an
# identity login. Browsers never send these headers, so the OTP flow is
# untouched for interactive use.
resource "cloudflare_zero_trust_access_policy" "mcp_service" {
  account_id = var.account_id
  name       = "${var.app_name} mcp service token"
  decision   = "non_identity"

  include = [
    {
      service_token = {
        token_id = cloudflare_zero_trust_access_service_token.mcp_agents.id
      }
    },
  ]
}
