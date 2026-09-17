#!/usr/bin/env bash
# docker/agent-box/image/doctor.sh
# The box's acceptance test. Runs INSIDE the container and reports what
# works, what needs a one-time login, and what is broken.
#
#   PASS  usable now
#   WARN  a one-time setup step is missing (the line says which)
#   FAIL  the box is misbuilt or misrun
#
# Exit status is 1 only on FAIL, so WARNs on a fresh volume are expected.
set -uo pipefail

REPO="${AGENT_BOX_REPO_DIR:-/work/infinite-room-labs-infra}"
fails=0; warns=0

pass() { printf '  \e[32mPASS\e[0m  %s\n' "$*"; }
warn() { printf '  \e[33mWARN\e[0m  %s\n' "$*"; warns=$((warns + 1)); }
fail() { printf '  \e[31mFAIL\e[0m  %s\n' "$*"; fails=$((fails + 1)); }
section() { printf '\n\e[1m%s\e[0m\n' "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }
# ver TOOL: one line of version output. A few tools spell it differently.
ver() {
  case "$1" in
    helm)    helm version --short 2>/dev/null ;;
    kubectl) kubectl version --client 2>/dev/null ;;
    ssh)     ssh -V 2>&1 ;;
    *)       "$1" --version 2>/dev/null ;;
  esac | head -1 | tr -d '\r'
}

section "Identity and layout"
if [[ "$(id -u)" == "0" ]]; then fail "running as root (Claude Code refuses --dangerously-skip-permissions as root)"; else pass "non-root user $(id -un) (uid $(id -u))"; fi
if [[ -d /work && -w /work ]]; then pass "/work is mounted and writable"; else fail "/work missing or read-only (host wrapper mounts ~/Projects here)"; fi
if [[ -d "$REPO" ]]; then
  pass "infra repo present at $REPO"
  if git -C "$REPO" rev-parse --show-toplevel >/dev/null 2>&1; then pass "git works on the bind-mounted repo (safe.directory set)"; else fail "git refuses $REPO (dubious ownership?); the image should set safe.directory '*'"; fi
else
  warn "infra repo not at $REPO (set AGENT_BOX_REPO_DIR or clone it under /work)"
fi
if [[ "${CLAUDE_CONFIG_DIR:-}" == "$HOME/.claude" && -w "$HOME/.claude" ]]; then pass "CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR (on the home volume)"; else fail "CLAUDE_CONFIG_DIR not set to a writable $HOME/.claude"; fi
if mountpoint -q "$HOME" 2>/dev/null || grep -qs " $HOME " /proc/mounts; then pass "$HOME is a mounted volume (state persists)"; else warn "$HOME is not a mount; logins will vanish when the container exits"; fi

section "Toolchain"
for tool in claude mise node uv terraform terragrunt helm kubectl task fnox packer ansible-playbook gh tea bw jq git ssh shellcheck starship; do
  if have "$tool"; then pass "$tool  $(ver "$tool" | cut -c1-60)"; else fail "$tool missing from PATH"; fi
done
if [[ -d "$REPO" ]]; then
  if (cd "$REPO" && mise ls --current --missing 2>/dev/null | grep -q .); then
    warn "some mise pins in $REPO/mise.toml are not installed: run 'cd $REPO && mise install'"
  else
    pass "every pin in $REPO/mise.toml is installed"
  fi
fi
if ansible-galaxy collection list 2>/dev/null | grep -qE '^kubernetes\.core'; then pass "ansible collections present ($ANSIBLE_COLLECTIONS_PATH)"; else fail "ansible collections missing (kubernetes.core not found)"; fi
if [[ "${DISABLE_AUTOUPDATER:-}" == "1" ]]; then pass "Claude Code autoupdate disabled (image pin is authoritative)"; else warn "DISABLE_AUTOUPDATER is not 1; the CLI may drift from the image pin"; fi

section "Volume-scoped extras (agent-box-extras)"
if command -v ccsm-detect-secrets >/dev/null 2>&1 && command -v ccsm-check-output >/dev/null 2>&1; then
  pass "ccsm hooks present (the infra repo's PreToolUse/PostToolUse call them)"
else
  warn "ccsm not installed: run 'agent-box-extras' (needs the box's key on GitHub)"
