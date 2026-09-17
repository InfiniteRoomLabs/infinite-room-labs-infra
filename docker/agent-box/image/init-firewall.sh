#!/usr/bin/env bash
# docker/agent-box/image/init-firewall.sh
# Egress DENYLIST firewall for the agent box.
#
# Policy after this runs:
#   OUTPUT: ACCEPT everything except destinations in the `agent-box-deny`
#           ipset (built from /etc/agent-box/denylist.txt), which are REJECTed.
#   INPUT / FORWARD: untouched (Docker's defaults; nothing listens anyway).
#
# Denylist format (one entry per line, `#` comments):
#   example.com        resolve A records now and block those IPs
#   10.0.0.0/8         block a CIDR as-is
#   1.2.3.4            block an address
#
# Limits worth knowing: names are resolved ONCE at container start, so a
# blocked service that rotates addresses can slip through later (restart the
# box to re-resolve). IPv6 entries are accepted in the file but only IPv4 is
# enforced (the container has no IPv6 route by default).
#
# Needs CAP_NET_ADMIN + CAP_NET_RAW and runs via the single sudoers rule the
# image grants the `agent` user. Nothing is flushed: the script only adds
# its own set and one OUTPUT rule, so Docker's DNS NAT rules are untouched.
set -euo pipefail
IFS=$'\n\t'

DENYLIST="${AGENT_BOX_DENYLIST:-/etc/agent-box/denylist.txt}"
SET_NAME="agent-box-deny"
CANARY="${AGENT_BOX_FIREWALL_CANARY:-example.com}"

log() { printf 'init-firewall: %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

is_ipv4() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; }
is_cidr() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]; }
is_ipv6() { [[ "$1" == *:* ]]; }

[[ -r "$DENYLIST" ]] || die "denylist not readable: $DENYLIST"

# 1. Fresh set (idempotent on re-runs inside the same container).
ipset destroy "$SET_NAME" 2>/dev/null || true
ipset create "$SET_NAME" hash:net

add_domain() {
  local domain="$1" ip found=0
  while read -r ip; do
    [[ -n "$ip" ]] || continue
    is_ipv4 "$ip" || die "unexpected DNS answer for $domain: $ip"
    ipset add -exist "$SET_NAME" "$ip"
    found=1
  done < <(dig +short +time=5 +tries=2 A "$domain" | grep -E '^[0-9.]+$' || true)
  [[ "$found" == 1 ]] || log "WARN: $domain resolved to nothing; not blocked"
}

while IFS= read -r line; do
  line="${line%%#*}"; line="${line//[[:space:]]/}"
  [[ -n "$line" ]] || continue
  if is_ipv6 "$line"; then
    continue                       # accepted in the file, not enforced (no v6 route)
  elif is_cidr "$line"; then
    ipset add -exist "$SET_NAME" "$line"
  elif is_ipv4 "$line"; then
    ipset add -exist "$SET_NAME" "$line"
  else
    add_domain "$line"
  fi
done <"$DENYLIST"

# 2. One rule, at the top of OUTPUT: reject anything headed for the set.
iptables -D OUTPUT -m set --match-set "$SET_NAME" dst -j REJECT --reject-with icmp-admin-prohibited 2>/dev/null || true
iptables -I OUTPUT 1 -m set --match-set "$SET_NAME" dst -j REJECT --reject-with icmp-admin-prohibited
iptables -P OUTPUT ACCEPT

entries="$(ipset list "$SET_NAME" | grep -c '^[0-9]' || true)"

# 3. Self-test: the world is reachable, the canary is not.
if curl -sS --max-time 8 -o /dev/null https://api.anthropic.com/ 2>/dev/null; then
  log "verified: api.anthropic.com reachable (default allow)"
else
  die "self-test failed: api.anthropic.com unreachable; the container has no egress at all"
fi
if grep -qE "^${CANARY//./\\.}\s*($|#)" "$DENYLIST"; then
  if curl -sS --max-time 5 -o /dev/null "https://$CANARY/" 2>/dev/null; then
    die "self-test failed: denylisted canary $CANARY is reachable; the firewall is not enforcing"
  fi
  log "verified: denylisted canary $CANARY is blocked ($entries entries denied)"
else
  log "note: canary $CANARY is not in the denylist; enforcement not self-tested ($entries entries denied)"
fi

# 4. World-readable marker so unprivileged checks (doctor) can see the state.
mkdir -p /run/agent-box
printf 'active mode=denylist %s entries=%s\n' "$(date -u +%FT%TZ)" "$entries" >/run/agent-box/firewall
chmod 0644 /run/agent-box/firewall
