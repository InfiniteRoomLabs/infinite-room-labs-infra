resource "porkbun_domain_nameservers" "this" {
  for_each = var.domain_nameservers

  domain      = each.key
  nameservers = each.value.nameservers
}
