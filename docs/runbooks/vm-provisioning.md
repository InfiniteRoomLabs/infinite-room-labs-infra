# Runbook: Provisioning Ubuntu VMs on the Homelab

Design: `docs/plans/2026-07-23-homelab-vm-gold-master-design.md`. Pipeline source: `packer/`, `ansible/playbooks/libvirt.yml`, `ansible/playbooks/vms.yml`.

## Provision a new VM (normal path)

1. **Ensure a gold master is published** (skip if `homelab:/media/root/storage1/vms/images/ubuntu-24.04-golden-latest.qcow2` exists):
   ```bash
   cd packer/ubuntu-24.04
   packer init . && packer build -var "image_version=X.Y.Z" .
   ../scripts/publish-image.sh output/ubuntu-24.04-golden-vX.Y.Z.qcow2
   ```
2. **Declare the VM** in `ansible/inventory/host_vars/homelab.yml` under `irl_vms` (respect `irl_vm_ram_budget_gb` -- the playbook asserts it):
   ```yaml
   irl_vms:
     my-vm:
       vcpus: 2
       ram_gb: 2
       disk_gb: 20
       # image: ubuntu-24.04-golden-v1.0.0.qcow2   # optional version pin
   ```
3. **Run the playbook** (needs a valid `tailscale-api-key` in Bitwarden -- it mints a single-use pre-auth key per new VM):
   ```bash
   cd ansible && uv run ansible-playbook playbooks/vms.yml
   ```
4. **Verify** (first boot takes 1-2 minutes):
   ```bash
   tailscale status | grep my-vm     # joined the tailnet
   ssh wes@my-vm                     # MagicDNS short name
   ssh wes@my-vm cloud-init status   # "status: done"
   ```

## Teardown (manual by design -- removing an irl_vms entry does NOT delete)

```bash
ssh homelab-ts
virsh -c qemu:///system destroy my-vm
virsh -c qemu:///system undefine my-vm
sudo rm /media/root/storage1/vms/disks/my-vm.qcow2 /media/root/storage1/vms/seeds/my-vm-seed.iso
```
Then remove the entry from `irl_vms` and the machine from the Tailscale admin console.

## Gotchas (all learned the hard way, 2026-07-23)

- **`virsh` on the homelab needs `-c qemu:///system`** -- as a non-root user it defaults to the empty `qemu:///session`.
- **Tailscale API key expires every 90 days** (Bitwarden `tailscale-api-key`). A 401 from `vms.yml`'s mint task means rotate it in the admin console, update Bitwarden, `mise run secrets:sync`. Durable fix if this gets annoying: a Tailscale OAuth client (does not expire) + token exchange in the playbook.
- **Tailscale key descriptions reject punctuation** (parens, dots) -- plain words and dashes only.
- **Host firewall vs libvirt**: the nftables input policy is drop; `virbr-irl` is allowlisted in `ansible/templates/nftables.conf.j2`. If VMs stop getting DHCP after a `security-hardening.yml` run, the ruleset flush also wiped libvirt's dynamic NAT rules -- restart networking AND reboot VMs to re-plug their taps:
  ```bash
  virsh -c qemu:///system net-destroy irl-vms && virsh -c qemu:///system net-start irl-vms
  virsh -c qemu:///system destroy my-vm && virsh -c qemu:///system start my-vm
  ```
  (`net-destroy` orphans running VMs' tap interfaces; a VM restart re-attaches them.)
- **libvirt's dnsmasq serves DHCP only, no DNS** -- the internal CoreDNS owns `*:53` on the host. VMs get 1.1.1.1/9.9.9.9 from DHCP for bootstrap, then MagicDNS (including `*.lab` split DNS) after the Tailscale join. See `ansible/templates/vm-network.xml.j2`.
- **Debugging a VM with no network**: the qemu guest agent works without networking --
  `virsh -c qemu:///system qemu-agent-command my-vm '{"execute":"guest-network-get-interfaces"}'`, or `guest-exec` for arbitrary commands.
