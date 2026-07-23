#!/usr/bin/env -S usage bash
#USAGE arg "<qcow2>" "Path to the built gold master qcow2 (packer output)"
#USAGE flag "-H --host <host>" default="homelab-ts" "SSH host to publish to"
#USAGE flag "-d --dest <dest>" default="/media/root/storage1/vms/images" "Remote images directory"
#USAGE flag "-n --no-latest" "Skip updating the ubuntu-24.04-golden-latest.qcow2 symlink"

# Publishes a Packer-built gold master to the homelab ZFS images directory and
# points the `latest` symlink at it. vms.yml resolves images by this symlink
# unless a VM pins an explicit version.

set -euo pipefail

qcow2="$usage_qcow2"
host="$usage_host"
dest="$usage_dest"

[ -f "$qcow2" ] || { echo "ERROR: no such file: $qcow2" >&2; exit 1; }

name="$(basename "$qcow2")"
case "$name" in
  *.qcow2) ;;
  *) echo "ERROR: expected a .qcow2 file, got: $name" >&2; exit 1 ;;
esac

echo "Publishing $name -> $host:$dest/"
scp "$qcow2" "$host:$dest/$name.tmp"
ssh "$host" "mv '$dest/$name.tmp' '$dest/$name'"

if [ -z "${usage_no_latest:-}" ]; then
  ssh "$host" "ln -sfn '$name' '$dest/ubuntu-24.04-golden-latest.qcow2'"
  echo "latest -> $name"
fi

echo "Done. Remote images:"
ssh "$host" "ls -lh '$dest/'"
