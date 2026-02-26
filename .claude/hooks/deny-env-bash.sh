#!/usr/bin/env bash
# Hook: PreToolUse (Bash)
# Denies any Bash command that attempts to read .env files.
set -euo pipefail

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // empty')

# Match common read commands targeting .env files
# Covers: cat, head, tail, less, more, bat, sed, awk, source, and dot-source
if echo "$cmd" | grep -qP '(^|[;&|\s])(cat|head|tail|less|more|bat|sed|awk|source|\.)\s+.*\.env(\s|$|[;&|])'; then
  cat >&2 <<'EOF'
{"hookSpecificOutput":{"permissionDecision":"deny"},"systemMessage":"Reading .env files via Bash is prohibited by project policy."}
EOF
  exit 2
fi
