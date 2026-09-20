variable "zone_id" {
  type        = string
  description = "Cloudflare zone ID the ruleset is attached to"
}

variable "hostnames" {
  type        = list(string)
  description = "Hostnames whose HTTP traffic is blocked at the edge"
}

variable "name" {
  type        = string
  default     = "block-hosts"
  description = "Ruleset name shown in the dashboard"
}

variable "description" {
  type        = string
  default     = "Block all HTTP traffic to the listed hostnames"
  description = "Ruleset and rule description"
}
