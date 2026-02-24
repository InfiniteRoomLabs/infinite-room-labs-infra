output "domain_ns_status" {
  value = {
    for domain, ns in porkbun_domain_nameservers.this : domain => ns.nameservers
  }
  description = "Map of domain name to configured nameservers (for verification)"
}
