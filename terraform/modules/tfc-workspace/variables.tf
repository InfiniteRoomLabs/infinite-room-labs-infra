variable "organization" {
  type        = string
  description = "Terraform Cloud organization name"
}

variable "workspace_name" {
  type        = string
  description = "Name for the TFC workspace"
}

variable "execution_mode" {
  type        = string
  default     = "local"
  description = "TFC execution mode (local or remote)"
}
