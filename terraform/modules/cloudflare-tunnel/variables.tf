variable "account_id" {
  type        = string
  description = "Cloudflare account ID that owns the tunnel, Access application, policy, and IdP."
}

variable "zone_id" {
  type        = string
  description = "Cloudflare zone ID for the public hostname's zone (used for the proxied CNAME record)."
}

variable "tunnel_name" {
  type        = string
  description = "User-friendly name for the cloudflared tunnel (also the release identity)."
  default     = "irl-jobops"
}

variable "hostname" {
  type        = string
  description = "Public hostname routed through the tunnel to the app."
  default     = "jops.infiniteroomlabs.com"
}

variable "dns_record_name" {
  type        = string
  description = "Record name (relative to the zone) for the proxied tunnel CNAME. Should be the leftmost label of var.hostname."
  default     = "jops"
}

variable "app_service" {
  type        = string
  description = <<-EOT
    Origin the tunnel forwards matched requests to. These deployments have NO
    in-cluster Service: the cloudflared connector runs as a sidecar in the app pod
    and reaches the app over pod-localhost, e.g. http://localhost:3001.
  EOT
  default     = "http://localhost:3001"
}

variable "operator_email" {
  type        = string
  description = "The single operator email allowed through Cloudflare Access to reach the app."
}

variable "app_name" {
  type        = string
  description = "Display name for the Cloudflare Access application."
  default     = "JobOps"
}

variable "session_duration" {
  type        = string
  description = "How long Access tokens issued for the application remain valid (e.g. 24h, 2h45m)."
  default     = "24h"
}

variable "idp_name" {
  type        = string
  description = "Display name for the one-time PIN identity provider shown on the Access login page."
  default     = "One-time PIN"
}

# ─────────────────────────────────────────────────────────────────────────────
# Connector token handling.
#
# The cloudflared connector token authenticates the tunnel sidecar to Cloudflare.
# It is a long-lived credential and MUST NOT live in Terraform/TFC state during
# normal operation. Leave this false: the token is fetched OUT OF BAND and stored
# in Bitwarden (see outputs.tf). Flip to true ONLY for a one-shot bootstrap read,
# copy the value into Bitwarden, then set it back to false and re-apply so the
# token is purged from state again.
# ─────────────────────────────────────────────────────────────────────────────
variable "read_connector_token" {
  type        = bool
  description = "Temporarily read the connector token into state for a one-shot bootstrap. Keep false in steady state."
  default     = false
}

variable "mcp_hostname" {
  type        = string
  description = "Optional hostname routing path ^/mcp to the app for the Cloudflare MCP portal (e.g. jops-mcp.infiniteroomlabs.com). null omits the ingress rule."
  default     = null
}

variable "extra_idp_ids" {
  type        = list(string)
  description = "Additional Access identity provider IDs allowed on the app besides the module-owned OTP IdP. Non-empty disables auto-redirect (login-method picker shown)."
  default     = []
}

# Cloudflare allows exactly ONE onetimepin IdP per account (API error 12132
# conflict on a second create -- surfaced by the provider as the opaque
# "failed to make http request"). The first module instance creates it; every
# later instance must reference it instead.
variable "existing_otp_idp_id" {
  type        = string
  description = "ID of the account's existing One-time PIN IdP. When set, the module does not create its own OTP IdP and allows this one on the app instead."
  default     = null
}

variable "public_bypass_paths" {
  type        = list(string)
  description = "Paths on var.hostname exempted from Access via path-scoped Bypass apps (e.g. [\"cv/*\", \"health\"]). Wildcards match subpaths only, not the parent path. Empty list creates nothing."
  default     = []
}
