variable "account_id" {
  type        = string
  description = "Cloudflare account ID"
}

variable "project_name" {
  type        = string
  description = "Name of the Cloudflare Pages project"
}

variable "production_branch" {
  type        = string
  description = "Git branch that triggers production deployments"
  default     = "main"
}

variable "build_command" {
  type        = string
  description = "Command to build the project (e.g., 'bun run build')"
}

variable "build_output_dir" {
  type        = string
  description = "Output directory of the build (e.g., 'dist')"
}

variable "repo_owner" {
  type        = string
  description = "GitHub organization or user that owns the repository"
}

variable "repo_name" {
  type        = string
  description = "GitHub repository name"
}

variable "custom_domains" {
  type        = list(string)
  description = "List of custom domains to bind to the Pages project"
  default     = []
}

variable "zone_id" {
  type        = string
  description = "Cloudflare zone ID for DNS record creation"
  default     = ""
}

variable "build_caching" {
  type        = bool
  description = "Enable build caching for the project"
  default     = true
}
