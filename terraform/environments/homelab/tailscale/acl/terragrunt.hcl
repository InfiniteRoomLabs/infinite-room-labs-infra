include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "provider" {
  path   = find_in_parent_folders("provider.hcl")
  expose = true
}

terraform {
  source = "${get_repo_root()}/terraform/modules//tailscale-acl"
}

inputs = {
  acl_rules = [
    {
      action = "accept"
      src    = ["autogroup:member"]
      dst    = ["autogroup:member:*", "tag:server:*", "autogroup:internet:*"]
    },
    {
      action = "accept"
      src    = ["tag:server"]
      dst    = ["autogroup:member:*", "tag:server:*", "autogroup:internet:*"]
    },
  ]

  tag_owners = {
    "tag:server"      = ["autogroup:admin"]
    "tag:workstation" = ["autogroup:admin"]
  }

  auto_approvers = {
    exitNode = ["tag:server", "tag:workstation", "autogroup:member"]
  }

  ssh_rules = [
    {
      action = "accept"
      src    = ["autogroup:member"]
      dst    = ["tag:server"]
      users  = ["autogroup:nonroot"]
    },
  ]
}
