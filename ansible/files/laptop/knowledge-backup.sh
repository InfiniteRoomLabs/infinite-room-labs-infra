#!/usr/bin/env bash
# knowledge-backup.sh -- back up the laptop knowledge archives to the homelab over
# SSH, into the dedicated main/backups ZFS dataset (owned by wes, its own quota).
# ONLY when Tailscale is up and the homelab is reachable; a clean no-op (exit 0)
# off-network, so a 6-hourly timer never noisily fails on the road.
#
# Transport: rsync over ssh to the `homelab-ts` alias (Tailscale). No --delete: this
# is append-safe redundancy, so a local wipe can never propagate to the backup (git
# history + ZFS snapshots are the versioning layer). The SSH key is passphraseless,
# so it runs unattended without an agent.
#
# One-time server setup (already done): the wes-owned dest dir
#   sudo mkdir -p /media/root/storage1/backups/laptop-knowledge
#   sudo chown wes:wes /media/root/storage1/backups/laptop-knowledge
#
# Deployed by infra ansible/playbooks/laptop.yml. Run standalone: ./knowledge-backup.sh
set -uo pipefail

HOMELAB_IP="100.86.213.22"
SSH_HOST="homelab-ts"
WAIT_FOR_IT="$HOME/.local/bin/wait-for-it"
REMOTE_DEST="/media/root/storage1/backups/laptop-knowledge"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
SOURCES=(
    "$HOME/claude-ai-export"
    "$HOME/threadwatch"
)
# Private archives join the list from a local, uncommitted file: one absolute
# path per line, `#` comments allowed. Missing dirs are skipped either way.
EXTRA_DIRS_FILE="$HOME/.config/knowledge-backup/dirs"
if [ -f "$EXTRA_DIRS_FILE" ]; then
    while IFS= read -r d; do
        case "$d" in ''|'#'*) continue ;; esac
        SOURCES+=("${d/#\~/$HOME}")
    done < "$EXTRA_DIRS_FILE"
fi

log() { printf '{"event":"knowledge_backup",%s}\n' "$1"; }

# -- Guard: wait (bounded) for the homelab, then skip cleanly if still down. --
# On resume/boot Tailscale needs ~10-15s to reconnect, so a single check would skip a
# backup that would have succeeded moments later (observed on a wake-from-sleep). A
# reachable homelab Tailscale IP:22 also implies Tailscale is up (its IP isn't routable
# otherwise). Skip cleanly (exit 0) only if still down after the wait -- genuinely
# off-network, where a 6-hourly no-op is correct.
if ! "$WAIT_FOR_IT" --tcp "$HOMELAB_IP:22" --timeout 90 --interval 5; then
    log '"status":"skipped","reason":"homelab unreachable after 90s wait"'; exit 0
fi

# Confirm ssh works and the dest dir exists (created wes-owned during setup).
if ! ssh "${SSH_OPTS[@]}" "$SSH_HOST" "mkdir -p '$REMOTE_DEST'" 2>/dev/null; then
    log '"status":"error","reason":"ssh or dest setup failed"'; exit 75
fi

rc=0
for src in "${SOURCES[@]}"; do
    [ -d "$src" ] || continue
    rsync -a -e "ssh ${SSH_OPTS[*]}" \
        --exclude='.venv/' --exclude='__pycache__/' --exclude='*.py[co]' \
        --exclude='.pytest_cache/' --exclude='node_modules/' \
        --exclude='.reindex-work/' --exclude='.reindex.lock' \
        "$src/" "$SSH_HOST:$REMOTE_DEST/$(basename "$src")/" || rc=$?
done

if [ "$rc" -eq 0 ]; then
    printf 'last_backup_utc=%s\nhost=%s\nsources=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(hostname)" "${SOURCES[*]}" \
        | ssh "${SSH_OPTS[@]}" "$SSH_HOST" "cat > '$REMOTE_DEST/LAST-BACKUP.txt'" 2>/dev/null || true
    log "\"status\":\"ok\",\"dest\":\"$SSH_HOST:$REMOTE_DEST\""
else
    log "\"status\":\"partial\",\"rc\":$rc"; exit 75
fi
