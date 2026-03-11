output "project_url" {
  value       = "https://${cloudflare_pages_project.this.subdomain}"
  description = "Default pages.dev URL for the project"
}

output "subdomain" {
  value       = cloudflare_pages_project.this.subdomain
  description = "The pages.dev subdomain assigned to the project"
  sensitive   = true
}

output "custom_domain_statuses" {
  value = {
    for domain, pd in cloudflare_pages_domain.this : domain => pd.status
  }
  description = "Map of custom domain to activation status"
}
