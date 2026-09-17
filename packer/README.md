# Packer -- VM Gold Master Images

Builds versioned "gold master" qcow2 images for the homelab KVM/libvirt hypervisor. Design: `docs/plans/2026-07-23-homelab-vm-gold-master-design.md`. Provisioning runbook: `docs/runbooks/vm-provisioning.md`.

Images are **generic** -- no hostnames, no users beyond cloud-init defaults, no secrets. Per-VM identity (hostname, admin user, Tailscale join) is injected at provision time by `ansible/playbooks/vms.yml` via a NoCloud cloud-init seed.

## Layout

| Path | Purpose |
|------|---------|
| `ubuntu-24.04/ubuntu.pkr.hcl` | Base gold master. QEMU builder from a pinned noble cloud image; installs qemu-guest-agent, tailscale (unjoined), unattended-upgrades, base tools; wipes machine identity + cloud-init state |
| `ubuntu-24.04-k8s/ubuntu-k8s.pkr.hcl` | k3s-node variant of the same image (see below) |
| `scripts/publish-image.sh` | scp an artifact to `homelab:/media/root/storage1/vms/images/` and repoint that image family's `latest` symlink |

## Image families

Each template produces its own **family**, and each family has its own mutable `latest` pointer:

| Family | Built by | `latest` symlink |
|--------|----------|------------------|
| `ubuntu-24.04-golden` | `ubuntu-24.04/` | `ubuntu-24.04-golden-latest.qcow2` |
| `ubuntu-24.04-k8s-golden` | `ubuntu-24.04-k8s/` | `ubuntu-24.04-k8s-golden-latest.qcow2` |

`publish-image.sh` derives the family from the artifact name, which must match

```
<family>-v<semver>.qcow2
```

`<semver>` is `MAJOR.MINOR.PATCH` with an optional prerelease/build suffix, which is what admits Packer's default `0.0.0-dev`. A name that does not parse is **rejected**: the family decides which symlink is repointed, so an arbitrary filename must never be able to select an unintended one. Both templates already emit conforming names; you only meet the grammar if you rename an artifact by hand.

## The k8s-node variant

`ubuntu-24.04-k8s/` is the base gold master with four deliberate differences. Everything else should stay in step with the base template.

1. **No unattended upgrades.** A cluster node must not reboot or swap a kernel or container-runtime package on its own schedule; upgrades are an operator action taken with the workload drained. Done in all three places, because any one alone is insufficient: the package is purged, the `apt-daily`/`apt-daily-upgrade` **timers and their services** are masked (a masked timer still leaves the service startable by anything else), and the `APT::Periodic` knobs are zeroed in `/etc/apt/apt.conf.d/99-irl-no-auto`.
2. **`nfs-common` installed.** Cheap, and likely wanted whichever way the cluster storage decision lands.
3. **`open-iscsi` deliberately NOT installed.** Configuring the package generates `/etc/iscsi/initiatorname.iscsi`, which every clone of the image would then share. A duplicated initiator IQN is a correctness hazard (two nodes claiming one initiator identity) and an access-control one (IQN-based ACLs stop distinguishing nodes). If iSCSI is ever chosen, Ansible installs it per-VM so each node mints its own IQN. The template asserts the file is absent from the artifact.
4. **No k3s pre-download.** `ansible/playbooks/k3s.yml` uses the presence of `/usr/local/bin/k3s` as its install sentinel, so a pre-baked binary would skip the install and then fail on the missing service unit. **Node software install remains Ansible's job** -- k3s, kubelet config, labels, and taints all come from the playbooks, not the image. Pre-caching can return later as its own change that also reworks `k3s.yml`'s install contract.

The variant also runs a cleanup-phase assertion pass: no baked initiator IQN, no `unattended-upgrades`, all four apt units masked, the apt dropin present, and a blank machine-id with no SSH host keys. These fail the build rather than shipping a broken gold master.

## Workflow

```bash
cd packer/ubuntu-24.04            # or packer/ubuntu-24.04-k8s
packer init .
packer build -var "image_version=1.0.0" .          # laptop needs KVM (/dev/kvm)
../scripts/publish-image.sh output/ubuntu-24.04-golden-v1.0.0.qcow2
```

Then provision VMs: add an entry to `irl_vms` in `ansible/inventory/host_vars/homelab.yml` and run `uv run ansible-playbook playbooks/vms.yml` from `ansible/`. A VM that should use the k8s-node image pins it explicitly:

```yaml
irl_vms:
  k8s-vm-01:
    vcpus: 2
    ram_gb: 4
    disk_gb: 40
    image: ubuntu-24.04-k8s-golden-latest.qcow2
```

## Pinning and bumping the upstream base image

Both templates pin the upstream Ubuntu cloud image to a **dated serial**, not `noble/current`:

```hcl
base_image_url      = ".../releases/noble/release-20260814/ubuntu-24.04-server-cloudimg-amd64.img"
base_image_checksum = "sha256:6e40c07ae715f744f84af0bec76415cc1987dd115b4b8de437818561f01a3733"
```

`current` is a moving target: two builds of the same `image_version` would silently differ, and the checksum could not be verified ahead of time.

To bump:

1. Pick a serial from <https://cloud-images.ubuntu.com/releases/noble/>.
2. Take the `ubuntu-24.04-server-cloudimg-amd64.img` line from that serial directory's `SHA256SUMS`.
3. Update **both** `base_image_url` and `base_image_checksum` together, and bump `image_version`.
4. Keep both variants on the same serial unless there is a reason not to.

Changing one variable without the other fails the build at download time. That is the point.

## Debugging a build

Pass `-var headless=false` to get a QEMU window. The build logs in via a throwaway `packer` user that is force-deleted before the artifact is finalized.

## Versioning

`image_version` is stamped into the filename and `/etc/irl-golden-image` inside the image. Bump it every published build; never overwrite a published version.

A family's `latest` symlink is the **only** mutable pointer, and `vms.yml` resolves it to a concrete file before recording a new disk's backing file -- so republishing never changes what an existing guest boots from. Disks created before that behavior existed record the symlink itself; `vms.yml` audits for them and `docs/runbooks/vm-disk-rebase.md` is the repair. Never delete a published version that a live disk still backs onto.

## Verification

`packer validate` proves template **syntax only** -- it does not execute provisioners, so nothing above about apt masking, iSCSI, or the identity wipe is verified by it. One real build per variant, on a machine with `/dev/kvm`, is the acceptance step before first use.

```bash
cd packer/ubuntu-24.04     && packer init . && packer validate -var image_version=0.0.1 .
cd packer/ubuntu-24.04-k8s && packer init . && packer validate -var image_version=0.0.1 .
cd tests && uv run pytest -m hygiene       # includes publish-image.sh unit tests
```
