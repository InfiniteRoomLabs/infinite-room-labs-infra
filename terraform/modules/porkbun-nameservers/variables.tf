variable "domain_nameservers" {
  type = map(object({
    nameservers = set(string)
  }))
  description = "Map of domain name to its target nameservers (from Cloudflare zone outputs)"
}
