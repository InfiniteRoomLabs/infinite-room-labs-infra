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
  iso_url      = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  iso_checksum = "file:https://cloud-images.ubuntu.com/noble/current/SHA256SUMS"
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
