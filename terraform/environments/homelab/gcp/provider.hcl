# Google Cloud provider configuration.
# Auth: Application Default Credentials (ADC) from `gcloud auth application-default
# login`. NO service-account key files, NO credentials in this repo.

generate "google_provider" {
  path      = "provider-google.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    variable "gcp_project_id" {
      type        = string
      description = "GCP project the resources belong to."
    }

    provider "google" {
      project = var.gcp_project_id
    }
  EOF
}
