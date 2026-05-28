# Enable one or more Google Cloud API services for a project.
# Enabling an API has no cost. Requires the Service Usage API to already be
# enabled on the project (it is, by default, on any project used via gcloud).

resource "google_project_service" "this" {
  for_each = toset(var.services)

  project = var.project
  service = each.value

  disable_on_destroy = var.disable_on_destroy
}
