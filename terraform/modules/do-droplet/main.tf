# terraform/modules/do-droplet/main.tf
# ======================================
# DigitalOcean Droplet with VPC and cloud firewall.

# ── VPC ───────────────────────────────────────────────────────────

resource "digitalocean_vpc" "this" {
  name     = var.vpc_name
  region   = var.region
  ip_range = var.vpc_ip_range
}

# ── Droplet ───────────────────────────────────────────────────────

resource "digitalocean_droplet" "this" {
  name      = var.name
  region    = var.region
  size      = var.size
  image     = var.image
  vpc_uuid  = digitalocean_vpc.this.id
  ssh_keys  = var.ssh_keys
  user_data = var.cloud_init_data
  tags      = var.tags

  # Enable monitoring agent
  monitoring = true

  # Graceful shutdown on destroy
  graceful_shutdown = true
}

# ── Cloud Firewall ────────────────────────────────────────────────

resource "digitalocean_firewall" "this" {
  name        = "${var.name}-fw"
  droplet_ids = [digitalocean_droplet.this.id]

  # Dynamic inbound rules from variable
  dynamic "inbound_rule" {
    for_each = var.firewall_inbound_rules
    content {
      protocol         = inbound_rule.value.protocol
      port_range       = inbound_rule.value.port_range
      source_addresses = inbound_rule.value.source_addresses
    }
  }

  # Allow all outbound (k3s needs image pulls, Tailscale, DNS, etc.)
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    port_range            = "0"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

# ── Project ───────────────────────────────────────────────────────

resource "digitalocean_project" "this" {
  name        = var.project_name
  description = var.project_description
  purpose     = "Service or API"
  environment = "Production"
}

resource "digitalocean_project_resources" "this" {
  project = digitalocean_project.this.id
  resources = [
    digitalocean_droplet.this.urn,
  ]
}
