# Runbook: Rebase a VM Disk off a Mutable `-latest` Symlink

**When you need this**: `ansible/playbooks/vms.yml` failed the preflight
"Assert no existing VM disk is backed by a mutable -latest image". The failure
names the disk and the backing reference it found.

Related: `docs/runbooks/vm-provisioning.md`, `packer/README.md`.

## Why it matters

VM disks are qcow2 overlays. The overlay stores its backing file as a **path
recorded in the qcow2 header**, and QEMU re-opens that path every time the
guest starts. If the recorded path is `<family>-latest.qcow2` -- a symlink that
`packer/scripts/publish-image.sh` repoints on every publish -- then publishing a
new gold master silently changes what the guest boots from. The overlay's
blocks were written against the *old* base, so the result ranges from a
confusing boot to filesystem corruption.

`vms.yml` now resolves the symlink before it calls `qemu-img create`, so every
disk it creates from here on records a concrete versioned image. Disks created
before that change still record the symlink and must be repaired by hand.

Known case: `ubuntu-vm-01` was declared without an `image:` pin under the old
behavior, so it is expected to trip this audit.

## Procedure

Everything below runs on the hypervisor. `vms.yml` never does any of it: it
audits and refuses to proceed. Never rebase a running VM -- QEMU holds the
image open and has its own view of the chain.

1. **Identify the concrete image the symlink currently points at.**

   ```bash
   ssh homelab-ts
   cd /media/root/storage1/vms/images
   readlink -e ubuntu-24.04-golden-latest.qcow2
   # -> /media/root/storage1/vms/images/ubuntu-24.04-golden-v1.0.0.qcow2
   ```

   If the symlink has already been repointed since the VM was created, this is
   the **wrong** image and rebasing onto it will corrupt the guest. Confirm the
   version the VM actually booted from before continuing:

   ```bash
   ssh wes@<vm> cat /etc/irl-golden-image
   ```

   The `version:` line there names the image the VM was built from. Use the
   matching `ubuntu-24.04-golden-v<version>.qcow2` file. If that file is gone,
   stop: this is a restore-from-backup situation, not a rebase.

2. **Shut the guest down cleanly and confirm it is off.**

   ```bash
   virsh -c qemu:///system shutdown <vm>
   virsh -c qemu:///system domstate <vm>    # must read "shut off"
   ```

3. **Snapshot the disk's current metadata** so you can tell what changed:

   ```bash
   qemu-img info --output=json /media/root/storage1/vms/disks/<vm>.qcow2
   ```

   Keep the output. `backing-filename` is what you are about to replace.

4. **Rewrite the backing reference, metadata only.**

   `-u` ("unsafe") tells `qemu-img` to change the recorded path **without**
   rewriting any data. That is exactly what is wanted here: the symlink and the
   concrete file are the same bytes, so no data conversion is needed and none
   should happen. Dropping `-u` would make `qemu-img` read and rewrite the
   overlay against the new base -- slow, and wrong if the two differ.

   ```bash
   qemu-img rebase -u \
     -b /media/root/storage1/vms/images/ubuntu-24.04-golden-v1.0.0.qcow2 \
     -F qcow2 \
     /media/root/storage1/vms/disks/<vm>.qcow2
   ```

5. **Verify** the new chain before booting:

   ```bash
   qemu-img info --output=json /media/root/storage1/vms/disks/<vm>.qcow2
   qemu-img check /media/root/storage1/vms/disks/<vm>.qcow2
   ```

   `backing-filename` must now be the concrete `-v<version>.qcow2` path, and
   `qemu-img check` must report no errors.

6. **Boot and confirm the guest is healthy.**

   ```bash
   virsh -c qemu:///system start <vm>
   ssh wes@<vm> cat /etc/irl-golden-image
   ssh wes@<vm> systemctl is-system-running
   ```

7. **Re-run the playbook.** The audit should pass:

   ```bash
   cd ansible && uv run ansible-playbook playbooks/vms.yml
   ```

## Aftercare

- **Pin the VM's image in `irl_vms`.** Add `image: ubuntu-24.04-golden-v<version>.qcow2`
  to the VM's entry in `ansible/inventory/host_vars/homelab.yml` so the
  declaration matches the disk. The drift assertion in `vms.yml` checks the
  backing file against the declared image *family*, so an unpinned entry is not
  an error -- but a pinned one documents what the guest is actually running.
- **Never delete a published image version that a live disk backs onto.** The
  `-latest` symlink is the only mutable pointer; versioned files are permanent.
  `qemu-img info` on every disk in `disks/` tells you which versions are still
  load bearing.
