#!/usr/bin/env bash
# docker/agent-box/image/mcp.sh  (installed as agent-box-mcp)
# In-box half of `agent-box.sh mcp`: Claude Code's MCP server
# (`claude mcp serve`) on stdio, stopped when the client goes away.
#
# Why not exec `claude mcp serve` directly: it does not reliably exit when
# its stdin closes (seen with 2.1.273 when the client never completed the
# handshake, e.g. a health check that connects and hangs up, and when a
# Windows client kills the wrapper outright). The container, and the
# docker client on the host, then run on with nobody attached. Here stdin
# is relayed through a FIFO; once the client closes it the server gets EOF
# as well, a few seconds to finish, then SIGTERM.
#
# stdout is the server's alone; this script writes only to stderr.
set -uo pipefail

GRACE="${AGENT_BOX_MCP_GRACE:-5}"   # seconds between client EOF and SIGTERM

fifo="$(mktemp -u)"
mkfifo -m 600 "$fifo"
trap 'rm -f "$fifo"' EXIT

claude mcp serve <"$fifo" &
server=$!
cat 0<&0 >"$fifo" &   # explicit 0<&0: an async command otherwise reads /dev/null
relay=$!

# Whichever ends first: the server (pass its status on) or the relay (the
# client closed stdin).
wait -n -p first "$server" "$relay"
rc=$?
if [[ "${first:-}" == "$server" ]]; then
  kill "$relay" 2>/dev/null
  exit "$rc"
fi

for _ in $(seq 1 $((GRACE * 2))); do
  kill -0 "$server" 2>/dev/null || break
  sleep 0.5
done
if kill -0 "$server" 2>/dev/null; then
  printf 'agent-box-mcp: client closed stdin; stopping the server\n' >&2
  kill -TERM "$server" 2>/dev/null
  wait "$server"
  exit 0          # the client hung up: a normal end of session
fi
wait "$server"
