resource "cloudflare_pages_project" "this" {
  account_id        = var.account_id
  name              = var.project_name
  production_branch = var.production_branch

  build_config = {
    build_caching   = var.build_caching
    build_command   = var.build_command
    destination_dir = var.build_output_dir
    root_dir        = var.root_dir
  }

  # NOTE: The GitHub source connection must be configured manually via the
  # Cloudflare dashboard after the project is created. Terraform manages the
  # project shell, custom domains, and DNS records only.
  # See: https://developers.cloudflare.com/pages/get-started/git-integration/
}

resource "cloudflare_pages_domain" "this" {
  for_each = toset(var.custom_domains)

  account_id   = var.account_id
  project_name = cloudflare_pages_project.this.name
  name         = each.value
}

resource "cloudflare_dns_record" "pages_cname" {
  for_each = var.zone_id != "" ? toset(var.custom_domains) : toset([])

  zone_id = var.zone_id
  name    = each.value
  type    = "CNAME"
  content = cloudflare_pages_project.this.subdomain
  ttl     = 1
  proxied = true
  comment = "Managed by Terraform - Pages project: ${var.project_name}"
}
