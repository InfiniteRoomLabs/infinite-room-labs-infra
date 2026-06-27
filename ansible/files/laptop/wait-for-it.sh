#!/usr/bin/env bash
# wait-for-it.sh -- poll a readiness probe until it passes or a timeout elapses.
#
# A boot/resume gate: a dependency (Tailscale, a host:port, the network) often
# needs a few seconds after wake before it is usable; a one-shot check loses that
# race. This blocks (bounded) until the probe succeeds.
#
# Usage:
#   wait-for-it.sh --tcp HOST:PORT [--timeout SECS] [--interval SECS]
#   wait-for-it.sh [--timeout SECS] [--interval SECS] -- PROBE_CMD [ARGS...]
#
# --tcp uses bash /dev/tcp (no raw socket, so it works under NoNewPrivileges,
# unlike ping). Otherwise PROBE_CMD is run each tick; a 0 exit means "ready".
#
# Exit: 0 as soon as the probe passes; 124 (the `timeout` convention) if it never
# does within --timeout. Plain bash on purpose (no `usage` shebang): this runs in
# systemd/ansible contexts where the usage interpreter mis-parses the script.
set -uo pipefail

timeout=120
interval=5
tcp=""

while [ $# -gt 0 ]; do
    case "$1" in
        --tcp)      tcp="$2"; shift 2 ;;
        --timeout)  timeout="$2"; shift 2 ;;
        --interval) interval="$2"; shift 2 ;;
        --)         shift; break ;;
        -*)         echo "wait-for-it: unknown option: $1" >&2; exit 64 ;;
        *)          break ;;
    esac
done

if [ -n "$tcp" ]; then
    host="${tcp%:*}"; port="${tcp##*:}"
    probe() { timeout 4 bash -c ": > /dev/tcp/$host/$port" 2>/dev/null; }
elif [ $# -gt 0 ]; then
    probe() { "$@"; }
else
    echo "wait-for-it: need --tcp HOST:PORT or -- PROBE_CMD" >&2; exit 64
fi

deadline=$(( SECONDS + timeout ))
while :; do
    if probe "$@"; then exit 0; fi
    [ "$SECONDS" -ge "$deadline" ] && exit 124
    sleep "$interval"
done
