# terraform/modules/do-droplet/variables.tf
# ============================================
# Variables for a DigitalOcean Droplet with VPC + firewall.

variable "name" {
  type        = string
  description = "Droplet hostname and display name."
}

variable "region" {
  type        = string
  description = "DigitalOcean region slug (e.g. nyc3, sfo3)."
  default     = "nyc3"
}

variable "size" {
  type        = string
  description = "Droplet size slug (e.g. s-4vcpu-8gb)."
  default     = "s-4vcpu-8gb"
}

variable "image" {
  type        = string
  description = "Droplet image slug or ID."
  default     = "ubuntu-24-04-x64"
}

variable "ssh_keys" {
  type        = list(string)
  description = "List of SSH key fingerprints or IDs to add to the droplet."
}

variable "vpc_name" {
  type        = string
  description = "Name for the VPC."
  default     = "irl-vpc"
}

variable "vpc_ip_range" {
  type        = string
  description = "IP range for the VPC."
  default     = "10.100.0.0/16"
}

variable "cloud_init_data" {
  type        = string
  description = "Cloud-init user data (raw YAML, not base64)."
  sensitive   = true
}

variable "tags" {
  type        = list(string)
  description = "Tags to apply to all resources."
  default     = ["managed-by:terraform", "project:irl"]
}

variable "project_name" {
  type        = string
  description = "DigitalOcean project name. Created if it doesn't exist."
  default     = "Infinite Room Labs"
}

variable "project_description" {
  type        = string
  description = "DigitalOcean project description."
  default     = "IRL k3s cluster"
}

variable "firewall_inbound_rules" {
  type = list(object({
    protocol         = string
    port_range       = string
    source_addresses = list(string)
  }))
  description = "Inbound firewall rules."
  default = [
    {
      protocol         = "tcp"
      port_range       = "22"
      source_addresses = ["0.0.0.0/0", "::/0"]
    },
    {
      protocol         = "udp"
      port_range       = "41641"
      source_addresses = ["0.0.0.0/0", "::/0"]
    },
    {
      protocol         = "icmp"
      port_range       = "0"
      source_addresses = ["0.0.0.0/0", "::/0"]
    },
  ]
}
