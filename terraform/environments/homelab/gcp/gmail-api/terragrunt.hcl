# Enable the Gmail API for the gmail-ai-broker tool.
#
# This is the ONLY GCP resource the gmail-ai-broker needs and it is FREE.
# The OAuth Desktop client + consent-screen publish is a Console-manual step
# (no google-provider resource creates a Gmail user-consent installed-app
# client -- verified against hashicorp/google 7.x). See gmail-ai-broker README.

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
  source = "${get_repo_root()}/terraform/modules//gcp-project-services"
}

inputs = {
  # Consumed by the generated google provider (provider.hcl).
  gcp_project_id = local.env_config.locals.gcp_project_id

  # Consumed by the gcp-project-services module.
  project  = local.env_config.locals.gcp_project_id
  services = ["gmail.googleapis.com"]
}
