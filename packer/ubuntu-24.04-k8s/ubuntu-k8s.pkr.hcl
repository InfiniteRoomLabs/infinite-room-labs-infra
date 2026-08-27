# Gold master: Ubuntu 24.04 LTS for homelab k3s NODES (KVM/libvirt guests).
#
# Same builder, identity-wipe, and version-stamping contract as
# ../ubuntu-24.04/. Differences are deliberate and listed below; everything
# else should stay in step with the base template.
#
#   1. NO unattended upgrades. A cluster node must not reboot or swap a
#      kernel/container-runtime package on its own schedule -- upgrades are
#      an operator action taken with the workload drained. Done thoroughly:
#      the package is purged, the apt-daily timers AND their services are
#      masked, and APT::Periodic is zeroed in a dropin. Masking one unit is
#      not enough: the timers re-arm the services, and the services run
#      regardless of the timers if something else pulls them in.
#   2. nfs-common installed. Cheap, and likely wanted whichever way the
#      cluster storage decision lands.
#   3. open-iscsi deliberately NOT installed. Installing it generates
#      /etc/iscsi/initiatorname.iscsi at package-configure time, which every
#      clone of this image would then SHARE. A duplicated initiator IQN is
#      both a correctness hazard (two nodes claiming one initiator identity)
#      and an access-control one (IQN-based ACLs stop distinguishing nodes).
#      If iSCSI is ever chosen, Ansible installs it per-VM so each node mints
#      its own IQN. A cleanup-phase assertion below fails the build if the
#      file exists in the artifact.
#   4. No k3s pre-download. ansible/playbooks/k3s.yml uses the presence of
#      /usr/local/bin/k3s as its install sentinel, so a pre-baked binary
#      would skip the install and then fail on the missing service unit.
#      Node software install stays Ansible's job.
#
# Build (from repo root):
#   cd packer/ubuntu-24.04-k8s
#   packer init . && packer build -var "image_version=1.0.0" .
#
# Output: output/ubuntu-24.04-k8s-golden-v<version>.qcow2
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

# Pinned upstream base image -- see ../ubuntu-24.04/ubuntu.pkr.hcl for the
# rationale and the bump procedure. Keep both variants on the same serial
# unless there is a reason not to.
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

source "qemu" "ubuntu-k8s" {
  iso_url      = var.base_image_url
  iso_checksum = var.base_image_checksum
  disk_image   = true

  vm_name          = "ubuntu-24.04-k8s-golden-v${var.image_version}.qcow2"
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
  sources = ["source.qemu.ubuntu-k8s"]

  provisioner "shell" {
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "cloud-init status --wait || true",

      "export DEBIAN_FRONTEND=noninteractive",
      "apt-get update",
      "apt-get -y upgrade",
      # No unattended-upgrades here (the base gold master installs it), and
      # nfs-common added. open-iscsi is deliberately absent -- see the header.
      "apt-get -y install qemu-guest-agent curl jq ca-certificates gnupg lsb-release python3 nfs-common",

      # ---- Disable automatic apt activity, all three mechanisms --------
      # The cloud image ships unattended-upgrades enabled. Purge it, mask the
      # timers AND the services they start (a masked timer still leaves the
      # service startable by anything else), and zero the APT::Periodic knobs
      # so apt.systemd.daily is a no-op even if a unit is somehow unmasked.
      "apt-get -y purge unattended-upgrades || true",
      "systemctl disable --now apt-daily.timer apt-daily-upgrade.timer || true",
      "systemctl mask apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service",
      "printf 'APT::Periodic::Enable \"0\";\\nAPT::Periodic::Update-Package-Lists \"0\";\\nAPT::Periodic::Download-Upgradeable-Packages \"0\";\\nAPT::Periodic::Unattended-Upgrade \"0\";\\nAPT::Periodic::AutocleanInterval \"0\";\\n' > /etc/apt/apt.conf.d/99-irl-no-auto",

      # Tailscale: installed, NOT joined. vms.yml supplies a single-use authkey
      # via the per-VM cloud-init seed.
      "curl -fsSL https://tailscale.com/install.sh | sh",
      "systemctl enable qemu-guest-agent tailscaled",

      # Version stamp for auditing running VMs against their source image.
      "printf 'image: ubuntu-24.04-k8s-golden\\nversion: %s\\nbuilt: %s\\n' '${var.image_version}' \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" > /etc/irl-golden-image",

      # Golden-image cleanup: unique identity must regenerate per clone.
      "apt-get -y autoremove --purge",
      "apt-get clean",
      "rm -f /etc/ssh/ssh_host_*",
      "truncate -s 0 /etc/machine-id",
      "rm -f /var/lib/dbus/machine-id",
      "ln -s /etc/machine-id /var/lib/dbus/machine-id",
    ]
  }

  # Cleanup-phase assertions. These run in the artifact, after the identity
  # wipe, and fail the build rather than shipping a broken gold master.
  provisioner "shell" {
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "set -e",

      # A baked initiator IQN would be shared by every clone -- see the header.
      "if [ -e /etc/iscsi/initiatorname.iscsi ]; then echo 'FAIL: /etc/iscsi/initiatorname.iscsi exists; every clone would share this IQN' >&2; exit 1; fi",

      # Automatic apt activity must be off by all three mechanisms.
      "if dpkg-query -W -f='$${Status}' unattended-upgrades 2>/dev/null | grep -q '^install ok installed$'; then echo 'FAIL: unattended-upgrades is still installed' >&2; exit 1; fi",
      "for u in apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service; do if [ \"$(systemctl is-enabled $u 2>/dev/null || true)\" != masked ]; then echo \"FAIL: $u is not masked\" >&2; exit 1; fi; done",
      "test -f /etc/apt/apt.conf.d/99-irl-no-auto",

      # Identity must be blank so every clone regenerates it.
      "test ! -s /etc/machine-id",
      "test -z \"$(ls /etc/ssh/ssh_host_* 2>/dev/null)\"",

      "echo 'k8s-node gold master assertions passed'",
    ]
  }
}
