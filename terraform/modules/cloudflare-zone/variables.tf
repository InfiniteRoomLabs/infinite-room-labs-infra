variable "account_id" {
  type        = string
  description = "Cloudflare account ID"
}

variable "domains" {
  type        = list(string)
  description = "List of domain names to create Cloudflare zones for"
}
