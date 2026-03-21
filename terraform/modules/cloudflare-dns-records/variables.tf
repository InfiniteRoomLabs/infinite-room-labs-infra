variable "zone_id" {
  type        = string
  description = "Cloudflare zone ID to create DNS records in"
}

variable "records" {
  type = list(object({
    name    = string
    type    = string
    content = string
    ttl     = optional(number, 1)
    proxied = optional(bool, false)
  }))
  description = "List of DNS records to create. TTL=1 means automatic. Proxied=false for Tailscale-only access."
}
