# Zone-level WAF custom ruleset that blocks every HTTP request to the given
# hostnames. Cloudflare allows exactly one ruleset per zone in the
# http_request_firewall_custom phase, so this module owns that phase for the zone.
resource "cloudflare_ruleset" "this" {
  zone_id     = var.zone_id
  name        = var.name
  description = var.description
  kind        = "zone"
  phase       = "http_request_firewall_custom"

  rules = [{
    action      = "block"
    description = var.description
    enabled     = true
    expression  = "(http.host in {${join(" ", [for h in var.hostnames : format("%q", h)])}})"
  }]
}
