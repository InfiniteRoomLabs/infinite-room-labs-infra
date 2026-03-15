resource "docker_hub_repository" "this" {
  for_each = var.repositories

  namespace        = var.namespace
  name             = each.key
  description      = each.value.description
  full_description = try(each.value.full_description, null)
  private          = each.value.private
}
