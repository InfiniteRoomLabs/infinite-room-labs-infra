# Gold master: Ubuntu 24.04 LTS server for homelab KVM/libvirt.
#
# Builds FROM the official Ubuntu cloud image (not ISO autoinstall) -- the image
# stays generic; per-VM identity (hostname, user, Tailscale) is injected later
# by ansible/playbooks/vms.yml via a NoCloud cloud-init seed.
#
# Build (from repo root):
#   cd packer/ubuntu-24.04
#   packer init . && packer build -var "image_version=1.0.0" .
#
# Output: output/ubuntu-24.04-golden-v<version>.qcow2
# Publish to the homelab: ../scripts/publish-image.sh <qcow2>

packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "~> 1"
    }
  }
}

variable "image_version" {
  type        = string
  default     = "0.0.0-dev"
  description = "Semver stamped into the output filename and /etc/irl-golden-image"
}

variable "headless" {
  type    = bool
  default = true
}

# The upstream base image is PINNED to a dated serial, not noble/current.
# `current` is a moving target: two builds of the same image_version would
# silently differ, and the checksum could not be verified ahead of time.
#
# To bump: pick a serial from https://cloud-images.ubuntu.com/releases/noble/,
# take its ubuntu-24.04-server-cloudimg-amd64.img line from that directory's
# SHA256SUMS, update BOTH vars together, and bump image_version. Changing one
# without the other fails the build at download time, which is the point.
variable "base_image_url" {
  type        = string
  default     = "https://cloud-images.ubuntu.com/releases/noble/release-20260814/ubuntu-24.04-server-cloudimg-amd64.img"
  description = "Pinned upstream Ubuntu cloud image (dated serial, never `current`)"
}

variable "base_image_checksum" {
  type        = string
  default     = "sha256:6e40c07ae715f744f84af0bec76415cc1987dd115b4b8de437818561f01a3733"
  description = "sha256 of base_image_url, from that serial directory's SHA256SUMS"
}

locals {
  # A throwaway build-only account. It is force-deleted in shutdown_command
  # before the artifact is finalized; it never exists in shipped images.
  build_user = "packer"
  build_pass = "packer-build-only"

  seed_user_data = <<-EOF
    #cloud-config
    users:
      - name: ${local.build_user}
        plain_text_passwd: ${local.build_pass}
        lock_passwd: false
        shell: /bin/bash
        sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_pwauth: true
  EOF
}

source "qemu" "ubuntu" {
  iso_url      = var.base_image_url
  iso_checksum = var.base_image_checksum
  disk_image   = true

  vm_name          = "ubuntu-24.04-golden-v${var.image_version}.qcow2"
  output_directory = "output"
  format           = "qcow2"
  disk_size        = "10G"

  accelerator = "kvm"
  cpus        = 2
  memory      = 2048
  headless    = var.headless

  # Temporary NoCloud seed so Packer can SSH into the stock cloud image.
  cd_label = "cidata"
  cd_content = {
    "meta-data" = ""
    "user-data" = local.seed_user_data
  }

  ssh_username = local.build_user
  ssh_password = local.build_pass
  ssh_timeout  = "10m"

  # Delete the build user (-f: even while logged in), wipe cloud-init state so
  # every clone re-runs first boot fresh, then power off.
  shutdown_command = "sudo sh -c 'userdel -rf ${local.build_user}; cloud-init clean --logs; shutdown -P now'"
}

build {
  sources = ["source.qemu.ubuntu"]

  provisioner "shell" {
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "cloud-init status --wait || true",

      "export DEBIAN_FRONTEND=noninteractive",
      "apt-get update",
      "apt-get -y upgrade",
      "apt-get -y install qemu-guest-agent curl jq ca-certificates gnupg lsb-release python3 unattended-upgrades",

      # Tailscale: installed, NOT joined. vms.yml supplies a single-use authkey
      # via the per-VM cloud-init seed.
      "curl -fsSL https://tailscale.com/install.sh | sh",
      "systemctl enable qemu-guest-agent tailscaled",

      # Version stamp for auditing running VMs against their source image.
      "printf 'image: ubuntu-24.04-golden\\nversion: %s\\nbuilt: %s\\n' '${var.image_version}' \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" > /etc/irl-golden-image",

      # Golden-image cleanup: unique identity must regenerate per clone.
      "apt-get -y autoremove --purge",
      "apt-get clean",
      "rm -f /etc/ssh/ssh_host_*",
      "truncate -s 0 /etc/machine-id",
      "rm -f /var/lib/dbus/machine-id",
      "ln -s /etc/machine-id /var/lib/dbus/machine-id",
    ]
  }
}
