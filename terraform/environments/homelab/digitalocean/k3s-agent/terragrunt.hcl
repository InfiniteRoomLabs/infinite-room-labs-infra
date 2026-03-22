# DigitalOcean k3s agent droplet.
# Joins the homelab k3s cluster over Tailscale.
#
# All secrets are read from Bitwarden at plan/apply time.
# No secrets in this file, env.hcl, or anywhere in the repo.

generate "backend" {
  path      = "backend.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    terraform {
      backend "local" {}
    }
  EOF
}

# TODO: Switch to root.hcl TFC backend once TFC token is refreshed.
# include "root" {
#   path   = find_in_parent_folders("root.hcl")
#   expose = true
# }

include "provider" {
  path   = find_in_parent_folders("provider.hcl")
  expose = true
}

# TODO: Enable once BW API client credentials are set up
# include "bitwarden" {
#   path   = find_in_parent_folders("bitwarden-provider.hcl")
#   expose = true
# }

locals {
  env_config = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

terraform {
  source = "${get_repo_root()}/terraform/modules//do-droplet"
}

# The DO droplet module doesn't know about Bitwarden.
# We use a wrapper module that reads BW data sources and passes
# values to the droplet module. This keeps the module reusable.
#
# For now, secrets are passed via env vars at apply time.
# The Bitwarden provider integration will be added as a
# data-source layer in a dedicated secrets module.
#
# Required env vars (sourced from ~/.secrets/ or bw-unlock):
#   DIGITALOCEAN_TOKEN
#   TAILSCALE_AUTH_KEY
#   K3S_NODE_TOKEN
#   BW_PASSWORD, BW_CLIENT_ID, BW_CLIENT_SECRET

inputs = {
  # Provider auth (env var DIGITALOCEAN_TOKEN)
  do_token = get_env("DIGITALOCEAN_TOKEN", "")

  # Droplet config (non-sensitive)
  name   = "irl-k3s-agent-01"
  region = "nyc3"
  size   = "s-4vcpu-8gb"
  image  = "ubuntu-24-04-x64"

  # SSH key fingerprint (env var, registered in DO console)
  ssh_keys = [get_env("DO_SSH_FINGERPRINT", "")]

  tags = ["managed-by:terraform", "project:irl", "role:k3s-agent"]

  # Cloud-init bootstrap
  cloud_init_data = templatefile(
    "${get_repo_root()}/terraform/modules/do-droplet/templates/cloud-init.yaml.tftpl",
    {
      admin_user         = "wes"
      admin_ssh_pubkey   = get_env("IRL_SSH_PUBKEY", "")
      tailscale_auth_key = get_env("TAILSCALE_AUTH_KEY", "")
      tailscale_hostname = "do-k3s-agent-01"
      k3s_server_url     = "https://${get_env("HOMELAB_TAILSCALE_IP", "")}:${local.env_config.locals.k3s_server_port}"
      k3s_node_token     = get_env("K3S_NODE_TOKEN", "")
      k3s_version        = local.env_config.locals.k3s_version
      timezone           = "UTC"
      k3s_node_labels = [
        "topology.kubernetes.io/region=us-east",
        "topology.kubernetes.io/zone=do-nyc3",
        "irl.dev/provider=digitalocean",
        "irl.dev/tier=compute",
        "irl.dev/instance-type=s-4vcpu-8gb",
        "irl.dev/storage=nvme",
        "irl.dev/network=tailscale",
        "irl.dev/cost=paid",
        "irl.dev/persistence=ephemeral",
        "irl.dev/gpu=none",
        "irl.dev/memory-class=standard",
      ]
      k3s_node_taints = [
        "irl.dev/cloud=digitalocean:NoSchedule",
      ]
    }
  )
}
