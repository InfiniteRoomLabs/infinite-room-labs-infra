#!/usr/bin/env -S usage bash
set -euo pipefail

#USAGE flag "--from <from>" help="Bundle directory written by desktop/Export-OpenMessageData.ps1. Required." required=#true
#USAGE flag "--ssh-host <ssh_host>" help="SSH alias or address of the k3s node holding the PV." default="homelab-ts"
#USAGE flag "--data-dir <data_dir>" help="Host path of the openmessage ZFS dataset backing pv-openmessage-data." default="/media/root/storage1/openmessage"
#USAGE flag "--namespace <namespace>" help="Kubernetes namespace of the OpenMessage release." default="irl"
#USAGE flag "--deployment <deployment>" help="Deployment name to check is scaled to zero." default="openmessage"
#USAGE flag "--overwrite" help="Allow landing on top of an existing messages.db in the data dir."
#USAGE flag "--dry-run" help="Run every check and print the plan; copy nothing."

# openmessage-import-data.sh
# ==========================
# Step two of the OpenMessage data migration: land the desktop daemon's SQLite
# store and Google pairing credential on the homelab PV, so the cluster pod
# resumes an existing pairing instead of asking for a re-pair.
#
# Step one is desktop/Export-OpenMessageData.ps1, which runs on the Windows
# desktop and writes the bundle this script consumes.
#
# Plan:    docs/superpowers/plans/2026-09-29-desktop-iac-openmessage.md
#          docs/plans/2026-09-25-openmessage-k3s-deployment.md section 8
# Runbook: ansible/docs/runbooks/openmessage-down.md
#
# WHAT THIS REFUSES TO DO, AND WHY
#
#   - Run against a bundle whose manifest does not record the desktop service
#     as Stopped or Absent. SQLite in WAL mode means a copy taken from a live
#     writer can be torn; the export captures that state on the machine where
#     it can actually be observed, and this script trusts nothing else.
#   - Run while the cluster Deployment has replicas > 0, or while any
#     OpenMessage pod exists. Files must land before anything opens them.
#   - Start the pod afterwards. Scaling up is a deliberate human act, done
#     after reading the data in place -- see the plan's deploy sequence.
#   - Land on top of an existing messages.db without --overwrite. Two stores
#     merged by cp is not a merge, it is data loss.
#
# The one-pod rule sits over all of it: exactly one OpenMessage may hold the
# Google pairing. The window between "desktop service stopped" and "cluster
# pod started" is the only safe time to run this.
#
# Args arrive as $usage_* env vars (usage parses the #USAGE spec above).

# Client-side expansion in the ssh command strings below is intentional: the
# paths being interpolated are this script's own variables (the staging dir,
# the data dir), not values that exist on the remote host. Hence the SC2029
# suppressions.

BUNDLE="${usage_from:?--from is required}"
SSH_HOST="${usage_ssh_host:-homelab-ts}"
DATA_DIR="${usage_data_dir:-/media/root/storage1/openmessage}"
NAMESPACE="${usage_namespace:-irl}"
DEPLOYMENT="${usage_deployment:-openmessage}"
OVERWRITE=false
[[ -n "${usage_overwrite:-}" ]] && OVERWRITE=true
DRY_RUN=false
[[ -n "${usage_dry_run:-}" ]] && DRY_RUN=true

die() {
  echo "ERROR: $*" >&2
  exit 1
}

note() { echo "==> $*"; }

run() {
  if [[ "$DRY_RUN" == true ]]; then
    echo "     [dry-run] $*"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# 1. Validate the bundle locally
# ---------------------------------------------------------------------------
[[ -d "$BUNDLE" ]] || die "bundle directory not found: $BUNDLE"
[[ -f "$BUNDLE/manifest.json" ]] || die "no manifest.json in $BUNDLE -- was it written by desktop/Export-OpenMessageData.ps1?"
[[ -f "$BUNDLE/SHA256SUMS" ]] || die "no SHA256SUMS in $BUNDLE"

command -v jq >/dev/null 2>&1 || die "jq is required"
command -v kubectl >/dev/null 2>&1 || die "kubectl is required"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"

kind="$(jq -r '.kind // empty' "$BUNDLE/manifest.json")"
[[ "$kind" == "openmessage-data-bundle" ]] || die "manifest.json is not an openmessage-data-bundle (kind='$kind')"

service_state="$(jq -r '.service_state // empty' "$BUNDLE/manifest.json")"
case "$service_state" in
  Stopped | Absent) ;;
  *) die "the desktop service was '$service_state' when this bundle was exported, not Stopped or Absent. Re-export after stopping it: pwsh -File .\\Invoke-DesktopConverge.ps1 -Item openmessage-daemon-stop" ;;
esac

note "bundle $BUNDLE exported $(jq -r '.exported_at' "$BUNDLE/manifest.json"), desktop service $service_state"

