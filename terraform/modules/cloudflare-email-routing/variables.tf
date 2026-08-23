variable "zone_id" {
  type        = string
  description = "Cloudflare zone ID whose Email Routing is managed here"
}

variable "account_id" {
  type        = string
  description = "Cloudflare account ID (destination addresses are account-scoped)"
}

variable "destination_email" {
  type        = string
  sensitive   = true
  description = "Verified destination address. IMPORT ONLY -- creating one triggers a verification-email loop."
}

variable "rules" {
  type = list(object({
    custom_address = string # full address, e.g. wes@example.com (matcher to/literal)
    destination    = string # forward target
    name           = string # mirror live value for imported rules
    priority       = optional(number, 0)
    enabled        = optional(bool, true)
  }))
  description = "Forwarding rules, keyed by custom_address"
}

variable "catch_all" {
  type = object({
    name         = string
    enabled      = optional(bool, true)
    action_type  = string                 # forward | drop | worker
    action_value = optional(list(string)) # forward targets; null for drop
  })
  description = "Catch-all rule, mirrored from live config"
}
