#!/usr/bin/env bash
# scripts/includes/bw-session.sh
# Shared BW_SESSION resolver. Source this file -- do not execute it directly.
#
# Single session store: ~/.bw_session (written by the fish `bw-unlock`
# function, chmod 600). Every shell on this machine -- fish, interactive bash,
# and agent bash (via BASH_ENV) -- loads BW_SESSION from it at startup, so the
# env candidate is normally already correct. The file candidate covers shells
# started before the last unlock. There is no fnox-stored session copy.
#
# Session keys have no inactivity TTL, but any subsequent unlock/lock/logout
# may invalidate cached keys -- so every candidate is validated with `bw
# status` before use. Recovery is `bw-unlock` (fish) or
# scripts/bw-unlock-prompt.sh; never raw `bw unlock --raw`, which rotates the
# key without updating the cache.
#
# Usage:  source ".../includes/bw-session.sh"; resolve_bw_session || exit 1
# On success exports a validated BW_SESSION and returns 0; on failure prints
# a caller-named message to stderr and returns 1 (never exits -- safe to
# source under `set -euo pipefail`).

_bw_session_ok() {
  [[ -n "$1" ]] && BW_SESSION="$1" bw status 2>/dev/null | grep -q '"status": *"unlocked"'
}

resolve_bw_session() {
  local cache="$HOME/.bw_session" caller="${BASH_SOURCE[1]:-$0}" cand

  # 1. Inherited/explicit env (may be stale if the vault re-unlocked since).
  if _bw_session_ok "${BW_SESSION:-}"; then
    export BW_SESSION
    return 0
  fi

  # 2. The ~/.bw_session cache.
  if [[ -f "$cache" && -r "$cache" ]]; then
    if [[ "$(stat -c '%u %a' "$cache" 2>/dev/null)" != "$(id -u) 600" ]]; then
      echo "$(basename "$caller"): ignoring $cache (must be owned by you, mode 600)" >&2
    else
      cand="$(<"$cache")"
      cand="${cand//[$'\t\r\n ']/}"
      if _bw_session_ok "$cand"; then
        export BW_SESSION="$cand"
        return 0
      fi
    fi
  fi

  echo "$(basename "$caller"): no valid BW_SESSION (vault locked or session rotated) -- run scripts/bw-unlock-prompt.sh, then retry" >&2
  return 1
}
