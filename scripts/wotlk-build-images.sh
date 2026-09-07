#!/usr/bin/env -S usage bash
set -euo pipefail

#USAGE flag "--host <host>" help="SSH host that builds and runs k3s" default="homelab-ts"
#USAGE flag "--acore-ref <ref>" help="mod-playerbots/azerothcore-wotlk branch or tag" default="Playerbot"
#USAGE flag "--module-ref <ref>" help="mod-playerbots/mod-playerbots branch or tag" default="master"
#USAGE flag "--cpus <cpuset>" help="cpuset for the buildkit container (leave headroom for k3s)" default="0-15"
#USAGE flag "--memory <size>" help="memory cap for the buildkit container" default="18g"
#USAGE flag "--no-import" help="Build only; skip the k3s containerd import"

# scripts/wotlk-build-images.sh
# Builds the AzerothCore + Playerbots images ON the homelab (24 threads) and
# imports them straight into k3s containerd on the same node. No registry:
# the images live only on that node (irl-wotlk pins nodeSelector to it) and
# a copy of the tarball is dropped in /var/lib/rancher/k3s/agent/images/ so
# k3s re-imports it after a restart or an image GC pass.
#
# Reuses the existing buildkit state volume (buildx_buildkit_homelab0_state)
# so previous compile layers are warm. The buildkit container is recreated
# with cpu/memory caps so a compile can't starve the cluster.
#
# Prints the image tag to pin in ansible/helm/wotlk/values.yaml.

HOST="${usage_host}"
ACORE_REF="${usage_acore_ref}"
MODULE_REF="${usage_module_ref}"
CPUS="${usage_cpus}"
MEMORY="${usage_memory}"
IMPORT=1; [[ "${usage_no_import:-}" == "true" ]] && IMPORT=0

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULES_DOCKERFILE_B64="$(base64 -w0 "$REPO_ROOT/docker/ac-wotlk-worldserver/Dockerfile")"

ssh -o BatchMode=yes "$HOST" \
  ACORE_REF="$ACORE_REF" MODULE_REF="$MODULE_REF" CPUS="$CPUS" MEMORY="$MEMORY" IMPORT="$IMPORT" \
  MODULES_DOCKERFILE_B64="$MODULES_DOCKERFILE_B64" \
  'bash -s' <<'REMOTE'
set -euo pipefail
SRC="$HOME/build/azerothcore-wotlk"
MOD="$SRC/modules/mod-playerbots"

sync_repo() {  # dir url ref
  if [[ -d "$1/.git" ]]; then
    git -C "$1" fetch --depth 1 origin "$3" && git -C "$1" checkout -q --detach FETCH_HEAD
  else
    git clone -q --depth 1 --branch "$3" "$2" "$1"
  fi
}
mkdir -p "$(dirname "$SRC")"
sync_repo "$SRC" https://github.com/mod-playerbots/azerothcore-wotlk.git "$ACORE_REF"
sync_repo "$MOD" https://github.com/mod-playerbots/mod-playerbots.git "$MODULE_REF"
TAG="pb-$(git -C "$SRC" rev-parse --short HEAD)-$(git -C "$MOD" rev-parse --short HEAD)"
echo "==> tag: $TAG"

# Builder: same node name as the Deck-created one so the state volume
# (buildx_buildkit_homelab0_state, the warm cache) is reused.
if ! docker buildx inspect homelab >/dev/null 2>&1; then
  docker rm -f buildx_buildkit_homelab0 >/dev/null 2>&1 || true
  docker buildx create --name homelab --driver docker-container \
    --driver-opt "cpuset-cpus=$CPUS,memory=$MEMORY" >/dev/null
fi
docker buildx inspect --bootstrap homelab >/dev/null

build() {  # target image
  docker buildx build --builder homelab --load \
    -f "$SRC/apps/docker/Dockerfile" --target "$1" -t "$2" "$SRC"
}
build authserver  "irl/ac-wotlk-authserver:$TAG"
build db-import   "irl/ac-wotlk-db-import:$TAG"
build client-data "irl/ac-wotlk-client-data:$TAG"
build worldserver "irl/ac-wotlk-worldserver-base:$TAG"
# Daemon builder here on purpose: the docker-container builder cannot see
# images that only exist in the local daemon, and BASE is one of those.
base64 -d <<<"$MODULES_DOCKERFILE_B64" | docker build \
  -f - --build-arg "BASE=irl/ac-wotlk-worldserver-base:$TAG" \
  -t "irl/ac-wotlk-worldserver:$TAG" "$SRC"

IMAGES=(irl/ac-wotlk-{authserver,db-import,client-data,worldserver}:"$TAG")
docker images --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep "ac-wotlk.*$TAG"

if [[ "$IMPORT" == 1 ]]; then
  echo "==> importing into k3s containerd"
  sudo -n mkdir -p /var/lib/rancher/k3s/agent/images
  docker save "${IMAGES[@]}" | sudo -n tee /var/lib/rancher/k3s/agent/images/ac-wotlk.tar \
    | sudo -n k3s ctr images import - >/dev/null
  sudo -n k3s ctr images ls -q | grep "ac-wotlk.*$TAG"
fi
echo "==> done. Pin in ansible/helm/wotlk/values.yaml: tag: \"$TAG\""
REMOTE
