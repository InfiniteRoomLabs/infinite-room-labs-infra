#!/usr/bin/env bash
# docker/agent-box/tests/unattended.sh
# Smoke test for the unattended modes: `agent-box.sh batch` and `mcp`.
#
#   ./tests/unattended.sh          (or: task test)
#
# Needs only docker and a built image. It runs against a THROWAWAY home
# volume (AGENT_BOX_SMOKE_VOLUME, removed afterwards), so it never touches
# your logins and never calls the model: a logged-out box answers "Not
# logged in" at once, which is enough to prove the plumbing. The runner's
# outcome-to-exit-code mapping is checked against a fake `claude` on PATH.
#
# What it proves: usage errors exit 64 before the box boots; batch stdout
# is exactly the result (text) or one JSON object (json); exit codes 0, 2,
# 3, 4, 124 come out of the box unchanged; the MCP server's stdout is pure
# JSON-RPC (no banner, no entrypoint chatter); a killed wrapper leaves no
# container behind; the firewall is still up in both modes.
# shellcheck disable=SC2015  # `test && pass || fail` is safe: pass always returns 0
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOX="$SCRIPT_DIR/../agent-box.sh"
export AGENT_BOX_VOLUME="${AGENT_BOX_SMOKE_VOLUME:-irl-agent-box-smoke}"
IMAGE="$("$BOX" config 2>/dev/null | awk '$1 == "AGENT_BOX_IMAGE" {print $2; exit}')"

fails=0
pass() { printf '  \e[32mPASS\e[0m  %s\n' "$*"; }
fail() { printf '  \e[31mFAIL\e[0m  %s\n' "$*"; fails=$((fails + 1)); }
expect_rc() { if [[ "$2" == "$3" ]]; then pass "$1 (exit $2)"; else fail "$1: expected exit $3, got $2"; fi; }
dockr() { MSYS_NO_PATHCONV=1 docker "$@"; }
# jq from the host if it has one, else from the image (the host needs only docker).
jqq() { if command -v jq >/dev/null 2>&1; then jq "$@"; else dockr run --rm -i --entrypoint jq "$IMAGE" "$@"; fi; }
leftovers() { dockr ps -aq --filter "name=agent-box-$1-"; }

work="$(mktemp -d)"
cleanup() {
  rm -rf "$work"
  dockr volume rm -f "$AGENT_BOX_VOLUME" >/dev/null 2>&1 || true
}
trap cleanup EXIT
[[ -n "$IMAGE" ]] || { echo "could not read AGENT_BOX_IMAGE from '$BOX config'" >&2; exit 1; }
printf 'image %s, throwaway volume %s, dir %s\n' "$IMAGE" "$AGENT_BOX_VOLUME" "$work"

printf '\n\e[1mbatch: argument handling (host side, no box)\e[0m\n'
"$BOX" batch --output xml hi >/dev/null 2>&1; expect_rc "bad --output" $? 64
"$BOX" batch --timeout soon hi >/dev/null 2>&1; expect_rc "bad --timeout" $? 64
"$BOX" batch -f "$work/missing.txt" >/dev/null 2>&1; expect_rc "unreadable --prompt-file" $? 64
"$BOX" batch --dir "$HOME" hi >/dev/null 2>&1; expect_rc "refuses to mount \$HOME" $? 64

printf '\n\e[1mbatch: a real box, logged out\e[0m\n'
"$BOX" batch --dir "$work" </dev/null >"$work/out" 2>"$work/err"; expect_rc "empty stdin prompt is rejected inside the box" $? 64
"$BOX" batch --dir "$work" -o json "say hi" >"$work/out" 2>"$work/err"; rc=$?
expect_rc "logged-out run is an agent error" "$rc" 2
if [[ "$(wc -l <"$work/out")" -eq 1 ]] && jqq -e '.type == "result" and .is_error == true' <"$work/out" >/dev/null; then
  pass "json: stdout is exactly one result object"
else
  fail "json: stdout is not one result object: $(head -c 300 "$work/out")"
fi
grep -q 'verified: denylisted canary' "$work/err" && pass "firewall came up (self-test on stderr)" || fail "no firewall self-test line on stderr"
printf 'say hi\n' | "$BOX" batch --dir "$work" >"$work/out" 2>"$work/err"; rc=$?
expect_rc "prompt from stdin, text output" "$rc" 2
if grep -q 'logged in' "$work/out" && ! grep -q 'agent-box' "$work/out"; then pass "text: stdout is the result only"; else fail "text: unexpected stdout: $(head -c 300 "$work/out")"; fi
[[ -z "$(leftovers batch)" ]] && pass "no batch containers left behind" || fail "batch containers left: $(leftovers batch)"

