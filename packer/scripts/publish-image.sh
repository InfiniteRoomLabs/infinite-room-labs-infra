#!/usr/bin/env -S usage bash
#USAGE arg "<qcow2>" "Path to the built gold master qcow2 (packer output)"
#USAGE flag "-H --host <host>" default="homelab-ts" "SSH host to publish to"
#USAGE flag "-d --dest <dest>" default="/media/root/storage1/vms/images" "Remote images directory"
#USAGE flag "-n --no-latest" "Skip updating the <family>-latest.qcow2 symlink"

# Publishes a Packer-built gold master to the homelab ZFS images directory and
# points that image FAMILY's `latest` symlink at it. vms.yml resolves images by
# the symlink unless a VM pins an explicit version.
#
# Artifact names must match the grammar
#
#     <family>-v<semver>.qcow2
#
# where <family> is the image family (ubuntu-24.04-golden,
# ubuntu-24.04-k8s-golden, ...) and <semver> is MAJOR.MINOR.PATCH with an
# optional prerelease/build suffix -- which is what admits the Packer default
# `0.0.0-dev`. The family is DERIVED from the name and decides which symlink
# gets repointed, so a name that does not parse is rejected outright: an
# arbitrary filename must never be able to select an unintended symlink.

set -euo pipefail

qcow2="${usage_qcow2:-}"
host="${usage_host:-homelab-ts}"
dest="${usage_dest:-/media/root/storage1/vms/images}"

[ -n "$qcow2" ] || { echo "ERROR: no qcow2 argument given" >&2; exit 2; }
[ -f "$qcow2" ] || { echo "ERROR: no such file: $qcow2" >&2; exit 1; }

name="$(basename "$qcow2")"

# Family + version, in one parse. Anchored at both ends; the family group is
# greedy so a family containing dashes (every family we ship) binds to the
# LAST -v<semver> segment.
name_re='^([A-Za-z0-9][A-Za-z0-9._]*(-[A-Za-z0-9._]+)*)-v([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+(\.[0-9A-Za-z.]+)*)?(\+[0-9A-Za-z.]+)?)\.qcow2$'

if [[ ! "$name" =~ $name_re ]]; then
    cat >&2 <<ERR
ERROR: artifact name does not match the image-family grammar: $name
       expected <family>-v<semver>.qcow2
       e.g. ubuntu-24.04-golden-v1.2.3.qcow2
            ubuntu-24.04-k8s-golden-v0.0.0-dev.qcow2
       The family is derived from this name and decides which
       <family>-latest.qcow2 symlink is repointed, so an unparseable name is
       refused rather than guessed at.
ERR
    exit 1
fi

family="${BASH_REMATCH[1]}"
version="${BASH_REMATCH[3]}"
latest="${family}-latest.qcow2"

echo "Publishing $name -> $host:$dest/"
echo "  family:  $family"
echo "  version: $version"
scp "$qcow2" "$host:$dest/$name.tmp"
ssh "$host" "mv '$dest/$name.tmp' '$dest/$name'"

if [ -z "${usage_no_latest:-}" ]; then
    ssh "$host" "ln -sfn '$name' '$dest/$latest'"
    echo "$latest -> $name"
else
    echo "skipping $latest (--no-latest)"
fi

echo "Done. Remote images:"
ssh "$host" "ls -lh '$dest/'"
