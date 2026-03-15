# Docker Hub provider configuration
# Auth via DOCKER_USERNAME and DOCKER_PASSWORD env vars (PAT with Read/Write/Delete scope)

generate "dockerhub_provider" {
  path      = "providers.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    terraform {
      required_version = ">= 1.5"
      required_providers {
        docker = {
          source  = "docker/docker"
          version = "~> 0.5"
        }
      }
    }

    provider "docker" {}
  EOF
}
