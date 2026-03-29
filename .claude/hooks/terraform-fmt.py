#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""PostToolUse hook: runs `terraform fmt` on .tf files after edits."""

import json
import subprocess
import sys

tool_input = json.loads(sys.stdin.read())
file_path = tool_input.get("tool_input", {}).get("file_path", "")

if file_path.endswith(".tf"):
    subprocess.run(
        ["terraform", "fmt", file_path],
        capture_output=True,
    )