printf '\n\e[1mbatch runner: outcome -> exit code (fake claude)\e[0m\n'
# One box, several cases. Each case prints "name rc first-line-of-stdout".
# shellcheck disable=SC2016  # expanded inside the box
cases='
set -u; mkdir -p /tmp/fake; export PATH=/tmp/fake:$PATH
fake() { printf "#!/bin/sh\ncat >/dev/null\n%s\n" "$1" >/tmp/fake/claude; chmod +x /tmp/fake/claude; }
run() { local n=$1; shift; out=$(echo prompt | agent-box-batch "$@" 2>/dev/null); echo "$n $? $(printf %s "$out" | head -n1)"; }
fake "echo {\\\"type\\\":\\\"result\\\",\\\"subtype\\\":\\\"success\\\",\\\"is_error\\\":false,\\\"result\\\":\\\"hello\\\"}"; run success
fake "echo {\\\"type\\\":\\\"result\\\",\\\"subtype\\\":\\\"error_max_turns\\\",\\\"is_error\\\":true}; exit 1"; run maxturns --max-turns 2
fake "echo boom >&2; exit 1"; run noresult --output json
fake "sleep 60"; run timeout --timeout 2s --output json
'
"$BOX" compose run --rm -T box bash -c "$cases" >"$work/cases" 2>"$work/err"
check_case() {
  local line; line="$(grep "^$1 " "$work/cases")"
  if [[ "$line" == "$1 $2"* && "$line" == *"$3"* ]]; then pass "$1 -> exit $2"; else fail "$1: expected '$1 $2 ...$3', got '$line'"; fi
}
check_case success 0 hello
check_case maxturns 3 ""
check_case noresult 4 error_no_result
check_case timeout 124 error_timeout

printf '\n\e[1mmcp: stdio is protocol only\e[0m\n'
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}'
{ printf '%s\n' "$init" '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'; sleep 45; } \
  | "$BOX" mcp --dir "$work" >"$work/mcp" 2>"$work/err"
if [[ -s "$work/mcp" ]] && jqq -c . <"$work/mcp" >/dev/null 2>&1 && [[ "$(head -c1 "$work/mcp")" == "{" ]]; then
  pass "every stdout line is JSON ($(wc -l <"$work/mcp") messages)"
else
  fail "stdout is not clean JSON-RPC: $(head -c 300 "$work/mcp")"
fi
jqq -se 'map(select(.id == 1))[0].result.serverInfo.name' <"$work/mcp" >/dev/null 2>&1 && pass "initialize answered" \
  || fail "no initialize result: $(head -n1 "$work/mcp" | head -c 300)"
n="$(jqq -sr 'map(select(.id == 2))[0].result.tools | length' <"$work/mcp" 2>/dev/null)"
[[ "${n:-0}" -gt 0 ]] && pass "tools/list returned $n tools" || fail "tools/list returned nothing"
[[ -z "$(leftovers mcp)" ]] && pass "stdin EOF ends the server and removes the container" || fail "mcp containers left: $(leftovers mcp)"

printf '\n\e[1mmcp: a killed wrapper leaves nothing running\e[0m\n'
"$BOX" mcp --dir "$work" < <(sleep 120) >/dev/null 2>&1 &
wrapper=$!
for _ in $(seq 1 60); do [[ -n "$(leftovers mcp)" ]] && break; sleep 1; done
[[ -n "$(leftovers mcp)" ]] && pass "server container started" || fail "server container never appeared"
# While it runs: the only bind is --dir (at /work/<basename>, since the temp
# dir is outside the workspace), next to the home volume. Nothing else.
mounts="$(dockr inspect --format '{{range .Mounts}}{{.Type}}:{{.Destination}} {{end}}' "$(leftovers mcp | head -n1)" 2>/dev/null | xargs -n1 | sort | xargs)"
want="$(printf '%s\n' "bind:/work/$(basename "$work")" volume:/home/agent | sort | xargs)"
[[ "$mounts" == "$want" ]] && pass "scoped: mounts are exactly '$want'" || fail "scoped: mounts are '$mounts', expected '$want'"
kill -TERM "$wrapper" 2>/dev/null; wait "$wrapper" 2>/dev/null
for _ in $(seq 1 20); do [[ -z "$(leftovers mcp)" ]] && break; sleep 1; done
[[ -z "$(leftovers mcp)" ]] && pass "SIGTERM to the wrapper removed the container" || fail "container survived SIGTERM: $(leftovers mcp)"

printf '\n%d fail\n' "$fails"
[[ "$fails" == 0 ]]
