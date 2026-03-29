#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""PreToolUse hook: blocks direct edits to vault.yml.

vault.yml is managed exclusively by bw-sync.sh. This hook prevents
Claude from writing to it via Edit or Write tools.
"""

import json
import sys

tool_input = json.loads(sys.stdin.read())
file_path = tool_input.get("tool_input", {}).get("file_path", "")

if file_path.endswith("vault.yml"):
    result = {
        "hookSpecificOutput": {"permissionDecision": "deny"},
        "systemMessage": (
            "vault.yml is managed exclusively by bw-sync.sh. "
            "Never edit it directly. Use: ./scripts/bw-sync.sh --target ansible"
        ),
    }
    print(json.dumps(result), file=sys.stderr)
    sys.exit(2)
