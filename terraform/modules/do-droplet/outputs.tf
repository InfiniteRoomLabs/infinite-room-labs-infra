# terraform/modules/do-droplet/outputs.tf
# ==========================================

output "droplet_id" {
  description = "ID of the droplet."
  value       = digitalocean_droplet.this.id
}

output "public_ip" {
  description = "Public IPv4 address of the droplet."
  value       = digitalocean_droplet.this.ipv4_address
}

output "private_ip" {
  description = "Private IPv4 address within the VPC."
  value       = digitalocean_droplet.this.ipv4_address_private
}

output "droplet_urn" {
  description = "URN of the droplet."
  value       = digitalocean_droplet.this.urn
}

output "vpc_id" {
  description = "ID of the VPC."
  value       = digitalocean_vpc.this.id
}

output "status" {
  description = "Current status of the droplet."
  value       = digitalocean_droplet.this.status
}
