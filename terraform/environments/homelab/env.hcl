locals {
  environment = "homelab"

  # Cloudflare zone for homelab DNS records.
  # Records are created under lab.infiniteroomlabs.cloud.
  cloudflare_domain = "infiniteroomlabs.cloud"

  # Sourced from CLOUDFLARE_ACCOUNT_ID environment variable.
  cloudflare_account_id = get_env("CLOUDFLARE_ACCOUNT_ID", "")

  # Homelab service subdomains that need DNS records.
  # These point to the Tailscale IP of the homelab server.
  # The Tailscale IP must be set via HOMELAB_TAILSCALE_IP env var.
  homelab_tailscale_ip = get_env("HOMELAB_TAILSCALE_IP", "")

  homelab_dns_records = [
    { name = "git.lab",     type = "A", content = local.homelab_tailscale_ip, proxied = false },
    { name = "plane.lab",   type = "A", content = local.homelab_tailscale_ip, proxied = false },
    { name = "auth.lab",    type = "A", content = local.homelab_tailscale_ip, proxied = false },
    { name = "grafana.lab", type = "A", content = local.homelab_tailscale_ip, proxied = false },
    { name = "vault.lab",   type = "A", content = local.homelab_tailscale_ip, proxied = false },
    { name = "ci.lab",      type = "A", content = local.homelab_tailscale_ip, proxied = false },
    { name = "*.lab",       type = "A", content = local.homelab_tailscale_ip, proxied = false },
  ]
}
