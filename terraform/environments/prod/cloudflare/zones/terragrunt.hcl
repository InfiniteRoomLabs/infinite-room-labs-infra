include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "provider" {
  path   = find_in_parent_folders("provider.hcl")
  expose = true
}

locals {
  env_config = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

terraform {
  source = "${get_repo_root()}/terraform/modules//cloudflare-zone"
}

inputs = {
  account_id = local.env_config.locals.cloudflare_account_id
  domains    = local.env_config.locals.domains
}
