#!/usr/bin/env bash
# docker/agent-box/image/extras.sh  (installed as agent-box-extras)
# Volume-scoped extras the image cannot bake in, because they need the
# box's own credentials (private repos over the box's SSH key) or a
# signed-in Claude Code. Idempotent; run it once per volume, and again
# after `docker volume rm`.
#
#   agent-box-extras            install/refresh everything below
#   agent-box-extras --status   report only
#
# What it does:
#   1. ccsm (Claude Code Secrets Manager) from the private org repo, via
#      `uv tool install git+ssh://...`, into ~/.local (the home volume, so
#      it survives image rebuilds). The infra repo's PreToolUse/PostToolUse
#      hooks call `ccsm-detect-secrets` and `ccsm-check-output`; without
#      them every Bash tool call in that repo logs a hook error.
#   2. A local-scope MCP override for `fnox` in the infra repo: its
#      committed .mcp.json points at a laptop-specific absolute path, and
#      local scope (claude mcp add -s local) wins over project scope.
set -euo pipefail

CCSM_GIT="${AGENT_BOX_CCSM_GIT:-git+ssh://git@github.com/InfiniteRoomLabs/claude-code-secrets-manager.git}"
REPO="${AGENT_BOX_REPO_DIR:-/work/infinite-room-labs-infra}"
export UV_TOOL_DIR="$HOME/.local/share/uv/tools" UV_TOOL_BIN_DIR="$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"

ok()   { printf '  \e[32mok\e[0m    %s\n' "$*"; }
todo() { printf '  \e[33mtodo\e[0m  %s\n' "$*"; }
fail() { printf '  \e[31mfail\e[0m  %s\n' "$*"; }

status_only=0
[[ "${1:-}" == "--status" ]] && status_only=1

printf '\e[1mccsm\e[0m\n'
if command -v ccsm-detect-secrets >/dev/null 2>&1 && command -v ccsm >/dev/null 2>&1; then
  ok "installed at $UV_TOOL_BIN_DIR ($(uv tool list 2>/dev/null | awk '/^ccsm /{print $2; exit}'))"
elif [[ "$status_only" == 1 ]]; then
  todo "not installed: run agent-box-extras"
else
  echo "  installing from $CCSM_GIT ..."
  if uv tool install --quiet --python 3.12 "$CCSM_GIT"; then
    ok "installed at $UV_TOOL_BIN_DIR"
  else
    fail "uv tool install failed. Does the box's SSH key have access to the repo? (agent-box.sh identity --github)"
  fi
fi

printf '\e[1mfnox MCP override (local scope, %s)\e[0m\n' "$REPO"
if [[ ! -d "$REPO" ]]; then
  todo "infra repo not at $REPO; skipped"
elif ! command -v claude >/dev/null 2>&1; then
  fail "claude not on PATH"
else
  cd "$REPO"
  if claude mcp get fnox 2>/dev/null | grep -qE "Scope: *Local"; then
    ok "fnox already overridden at local scope"
  elif [[ "$status_only" == 1 ]]; then
    todo "not overridden: run agent-box-extras"
  else
    if claude mcp add -s local fnox -- fnox mcp >/dev/null 2>&1; then
      ok "fnox -> 'fnox mcp' (mise shim) at local scope"
    else
      fail "claude mcp add failed (is Claude Code signed in? run 'claude' once)"
    fi
  fi
fi
