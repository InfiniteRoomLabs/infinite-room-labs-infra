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

dependency "cloudflare_zones" {
  config_path = "../../cloudflare/zones"

  # Mock outputs for `terragrunt validate` and `terragrunt plan` before zones exist
  mock_outputs = {
    nameservers_map = {}
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

terraform {
  source = "${get_repo_root()}/terraform/modules//porkbun-nameservers"
}

inputs = {
  domain_nameservers = {
    for domain, nameservers in dependency.cloudflare_zones.outputs.nameservers_map : domain => {
      nameservers = toset(nameservers)
    }
  }
}
