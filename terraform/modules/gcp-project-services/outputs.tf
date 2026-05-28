output "enabled_services" {
  description = "The set of API services enabled by this module."
  value       = [for s in google_project_service.this : s.service]
}
