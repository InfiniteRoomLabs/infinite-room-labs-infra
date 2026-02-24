output "workspace_id" {
  value       = tfe_workspace.this.id
  description = "The ID of the created TFC workspace"
}

output "workspace_name" {
  value       = tfe_workspace.this.name
  description = "The name of the created TFC workspace"
}
