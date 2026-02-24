resource "cloudflare_zone" "this" {
  for_each = toset(var.domains)

  account = {
    id = var.account_id
  }
  name = each.value
}
