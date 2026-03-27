locals {
  environment = "prod"

  # Domains to onboard to Cloudflare in the prod environment.
  # Add domains here to create Cloudflare zones and update Porkbun nameservers.
  domains = [
    "infiniteroomlabs.com",
    "infiniteroomlabs.cloud",
  ]

  # Sourced from CLOUDFLARE_ACCOUNT_ID environment variable.
  # Set this before running terragrunt.
  cloudflare_account_id = get_env("CLOUDFLARE_ACCOUNT_ID", "")

  # ── DNS records for infiniteroomlabs.com ──────────────────────────
  # SendGrid link branding
  sendgrid_dns_records = [
    { name = "url1041",       type = "CNAME", content = "sendgrid.net" },
    { name = "61558306",      type = "CNAME", content = "sendgrid.net" },
    { name = "em1988",        type = "CNAME", content = "u61558306.wl057.sendgrid.net" },
    # SendGrid domain authentication
    { name = "url45",         type = "CNAME", content = "sendgrid.net" },
    { name = "em1794",        type = "CNAME", content = "u61558306.wl057.sendgrid.net" },
    # DKIM + DMARC (shared by both)
    { name = "s1._domainkey", type = "CNAME", content = "s1.domainkey.u61558306.wl057.sendgrid.net" },
    { name = "s2._domainkey", type = "CNAME", content = "s2.domainkey.u61558306.wl057.sendgrid.net" },
    { name = "_dmarc",        type = "TXT",   content = "v=DMARC1; p=none;" },
  ]
}
