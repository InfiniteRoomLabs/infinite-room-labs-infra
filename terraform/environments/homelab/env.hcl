locals {
  environment = "homelab"

  # ── Non-sensitive config only ───────────────────────────────────
  # NO secrets, keys, tokens, fingerprints, or IPs here.
  # All sensitive values come from env vars at apply time,
  # sourced from ~/.secrets/ files or bw-unlock.
  # Bitwarden provider reads secrets at plan/apply via data sources.

  k3s_version     = "v1.31.4+k3s1"
  k3s_server_port = "6443"

  # ── Cloudflare (non-sensitive) ──────────────────────────────────
  cloudflare_domain = "infiniteroomlabs.cloud"

  # ── DNS records (IP content comes from env var at leaf level) ───
  homelab_dns_records = [
    { name = "git.lab",     type = "A", proxied = false },
    { name = "auth.lab",    type = "A", proxied = false },
    { name = "grafana.lab", type = "A", proxied = false },
    { name = "vault.lab",   type = "A", proxied = false },
    { name = "ci.lab",      type = "A", proxied = false },
    { name = "*.lab",       type = "A", proxied = false },
  ]
}