fi
if [[ -d "$REPO" ]] && (cd "$REPO" && claude mcp get fnox 2>/dev/null | grep -qE "Scope: *Local"); then
  pass "fnox MCP overridden at local scope for the infra repo"
else
  warn "fnox MCP not overridden: .mcp.json points at a laptop path; run 'agent-box-extras'"
fi

section "Logins (one-time, persisted in the home volume)"
if [[ -s "$HOME/.claude/.claude.json" ]] && grep -q '"oauthAccount"' "$HOME/.claude/.claude.json" 2>/dev/null; then pass "Claude Code signed in"; else warn "Claude Code not signed in: run 'claude' once and follow the prompt"; fi
if gh auth status >/dev/null 2>&1; then pass "gh authenticated"; else warn "gh not authenticated: run 'gh auth login'"; fi
if (cd / && tea whoami >/dev/null 2>&1); then pass "tea login works"; else warn "tea has no working login: run 'tea login add'"; fi
case "$(bw status 2>/dev/null | jq -r .status 2>/dev/null)" in
  unlocked) pass "Bitwarden CLI unlocked" ;;
  locked)   warn "Bitwarden CLI logged in but locked: run 'bw unlock' and export BW_SESSION to ~/.bw_session (mode 600)" ;;
  *)        warn "Bitwarden CLI not logged in: run 'bw login'" ;;
esac
if [[ -f "$HOME/.config/fnox/config.toml" ]]; then
  pass "fnox global config present"
  if [[ -d "$REPO" ]] && (cd "$REPO" && fnox check >/dev/null 2>&1); then pass "fnox check passes in the repo"; else warn "fnox check fails (needs an unlocked Bitwarden session; see above)"; fi
else
  warn "no ~/.config/fnox/config.toml: copy it from the laptop (declares the bitwarden/age providers)"
fi

section "Reach"
if [[ -f "$HOME/.ssh/id_ed25519" ]]; then
  pass "box SSH identity exists ($(cut -d' ' -f3 "$HOME/.ssh/id_ed25519.pub" 2>/dev/null))"
  if ! grep -qs '^Host homelab-ts' "$HOME/.ssh/config"; then
    warn "no homelab-ts entry in ~/.ssh/config (AGENT_BOX_SSH_USER/AGENT_BOX_SSH_HOST were empty on the host side)"
  elif ssh -o BatchMode=yes -o ConnectTimeout=8 homelab-ts true 2>/dev/null; then pass "ssh homelab-ts works"; else warn "ssh homelab-ts failed: authorize the key ('agent-box.sh identity --authorize-homelab') or check Tailscale reach"; fi
else
  warn "no SSH identity yet: run 'agent-box.sh identity'"
fi
if [[ -f "$HOME/.kube/config" ]]; then
  if kubectl get nodes --request-timeout=10s >/dev/null 2>&1; then pass "kubectl reaches the cluster ($(kubectl config current-context 2>/dev/null))"; else warn "kubeconfig present but 'kubectl get nodes' failed (token revoked? network?)"; fi
else
  warn "no kubeconfig yet: run 'agent-box.sh kubeconfig'"
fi

section "Network policy"
if [[ "${AGENT_BOX_FIREWALL:-1}" == "1" ]]; then
  # iptables needs root; the firewall script leaves a readable marker instead.
  if grep -qs '^active' /run/agent-box/firewall; then pass "egress firewall active ($(cut -d' ' -f3 /run/agent-box/firewall))"; else fail "AGENT_BOX_FIREWALL=1 but init-firewall.sh left no /run/agent-box/firewall marker"; fi
  if curl -sS --max-time 6 -o /dev/null https://example.com/ 2>/dev/null; then fail "example.com reachable; allowlist is not enforced"; else pass "unlisted host blocked (example.com)"; fi
else
  warn "firewall disabled for this run (AGENT_BOX_FIREWALL=0)"
fi
if curl -sS --max-time 8 -o /dev/null https://api.anthropic.com/ 2>/dev/null; then pass "api.anthropic.com reachable"; else fail "api.anthropic.com unreachable"; fi

printf '\n%d fail, %d warn\n' "$fails" "$warns"
[[ "$fails" == 0 ]]
