output "zone_ids" {
  value = {
    for domain, zone in cloudflare_zone.this : domain => zone.id
  }
  description = "Map of domain name to Cloudflare zone ID"
}

output "nameservers_map" {
  value = {
    for domain, zone in cloudflare_zone.this : domain => zone.name_servers
  }
  description = "Map of domain name to assigned Cloudflare nameservers"
}
