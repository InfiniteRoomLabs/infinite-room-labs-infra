# Tailscale Split DNS configuration.
# Routes *.lab.infiniteroomlabs.cloud and *.internal.infiniteroomlabs.cloud
# to the internal CoreDNS server on the homelab. Queries for these domains
# never fall back to public DNS (leak prevention).

generate "backend" {
  path      = "backend.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    terraform {
      backend "local" {}
    }
  EOF
}

include "provider" {
  path   = find_in_parent_folders("provider.hcl")
  expose = true
}

generate "versions" {
  path      = "versions.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    terraform {
      required_version = ">= 1.5"
      required_providers {
        tailscale = {
          source  = "tailscale/tailscale"
          version = "~> 0.18"
        }
      }
    }
  EOF
}

locals {
  # CoreDNS runs on the homelab k3s node, exposed via NodePort 30053
  coredns_ip = get_env("HOMELAB_TAILSCALE_IP", "100.86.213.22")
}

generate "main" {
  path      = "main.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    # Split DNS: route internal domains to homelab CoreDNS.
    # "Restrict to domain" is implicit -- Tailscale never falls back
    # to public DNS for split DNS domains.

    resource "tailscale_dns_split_nameservers" "lab" {
      domain      = "lab.infiniteroomlabs.cloud"
      nameservers = ["${local.coredns_ip}"]
    }

    resource "tailscale_dns_split_nameservers" "internal" {
      domain      = "internal.infiniteroomlabs.cloud"
      nameservers = ["${local.coredns_ip}"]
    }
  EOF
}
