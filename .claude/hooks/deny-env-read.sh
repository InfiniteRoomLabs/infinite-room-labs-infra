#!/usr/bin/env bash
# Hook: PreToolUse (Read)
# Denies any attempt to read .env files via the Read tool.
set -euo pipefail

input=$(cat)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty')
base=$(basename "$file_path" 2>/dev/null || true)

if [ "$base" = ".env" ]; then
  cat >&2 <<'EOF'
{"hookSpecificOutput":{"permissionDecision":"deny"},"systemMessage":"Reading .env files is prohibited by project policy."}
EOF
  exit 2
fi
