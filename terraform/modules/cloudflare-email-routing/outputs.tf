output "rule_ids" {
  value       = { for addr, r in cloudflare_email_routing_rule.this : addr => r.id }
  description = "Map of custom address to routing rule ID"
}

output "destination_address_id" {
  value       = cloudflare_email_routing_address.destination.id
  description = "Account-scoped destination address identifier"
}
