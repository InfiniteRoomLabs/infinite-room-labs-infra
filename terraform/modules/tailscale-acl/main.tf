resource "tailscale_acl" "this" {
  acl = jsonencode({
    acls = var.acl_rules

    tagOwners = var.tag_owners

    autoApprovers = var.auto_approvers

    ssh = var.ssh_rules
  })
}
