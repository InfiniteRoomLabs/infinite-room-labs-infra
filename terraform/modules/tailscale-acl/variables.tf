variable "acl_rules" {
  type = list(object({
    action = string
    src    = list(string)
    dst    = list(string)
  }))
  description = "Tailscale ACL rules defining which devices can access which destinations"
}

variable "tag_owners" {
  type        = map(list(string))
  default     = {}
  description = "Map of tag names to lists of users/groups that can assign the tag"
}

variable "auto_approvers" {
  type = object({
    routes   = optional(map(list(string)), {})
    exitNode = optional(map(list(string)), {})
  })
  default     = {}
  description = "Auto-approval rules for subnet routes and exit nodes"
}

variable "ssh_rules" {
  type = list(object({
    action = string
    src    = list(string)
    dst    = list(string)
    users  = list(string)
  }))
  default     = []
  description = "Tailscale SSH ACL rules"
}
