output "repository_ids" {
  value = {
    for name, repo in docker_hub_repository.this : name => repo.id
  }
  description = "Map of repository name to Docker Hub ID (namespace/name)"
}
