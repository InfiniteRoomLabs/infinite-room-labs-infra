# Packer -- VM Gold Master Images

Builds versioned "gold master" qcow2 images for the homelab KVM/libvirt hypervisor. Design: `docs/plans/2026-07-23-homelab-vm-gold-master-design.md`. Provisioning runbook: `docs/runbooks/vm-provisioning.md`.

The image is **generic** -- no hostnames, no users beyond cloud-init defaults, no secrets. Per-VM identity (hostname, admin user, Tailscale join) is injected at provision time by `ansible/playbooks/vms.yml` via a NoCloud cloud-init seed.

## Layout

| Path | Purpose |
|------|---------|
| `ubuntu-24.04/ubuntu.pkr.hcl` | QEMU builder from the official noble cloud image; installs qemu-guest-agent, tailscale (unjoined), base tools; wipes machine identity + cloud-init state |
| `scripts/publish-image.sh` | scp the artifact to `homelab:/media/root/storage1/vms/images/` and update the `latest` symlink |

## Workflow

```bash
cd packer/ubuntu-24.04
packer init .
packer build -var "image_version=1.0.0" .          # laptop needs KVM (/dev/kvm)
../scripts/publish-image.sh output/ubuntu-24.04-golden-v1.0.0.qcow2
```

Then provision VMs: add an entry to `irl_vms` in `ansible/inventory/host_vars/homelab.yml` and run `uv run ansible-playbook playbooks/vms.yml` from `ansible/`.

## Debugging a build

Pass `-var headless=false` to get a QEMU window. The build logs in via a throwaway `packer` user that is force-deleted before the artifact is finalized.

## Versioning

`image_version` is stamped into the filename and `/etc/irl-golden-image` inside the image. Bump it every published build; never overwrite a published version (the `latest` symlink is the only mutable pointer).
