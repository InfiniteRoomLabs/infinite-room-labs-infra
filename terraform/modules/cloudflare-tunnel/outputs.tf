output "tunnel_id" {
  value       = cloudflare_zero_trust_tunnel_cloudflared.this.id
  description = "UUID of the cloudflared tunnel."
}

output "tunnel_cname" {
  value       = cloudflare_dns_record.tunnel.content
  description = "The <tunnel-id>.cfargotunnel.com target the proxied CNAME points at."
}

output "hostname" {
  value       = var.hostname
  description = "Public hostname fronted by the tunnel + Access."
}

output "access_application_id" {
  value       = cloudflare_zero_trust_access_application.this.id
  description = "UUID of the Cloudflare Access application."
}

output "access_application_aud" {
  value       = cloudflare_zero_trust_access_application.this.aud
  description = "Audience (AUD) tag of the Access application, for JWT validation."
}

output "access_policy_id" {
  value       = cloudflare_zero_trust_access_policy.operator.id
  description = "UUID of the operator allow policy."
}

output "identity_provider_id" {
  value       = cloudflare_zero_trust_access_identity_provider.otp.id
  description = "UUID of the one-time PIN identity provider."
}

# ─────────────────────────────────────────────────────────────────────────────
# Connector token — OUT-OF-BAND, NOT a normal state-persisted output.
#
# The cloudflared connector token is a long-lived credential for the tunnel
# sidecar. It is deliberately NOT applied from Terraform state: it is retrieved
# out of band (via the Cloudflare dashboard/API or `cloudflared`) and stored in
# Bitwarden, then injected into the JobOps pod's cloudflared sidecar as a
# Kubernetes Secret (never committed, never sourced from this state).
#
# By default var.read_connector_token = false, so the token data source has
# count = 0 and this output is null — nothing sensitive lands in state. The
# output is marked sensitive so that even during a one-shot bootstrap read the
# value is redacted from CLI/plan output; retrieve it with:
#
#   terraform output -raw connector_token
#
# and paste it straight into Bitwarden. Then set read_connector_token back to
# false and re-apply to purge the token from state.
# ─────────────────────────────────────────────────────────────────────────────
output "connector_token" {
  value       = var.read_connector_token ? data.cloudflare_zero_trust_tunnel_cloudflared_token.this[0].token : null
  description = "Tunnel connector token. Null unless read_connector_token is temporarily enabled for an out-of-band bootstrap into Bitwarden."
  sensitive   = true
}
