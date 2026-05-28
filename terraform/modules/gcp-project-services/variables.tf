variable "project" {
  type        = string
  description = "GCP project ID in which to enable the services."
}

variable "services" {
  type        = list(string)
  description = "Google API services to enable (e.g. [\"gmail.googleapis.com\"])."
}

variable "disable_on_destroy" {
  type        = bool
  default     = false
  description = <<-EOT
    If true, disable the API when this resource is destroyed. Defaults to false
    so tearing down Terraform never silently disables an API another tool relies
    on -- enabling an API is free and idempotent.
  EOT
}
