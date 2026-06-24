#!/usr/bin/env bash
# knowledge-backup.sh -- mirror the laptop knowledge archives to the homelab NFS
# share, but ONLY when Tailscale is up and the homelab is reachable. A clean no-op
# (exit 0) when off-network, so a 6-hourly timer never noisily fails on the road.
#
# Transport: rsync to the local NFS automount (/mnt/homelab-nfs, fstab) -> lands in
# the homelab ZFS share over Tailscale. No --delete: this is append-safe redundancy,
# so a local wipe can never propagate to the backup (git history + ZFS snapshots are
# the versioning layer).
#
# Deployed by infra ansible/playbooks/laptop.yml. Run standalone: ./knowledge-backup.sh
set -uo pipefail

DEST="/mnt/homelab-nfs/laptop-knowledge-backup"
HOMELAB_IP="100.86.213.22"
SOURCES=(
    "$HOME/claude-ai-export"
    "$HOME/private-email-archive"
    "$HOME/threadwatch"
)

log() { printf '{"event":"knowledge_backup",%s}\n' "$1"; }

# -- Guard: Tailscale up + homelab reachable. Skip cleanly (exit 0) if not. --
if ! tailscale status >/dev/null 2>&1; then
    log '"status":"skipped","reason":"tailscale down"'; exit 0
fi
if ! ping -c1 -W3 "$HOMELAB_IP" >/dev/null 2>&1; then
    log '"status":"skipped","reason":"homelab unreachable"'; exit 0
fi

# Trigger the automount and confirm the destination is writable.
if ! mkdir -p "$DEST" 2>/dev/null || ! : >"$DEST/.writable" 2>/dev/null; then
    log '"status":"error","reason":"NFS dest not writable"'; exit 75
fi
rm -f "$DEST/.writable"

rc=0
for src in "${SOURCES[@]}"; do
    [ -d "$src" ] || continue
    rsync -a \
        --exclude='.venv/' --exclude='__pycache__/' --exclude='*.py[co]' \
        --exclude='.pytest_cache/' --exclude='node_modules/' \
        --exclude='.reindex-work/' --exclude='.reindex.lock' \
        "$src/" "$DEST/$(basename "$src")/" || rc=$?
done

if [ "$rc" -eq 0 ]; then
    printf 'last_backup_utc=%s\nhost=%s\nsources=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(hostname)" "${SOURCES[*]}" \
        > "$DEST/LAST-BACKUP.txt" 2>/dev/null || true
    log "\"status\":\"ok\",\"dest\":\"$DEST\""
else
    log "\"status\":\"partial\",\"rc\":$rc"; exit 75
fi
