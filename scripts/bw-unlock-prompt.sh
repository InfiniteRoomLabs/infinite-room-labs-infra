#!/usr/bin/env bash
set -euo pipefail

# scripts/bw-unlock-prompt.sh
# Agent-callable attention grabber: spawns a terminal window front and center
# asking the user to unlock Bitwarden, then detaches and exits immediately.
# It does NOT wait for the unlock -- after spawning, poll `bw status` or just
# retry the failed command once the user says done.
#
# The spawned session refreshes BOTH session stores, in order:
#   1. bw-unlock (fish)  -> writes ~/.bw_session
#   2. fnox set          -> refreshes the age-encrypted BW_SESSION that
#                           with-secrets.sh / vault-pass.sh resolve FIRST.
# Refreshing only ~/.bw_session is not enough: a stale fnox entry shadows it.

UNLOCK_CMD='
  echo "== Agent needs the Bitwarden vault unlocked =="
  bw-unlock
  and cat ~/.bw_session | fnox set BW_SESSION --provider age -g
  and echo "Unlocked; fnox session refreshed. Closing in 3s..."
  and sleep 3
  or begin
    echo "Unlock failed or was cancelled. Close this window and retry."
    sleep 15
  end
'

if command -v ghostty >/dev/null 2>&1; then
  setsid -f ghostty --title="== BITWARDEN UNLOCK NEEDED ==" \
    -e fish -c "$UNLOCK_CMD" >/dev/null 2>&1 || true
elif command -v gnome-terminal >/dev/null 2>&1; then
  setsid -f gnome-terminal --title="== BITWARDEN UNLOCK NEEDED ==" \
    -- fish -c "$UNLOCK_CMD" >/dev/null 2>&1 || true
else
  echo "No supported terminal (ghostty/gnome-terminal) found." >&2
  exit 1
fi

echo "Unlock prompt spawned. Wait for the user to unlock, then poll: bw status"