# messages.db and session.json are the pair that make this worth doing at all:
# the database without the credential means a re-pair, the credential without
# the database means a full re-sync.
for required in messages.db session.json; do
  [[ -f "$BUNDLE/$required" ]] || die "bundle is missing $required"
done

note "verifying bundle checksums locally"
(cd "$BUNDLE" && sha256sum -c SHA256SUMS) || die "local checksum verification failed -- the bundle is damaged, re-export it"

# Every file the manifest lists must be covered by SHA256SUMS, or a file could
# ride along unverified.
mapfile -t manifest_files < <(jq -r '.files[]' "$BUNDLE/manifest.json")
for f in "${manifest_files[@]}"; do
  grep -qE "[[:space:]]\*?${f}\$" "$BUNDLE/SHA256SUMS" || die "$f is in the manifest but not in SHA256SUMS"
done

# ---------------------------------------------------------------------------
# 2. Refuse if anything is running in the cluster
# ---------------------------------------------------------------------------
if kubectl -n "$NAMESPACE" get deployment "$DEPLOYMENT" >/dev/null 2>&1; then
  replicas="$(kubectl -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o jsonpath='{.spec.replicas}')"
  [[ "${replicas:-0}" -eq 0 ]] || die "deployment $NAMESPACE/$DEPLOYMENT has spec.replicas=$replicas. Scale it to 0 and wait for the pod to go before importing: kubectl scale -n $NAMESPACE deploy/$DEPLOYMENT --replicas=0"
  note "deployment $NAMESPACE/$DEPLOYMENT is scaled to 0"
else
  note "deployment $NAMESPACE/$DEPLOYMENT does not exist yet -- importing before first deploy"
fi

pods="$(kubectl -n "$NAMESPACE" get pods -l "app.kubernetes.io/instance=$DEPLOYMENT" -o name 2>/dev/null || true)"
[[ -z "$pods" ]] || die "OpenMessage pods still exist: $pods -- wait for them to terminate (kubectl wait -n $NAMESPACE --for=delete pod -l app.kubernetes.io/instance=$DEPLOYMENT --timeout=120s)"

# ---------------------------------------------------------------------------
# 3. Refuse to clobber an existing store
# ---------------------------------------------------------------------------
# shellcheck disable=SC2029
if ssh "$SSH_HOST" "sudo test -f '$DATA_DIR/messages.db'"; then
  [[ "$OVERWRITE" == true ]] || die "$SSH_HOST:$DATA_DIR/messages.db already exists. The cluster already has a store; importing over it would lose whichever side you did not mean to keep. Pass --overwrite if you are sure."
  note "WARNING: --overwrite given; the existing $DATA_DIR/messages.db will be replaced"
fi

# ---------------------------------------------------------------------------
# 4. Stage, verify on the far side, then move into place
# ---------------------------------------------------------------------------
staging="/tmp/openmessage-import.$$"
note "staging to $SSH_HOST:$staging"
run ssh "$SSH_HOST" "mkdir -p '$staging'"

cleanup() {
  if [[ "$DRY_RUN" == false ]]; then
    # shellcheck disable=SC2029
    ssh "$SSH_HOST" "rm -rf '$staging'" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# WAL files travel with the database, always together: messages.db on its own
# can be missing committed transactions that only exist in the -wal.
scp_files=("$BUNDLE/SHA256SUMS")
for f in "${manifest_files[@]}"; do scp_files+=("$BUNDLE/$f"); done
run scp "${scp_files[@]}" "$SSH_HOST:$staging/"

note "verifying checksums on $SSH_HOST"
run ssh "$SSH_HOST" "cd '$staging' && sha256sum -c SHA256SUMS"

note "installing into $DATA_DIR (owner 1000:1000 -- hostPath PVs ignore fsGroup, so the dataset owner is what makes it writable)"
run ssh "$SSH_HOST" "sudo mkdir -p '$DATA_DIR' && sudo cp -a $(printf "'%s/%s' " "$staging" "${manifest_files[@]}") '$DATA_DIR/' && sudo chown -R 1000:1000 '$DATA_DIR'"

note "re-verifying checksums in their final location"
run ssh "$SSH_HOST" "cd '$DATA_DIR' && sudo sha256sum -c '$staging/SHA256SUMS'"

if [[ "$DRY_RUN" == true ]]; then
  echo
  echo "Dry run complete. Every precondition passed; nothing was copied."
  exit 0
fi

cat <<EOF

Import complete. The pod was NOT started -- that is deliberate.

Next:
  ansible/ \$ uv run ansible-playbook playbooks/helm-deploy.yml --tags openmessage
  kubectl -n $NAMESPACE logs -f deploy/$DEPLOYMENT      # pairing state appears only in the logs

The desktop's data directory is untouched and remains the rollback.
EOF
