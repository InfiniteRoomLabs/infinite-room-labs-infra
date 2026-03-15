include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "provider" {
  path   = find_in_parent_folders("provider.hcl")
  expose = true
}

terraform {
  source = "${get_repo_root()}/terraform/modules//dockerhub-repo"
}

inputs = {
  namespace = "deathnerd"

  repositories = {
    "claudesync-mcp" = {
      description      = "MCP server for programmatic access to claude.ai conversations"
      full_description = "ClaudeSync MCP Server -- Unofficial SDK wrapping the claude.ai web API. Exposes conversation listing, search, project docs, and artifact access as MCP tools. Part of the ClaudeSync project by Infinite Room Labs."
      private          = false
    }
  }
}
