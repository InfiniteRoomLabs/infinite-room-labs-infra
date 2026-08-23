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

  # Email Routing forward target. Personal mailbox -> never hardcoded (public
  # repo). Injected by fnox (IRL_EMAIL_ROUTING_DESTINATION) under with-secrets.sh.
  email_routing_destination = get_env("IRL_EMAIL_ROUTING_DESTINATION", "")

  # ── DNS records for infiniteroomlabs.com (email) ───────────────────
  email_dns_records = [
    # SendGrid link branding
    { name = "url1041",       type = "CNAME", content = "sendgrid.net" },
    { name = "61558306",      type = "CNAME", content = "sendgrid.net" },
    { name = "em1988",        type = "CNAME", content = "u61558306.wl057.sendgrid.net" },

    # SendGrid domain auth
    { name = "url45",         type = "CNAME", content = "sendgrid.net" },
    { name = "em1794",        type = "CNAME", content = "u61558306.wl057.sendgrid.net" },

    # DKIM/DMARC (shared by both SendGrid setups). rua= collects our own
    # aggregate reports into the same mailbox as client reports.
    { name = "s1._domainkey", type = "CNAME", content = "s1.domainkey.u61558306.wl057.sendgrid.net" },
    { name = "s2._domainkey", type = "CNAME", content = "s2.domainkey.u61558306.wl057.sendgrid.net" },
    { name = "_dmarc",        type = "TXT",   content = "v=DMARC1; p=none; rua=mailto:clients-dmarc@infiniteroomlabs.com" },

    # DMARC client reporting (RFC 7489 section 7.1): authorizes any external
    # domain to send its aggregate reports to clients-dmarc@infiniteroomlabs.com.
    # See docs/dmarc-client-reporting.md.
    { name = "*._report._dmarc", type = "TXT", content = "v=DMARC1" },
  ]
}
