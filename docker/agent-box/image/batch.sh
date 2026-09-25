#!/usr/bin/env bash
# docker/agent-box/image/batch.sh  (installed as agent-box-batch)
# In-box runner for `agent-box.sh batch`: read a prompt on stdin, run Claude
# Code non-interactively until it finishes, print its output, and turn the
# outcome into an exit code a caller can branch on.
#
#   echo "prompt" | agent-box-batch [--output text|json|stream-json]
#                                   [--timeout DUR] [--max-turns N]
#                                   [--permission-mode MODE] [-- claude args...]
#
# stdout carries ONLY the agent's output (the result text, one JSON object,
# or the stream-json lines). Everything else goes to stderr.
#
# Exit codes (the host wrapper passes them through unchanged):
#   0    the agent finished and reported success
#   2    the agent finished with an error result (API error, not logged in, ...)
#   3    the agent hit --max-turns before finishing
#   4    claude exited without producing a result at all
#   64   usage error (bad option, empty prompt)
#   124  --timeout expired; the agent was killed
# (1 is left to the entrypoint and the wrapper: "the box could not run".)
#
# Claude always runs with --output-format json or stream-json, so the
# outcome is read from its result object rather than guessed from its exit
# status; text mode prints that object's `result` field.
set -uo pipefail

log() { printf 'agent-box-batch: %s\n' "$*" >&2; }
usage_error() { log "$*"; exit 64; }

output=text timeout=30m max_turns="" permission_mode=acceptEdits
extra=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)          output="${2:-}"; shift 2 || usage_error "--output needs a value" ;;
    --timeout)         timeout="${2:-}"; shift 2 || usage_error "--timeout needs a value" ;;
    --max-turns)       max_turns="${2:-}"; shift 2 || usage_error "--max-turns needs a value" ;;
    --permission-mode) permission_mode="${2:-}"; shift 2 || usage_error "--permission-mode needs a value" ;;
    --)                shift; extra=("$@"); break ;;
    *)                 usage_error "unknown option: $1" ;;
  esac
done

case "$output" in text|json|stream-json) ;; *) usage_error "--output must be text, json or stream-json (got '$output')" ;; esac
[[ "$timeout" =~ ^[0-9]+[smhd]?$ ]] || usage_error "--timeout must look like 600, 90s, 30m or 2h (got '$timeout'); 0 disables it"
[[ -z "$max_turns" || "$max_turns" =~ ^[1-9][0-9]*$ ]] || usage_error "--max-turns must be a positive integer (got '$max_turns')"

prompt="$(cat)"
[[ -n "${prompt//[[:space:]]/}" ]] || usage_error "empty prompt on stdin"

claude_args=(-p --permission-mode "$permission_mode" --permission-prompts none)
if [[ "$output" == stream-json ]]; then
  claude_args+=(--output-format stream-json --verbose)   # claude requires --verbose for it
else
  claude_args+=(--output-format json)
fi
[[ -n "$max_turns" ]] && claude_args+=(--max-turns "$max_turns")
claude_args+=("${extra[@]}")

out="$(mktemp)"
trap 'rm -f "$out"' EXIT

# `timeout` sends TERM, then KILL 30s later if claude ignores it. The prompt
# goes in on stdin, not argv, so its size and quoting never matter.
log "running claude (${permission_mode}, timeout ${timeout}, max turns ${max_turns:-default}) in $(pwd)"
if [[ "$output" == stream-json ]]; then
  timeout --kill-after=30s "$timeout" claude "${claude_args[@]}" <<<"$prompt" | tee "$out"
  rc=${PIPESTATUS[0]}
else
  timeout --kill-after=30s "$timeout" claude "${claude_args[@]}" <<<"$prompt" >"$out"
  rc=$?
fi

# emit_synthetic SUBTYPE MESSAGE: in json modes, a result-shaped object so
# a caller can always parse stdout, even when claude produced nothing.
emit_synthetic() {
  [[ "$output" == text ]] && return 0
  jq -cn --arg subtype "$1" --arg msg "$2" --argjson rc "$rc" \
    '{type: "result", subtype: $subtype, is_error: true, result: $msg, agent_box_exit: $rc}'
}

if [[ "$rc" == 124 || "$rc" == 137 ]]; then
  log "timed out after $timeout; the agent was stopped"
  emit_synthetic error_timeout "agent-box: timed out after $timeout"
  exit 124
fi

# The last result object in the output (json: the only line; stream-json:
# the final line). Non-JSON lines are skipped rather than fatal.
result="$(jq -cR 'fromjson? | select(type == "object" and .type == "result")' "$out" 2>/dev/null | tail -n 1)"
if [[ -z "$result" ]]; then
  log "claude exited $rc without a result; its output follows on stderr"
  cat "$out" >&2
  emit_synthetic error_no_result "agent-box: claude exited $rc without a result"
  exit 4
fi

case "$output" in
  text) jq -r '.result // empty' <<<"$result" ;;
  json) printf '%s\n' "$result" ;;
  stream-json) ;;   # already streamed through tee
esac

# One human line on stderr: how it went and how to pick the session back up.
jq -r '"done: \(.subtype // "?"), \(.num_turns // "?") turns, $\(.total_cost_usd // 0), session \(.session_id // "?")"' <<<"$result" \
  | sed 's/^/agent-box-batch: /' >&2

subtype="$(jq -r '.subtype // ""' <<<"$result")"
reason="$(jq -r '.terminal_reason // ""' <<<"$result")"
is_error="$(jq -r '.is_error // false' <<<"$result")"
if [[ "$subtype" == error_max_turns || "$reason" == max_turns ]]; then
  exit 3
elif [[ "$is_error" == true || "$subtype" == error_* ]]; then
  exit 2
fi
exit 0
