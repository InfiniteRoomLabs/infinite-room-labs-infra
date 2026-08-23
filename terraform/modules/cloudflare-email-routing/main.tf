# Email Routing for one zone. No provider/required_providers here: root.hcl pins
# the provider and prod/cloudflare/provider.hcl generates the provider block +
# bootstrap_api_token variable into this module at runtime.

# IMPORT ONLY. A create here fires Cloudflare's verification-email loop.
# Acceptance rule for this module: a plan must never show this as an add.
resource "cloudflare_email_routing_address" "destination" {
  account_id = var.account_id
  email      = var.destination_email

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_email_routing_rule" "this" {
  for_each = { for r in var.rules : r.custom_address => r }

  zone_id  = var.zone_id
  name     = each.value.name
  enabled  = each.value.enabled
  priority = each.value.priority

  matchers = [{
    type  = "literal"
    field = "to"
    value = each.key
  }]

  actions = [{
    type  = "forward"
    value = [each.value.destination]
  }]
}

resource "cloudflare_email_routing_catch_all" "this" {
  zone_id = var.zone_id
  name    = var.catch_all.name
  enabled = var.catch_all.enabled

  matchers = [{ type = "all" }]

  actions = [{
    type  = var.catch_all.action_type
    value = var.catch_all.action_value
  }]
}
