#!/usr/bin/env bash
# docker/agent-box/image/init-firewall.sh
# Default-deny egress firewall for the agent box, adapted from Anthropic's
# reference dev container (anthropics/claude-code/.devcontainer/init-firewall.sh).
#
# Policy after this runs:
#   OUTPUT: DROP everything except DNS, loopback, and destinations in the
#           `agent-box-allow` ipset (built from /etc/agent-box/allowlist.txt).
#   INPUT:  DROP everything except loopback and replies to our own traffic.
#   FORWARD: DROP.
#
# Allowlist format (one entry per line, `#` comments):
#   example.com        resolve A records now and allow those IPs
#   10.0.0.0/8         allow a CIDR as-is
#   @github            expand to GitHub's published web/api/git ranges
#
# Limits worth knowing: names are resolved ONCE at container start, so a CDN
# that rotates addresses mid-session can start failing (restart the box).
# Nothing here restricts ports on an allowed destination.
#
# Needs CAP_NET_ADMIN + CAP_NET_RAW and runs via the single sudoers rule the
# image grants the `agent` user.
set -euo pipefail
IFS=$'\n\t'

ALLOWLIST="${AGENT_BOX_ALLOWLIST:-/etc/agent-box/allowlist.txt}"
SET_NAME="agent-box-allow"

log() { printf 'init-firewall: %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

is_ipv4()  { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; }
is_cidr()  { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]; }

[[ -r "$ALLOWLIST" ]] || die "allowlist not readable: $ALLOWLIST"

# 1. Remember Docker's embedded-DNS NAT rules before flushing; we put them back.
docker_dns_rules="$(iptables-save -t nat 2>/dev/null | grep '127\.0\.0\.11' || true)"

iptables -F; iptables -X
iptables -t nat -F; iptables -t nat -X
iptables -t mangle -F; iptables -t mangle -X
ipset destroy "$SET_NAME" 2>/dev/null || true

if [[ -n "$docker_dns_rules" ]]; then
  iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
  iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
  while IFS= read -r rule; do
    # shellcheck disable=SC2086  # the saved rule is meant to be word-split
    iptables -t nat $rule
  done <<<"$docker_dns_rules"
fi

# 2. Always-allowed plumbing: DNS, loopback, replies.
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A INPUT  -p udp --sport 53 -j ACCEPT
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# 3. Build the allow set.
ipset create "$SET_NAME" hash:net

add_github_ranges() {
  local meta cidr
  meta="$(curl -fsS --max-time 20 https://api.github.com/meta)" || die "could not fetch GitHub IP ranges"
  echo "$meta" | jq -e '.web and .api and .git' >/dev/null || die "GitHub meta response missing fields"
  while read -r cidr; do
    is_cidr "$cidr" || die "unexpected CIDR from GitHub meta: $cidr"
    ipset add -exist "$SET_NAME" "$cidr"
  done < <(echo "$meta" | jq -r '(.web + .api + .git)[]' | aggregate -q)
  log "added GitHub ranges"
}

add_domain() {
  local domain="$1" ip found=0
  while read -r ip; do
    [[ -n "$ip" ]] || continue
    is_ipv4 "$ip" || die "unexpected DNS answer for $domain: $ip"
    ipset add -exist "$SET_NAME" "$ip"
    found=1
  done < <(dig +short +time=5 +tries=2 A "$domain" | grep -E '^[0-9.]+$' || true)
  if [[ "$found" == 0 ]]; then
    log "WARN: $domain resolved to nothing; not allowed"
  fi
}

while IFS= read -r line; do
  line="${line%%#*}"; line="${line//[[:space:]]/}"
  [[ -n "$line" ]] || continue
  case "$line" in
    @github)      add_github_ranges ;;
    @*)           die "unknown macro in allowlist: $line" ;;
    */*)          is_cidr "$line" || die "bad CIDR: $line"; ipset add -exist "$SET_NAME" "$line" ;;
    *)            if is_ipv4 "$line"; then ipset add -exist "$SET_NAME" "$line"; else add_domain "$line"; fi ;;
  esac
done <"$ALLOWLIST"

# 4. The host side of Docker's bridge (default route) stays reachable so
#    Docker DNS and host-published ports keep working.
host_ip="$(ip route | awk '/default/ {print $3; exit}')"
[[ -n "$host_ip" ]] || die "could not detect the container's default gateway"
host_net="${host_ip%.*}.0/24"
iptables -A INPUT  -s "$host_net" -j ACCEPT
iptables -A OUTPUT -d "$host_net" -j ACCEPT

# 5. Default deny, then the allow set.
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP
iptables -A OUTPUT -m set --match-set "$SET_NAME" dst -j ACCEPT
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# 6. Self-test: an allowed host answers, an unlisted one does not.
if curl -fsS --max-time 8 -o /dev/null -w '%{http_code}' https://api.anthropic.com/ >/dev/null 2>&1 \
   || curl -sS --max-time 8 -o /dev/null https://api.anthropic.com/ 2>/dev/null; then
  log "verified: api.anthropic.com reachable"
else
  die "self-test failed: api.anthropic.com is NOT reachable through the allow set"
fi
if curl -sS --max-time 5 -o /dev/null https://example.com/ 2>/dev/null; then
  die "self-test failed: example.com is reachable; the firewall is not enforcing"
fi
log "verified: unlisted hosts are blocked ($(ipset list "$SET_NAME" | grep -c '^[0-9]') entries allowed)"

# 7. Leave a world-readable marker so unprivileged checks (doctor) can tell
#    the policy is up without needing iptables access.
mkdir -p /run/agent-box
printf 'active %s entries=%s\n' "$(date -u +%FT%TZ)" "$(ipset list "$SET_NAME" | grep -c '^[0-9]')" >/run/agent-box/firewall
chmod 0644 /run/agent-box/firewall
