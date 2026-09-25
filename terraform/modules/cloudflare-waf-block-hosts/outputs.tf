output "ruleset_id" {
  value       = cloudflare_ruleset.this.id
  description = "ID of the zone custom-rules ruleset"
}
