variable "namespace" {
  type        = string
  description = "Docker Hub namespace (username or organization)"
}

variable "repositories" {
  type = map(object({
    description      = string
    full_description = optional(string)
    private          = bool
  }))
  description = "Map of repository name to configuration"
}
