terraform {
  required_providers {
    tfe = {
      source  = "hashicorp/tfe"
      version = "~> 0.62"
    }
  }
}

resource "tfe_workspace" "this" {
  name           = var.workspace_name
  organization   = var.organization
  execution_mode = var.execution_mode
}
