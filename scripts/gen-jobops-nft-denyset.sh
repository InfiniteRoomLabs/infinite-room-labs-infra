#!/usr/bin/env -S usage bash
set -euo pipefail

#USAGE flag "--pod-cidr <pod_cidr>" help="JobOps pod CIDR to fence (e.g. 10.42.7.0/24). Required." required=#true
#USAGE flag "--inventory <inventory>" help="Ansible inventory dir or hosts file to derive addresses from." default="../ansible/inventory/hosts.ini"
#USAGE flag "--output <output>" help="Write the snippet to this file instead of stdout."
#USAGE flag "--tailnet-iface <tailnet_iface>" help="Tailnet interface name to drop egress on." default="tailscale0"
#USAGE flag "--lan-iface <lan_iface>" help="LAN interface name to drop egress on (default: none; LAN CIDR covers it)."
#USAGE flag "--nodeport-range <nodeport_range>" help="Kubernetes NodePort range." default="30000-32767"
#USAGE flag "--extra-deny <extra_deny>" help="Comma-separated extra addrs/CIDRs to deny (WAN/external node IPs not in inventory)."

# gen-jobops-nft-denyset.sh
# =========================
# Emit an nftables deny-set snippet that fences the JobOps pod (chart/release
# "irl-jobops", k8s namespace "jobops", public hostname "jops.infiniteroomlabs.com")
# off the k3s host's control plane and private networks -- a HOST-LEVEL BACKSTOP
# behind the in-cluster NetworkPolicy the CNI enforces.
#
# JobOps has NO in-cluster Service: a tunnel sidecar reaches the app over
# pod-localhost:3001, so nothing legitimate needs to route through the node's
# LAN / tailnet / API surface. This snippet drops, for the pod CIDR only:
#   - every cluster node address (internal + external + Tailscale + WAN)
#   - the Kubernetes API (6443) and kubelet (10250) ports
#   - all NodePorts (30000-32767)
#   - the LAN + tailnet CIDRs and the tailnet interface
# ...while leaving normal public egress untouched (non-matching packets return
# to the calling chain and follow the existing accept path).
#
# The node/address list is GENERATED from the Ansible inventory, never hardcoded:
# it reads ansible_host (node addresses), irl_k3s_server_url (API endpoint), and
# irl_nfs_allowed_subnets[].cidr (LAN + tailnet CIDRs). WAN/external node
# addresses are NOT declared in the inventory -- supply them via --extra-deny.
#
# The emitted snippet is NOT self-applied. Wire it into
# ansible/templates/nftables.conf.j2 as a separate integration step owned by the
# serial ansible lane -- see gen-jobops-nft-denyset.README.md.
#
# Args arrive as $usage_* env vars (usage parses the #USAGE spec above).

# ---------------------------------------------------------------------------
# Resolve arguments (usage delivers them as $usage_* env vars).
# ---------------------------------------------------------------------------
pod_cidr="${usage_pod_cidr:-}"
inventory="${usage_inventory:-}"
output="${usage_output:-}"
tailnet_iface="${usage_tailnet_iface:-tailscale0}"
lan_iface="${usage_lan_iface:-}"
nodeport_range="${usage_nodeport_range:-30000-32767}"
extra_deny="${usage_extra_deny:-}"

if [[ -z "$pod_cidr" ]]; then
    echo "error: --pod-cidr is required" >&2
    exit 2
fi

# Default inventory path is relative to this script's location so the tool works
# regardless of the caller's cwd.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "$inventory" ]]; then
    inventory="${script_dir}/../ansible/inventory/hosts.ini"
fi

# Accept either a directory (assume hosts.ini inside) or a hosts file directly.
if [[ -d "$inventory" ]]; then
    inv_dir="$inventory"
    hosts_file="${inventory%/}/hosts.ini"
else
    hosts_file="$inventory"
    inv_dir="$(dirname "$inventory")"
fi

if [[ ! -f "$hosts_file" ]]; then
    echo "error: inventory hosts file not found: $hosts_file" >&2
    exit 3
fi

# ---------------------------------------------------------------------------
# Derive the deny set from the inventory.
#   Primary source : ansible-inventory --list (fully resolves group/host vars).
#   Fallback       : grep hosts.ini + yq over group_vars/**/*.yml.
# Collected into newline-delimited lists, then de-duplicated.
# ---------------------------------------------------------------------------
node_addrs=""   # ansible_host of every node (internal/tailscale primary addr)
cidrs=""        # irl_nfs_allowed_subnets cidrs (LAN + tailnet)
k3s_urls=""     # irl_k3s_server_url (API endpoint host:port)

derive_via_ansible_inventory() {
    command -v ansible-inventory >/dev/null 2>&1 || return 1
    command -v jq >/dev/null 2>&1 || return 1
    local out
    out="$(ansible-inventory -i "$hosts_file" --list 2>/dev/null)" || return 1
    [[ -n "$out" ]] || return 1

    node_addrs="$(printf '%s' "$out" | jq -r '._meta.hostvars | to_entries[] | .value.ansible_host // empty' | sort -u)"
    k3s_urls="$(printf '%s' "$out" | jq -r '._meta.hostvars | to_entries[] | .value.irl_k3s_server_url // empty' | sort -u)"
    cidrs="$(printf '%s' "$out" | jq -r '._meta.hostvars | to_entries[] | (.value.irl_nfs_allowed_subnets // [])[] | .cidr' | sort -u)"
    return 0
}

derive_via_grep_yq() {
    # Node addresses: uncommented `ansible_host=<ip>` lines in the hosts file.
    node_addrs="$(grep -hoE '^[^#]*ansible_host=[0-9.]+' "$hosts_file" \
        | sed -E 's/.*ansible_host=//' | sort -u)"

    if [[ -d "${inv_dir%/}/group_vars" ]] && command -v yq >/dev/null 2>&1; then
        local f fc fk
        while IFS= read -r f; do
            # Skip Ansible-Vault-encrypted files (e.g. group_vars/all/vault.yml) --
            # yq cannot parse them and would otherwise abort under set -e.
            if head -c 16 "$f" 2>/dev/null | grep -q '\$ANSIBLE_VAULT'; then
                continue
            fi
            fc="$(yq -r '(.irl_nfs_allowed_subnets // []) | .[].cidr' "$f" 2>/dev/null || true)"
            fk="$(yq -r '.irl_k3s_server_url // ""' "$f" 2>/dev/null || true)"
            [[ -n "$fc" ]] && cidrs+="$fc"$'\n'
            [[ -n "$fk" ]] && k3s_urls+="$fk"$'\n'
        done < <(find "${inv_dir%/}/group_vars" -type f \( -name '*.yml' -o -name '*.yaml' \))
        cidrs="$(printf '%s' "$cidrs" | sed '/^$/d' | sort -u)"
        k3s_urls="$(printf '%s' "$k3s_urls" | sed '/^$/d' | sort -u)"
    fi
}

if ! derive_via_ansible_inventory; then
    echo "note: ansible-inventory unavailable/failed; using grep+yq fallback" >&2
    derive_via_grep_yq
fi

# ---------------------------------------------------------------------------
# Split CIDRs into tailnet (100.64.0.0/10 CGNAT range) vs LAN/internal, and
# extract the API host+port from the k3s server URL(s).
# ---------------------------------------------------------------------------
tailnet_cidrs=""
lan_cidrs=""
while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    if [[ "$c" == 100.64.* || "$c" == 100.6[4-9].* || "$c" == 100.[7-9][0-9].* || "$c" == 100.1[01][0-9].* || "$c" == 100.12[0-7].* ]]; then
        tailnet_cidrs+="$c"$'\n'
    else
        lan_cidrs+="$c"$'\n'
    fi
done <<< "$cidrs"
tailnet_cidrs="$(printf '%s' "$tailnet_cidrs" | sed '/^$/d' | sort -u)"
lan_cidrs="$(printf '%s' "$lan_cidrs" | sed '/^$/d' | sort -u)"

# API server endpoints + ports. Kubelet (10250) is a well-known port; the API
# port is taken from the URL (default 6443 if unspecified).
api_hosts=""
api_ports=""
while IFS= read -r url; do
    [[ -z "$url" ]] && continue
    local_host="$(printf '%s' "$url" | sed -E 's#^[a-zA-Z]+://([^:/]+).*#\1#')"
    local_port="$(printf '%s' "$url" | sed -E 's#^[a-zA-Z]+://[^:/]+:?([0-9]*).*#\1#')"
    [[ -z "$local_port" ]] && local_port="6443"
    api_hosts+="$local_host"$'\n'
    api_ports+="$local_port"$'\n'
done <<< "$k3s_urls"
api_hosts="$(printf '%s' "$api_hosts" | sed '/^$/d' | sort -u)"
# Control-plane ports: derived API port(s) + kubelet 10250. Default 6443 if none.
cp_ports="$(printf '%s\n%s\n' "$api_ports" "10250" | sed '/^$/d' | sort -un)"
[[ -z "$(printf '%s' "$api_ports" | sed '/^$/d')" ]] && cp_ports="$(printf '6443\n10250\n' | sort -un)"

# Union of node addresses to drop as /32: ansible_host of each node + API host(s).
deny_addrs="$(printf '%s\n%s\n' "$node_addrs" "$api_hosts" | sed '/^$/d' | sort -u)"

# Extra (WAN/external) addresses supplied on the CLI -- not in the inventory.
extra_addrs=""
if [[ -n "$extra_deny" ]]; then
    extra_addrs="$(printf '%s' "$extra_deny" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d')"
fi

# ---------------------------------------------------------------------------
# Emit the nftables snippet.
# ---------------------------------------------------------------------------
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

emit() {
    cat <<EOF
# ============================================================================
# JobOps host-firewall deny-set  (GENERATED -- do not edit by hand)
# ----------------------------------------------------------------------------
# Generated : ${now}
# Generator : scripts/gen-jobops-nft-denyset.sh
# Inventory : ${hosts_file}
# Pod CIDR  : ${pod_cidr}
#
# Pinned deployment identifiers (for traceability):
#   chart/release "irl-jobops" | namespace "jobops" | ZFS "main/jobops-data"
#   hostname "jops.infiniteroomlabs.com" | app port 3001 (pod-localhost, NO Service)
#   image ghcr.io/dakheera47/job-ops @ <digest> | JOBOPS_DISABLE_ANALYTICS=true
#
# This is a HOST-LEVEL BACKSTOP for the in-cluster NetworkPolicy the CNI cannot
# fully enforce at the node boundary. Non-matching traffic RETURNS to the caller
# and follows the existing accept path, so normal public egress is intact.
#
# INTEGRATION (owned by the serial ansible lane -- see the README):
#   1. Paste the \`chain jobops_backstop { ... }\` block below INSIDE
#      \`table inet filter { ... }\` in ansible/templates/nftables.conf.j2.
#   2. Add the jump line to BOTH the \`input\` and \`forward\` chains, placed
#      ABOVE the trusted-interface accepts (\`iifname "cni0" accept\` etc.) --
#      otherwise cni0/flannel accepts short-circuit the drop.
#      Place it right after \`ct state established,related accept\`:
#
#          ip saddr ${pod_cidr} jump jobops_backstop
#
# ============================================================================

    chain jobops_backstop {
        # Reached only for packets whose source is the JobOps pod CIDR
        # (${pod_cidr}); the jump in input/forward already matches ip saddr.

        # -- Kubernetes control-plane ports (API server + kubelet) --
EOF
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        printf '        tcp dport %s log prefix "nft-jobops-drop-cp: " drop\n' "$p"
    done <<< "$cp_ports"

    cat <<EOF

        # -- All NodePorts --
        tcp dport ${nodeport_range} log prefix "nft-jobops-drop-nodeport: " drop
        udp dport ${nodeport_range} drop

        # -- Cluster node addresses (internal + Tailscale + API endpoint) --
EOF
    if [[ -n "$deny_addrs" ]]; then
        while IFS= read -r a; do
            [[ -z "$a" ]] && continue
            printf '        ip daddr %-18s log prefix "nft-jobops-drop-node: " drop\n' "$a"
        done <<< "$deny_addrs"
    else
        echo '        # (no ansible_host / API addresses derived from inventory)'
    fi

    cat <<EOF

        # -- LAN / internal CIDR(s) (covers node internal addr + LAN interface) --
EOF
    if [[ -n "$lan_cidrs" ]]; then
        while IFS= read -r c; do
            [[ -z "$c" ]] && continue
            printf '        ip daddr %-18s log prefix "nft-jobops-drop-lan: " drop\n' "$c"
        done <<< "$lan_cidrs"
    else
        echo '        # (no LAN CIDR derived from inventory)'
    fi

    cat <<EOF

        # -- Tailnet CIDR (all nodes' Tailscale addrs) + tailnet interface --
EOF
    if [[ -n "$tailnet_cidrs" ]]; then
        while IFS= read -r c; do
            [[ -z "$c" ]] && continue
            printf '        ip daddr %-18s log prefix "nft-jobops-drop-tailnet: " drop\n' "$c"
        done <<< "$tailnet_cidrs"
    else
        echo '        # (no tailnet CIDR derived from inventory)'
    fi
    printf '        oifname %-18s log prefix "nft-jobops-drop-tailnet: " drop\n' "\"$tailnet_iface\""
    if [[ -n "$lan_iface" ]]; then
        printf '        oifname %-18s log prefix "nft-jobops-drop-lan: " drop\n' "\"$lan_iface\""
    fi

    cat <<EOF

        # -- WAN / external node addresses (NOT declared in the inventory) --
EOF
    if [[ -n "$extra_addrs" ]]; then
        while IFS= read -r a; do
            [[ -z "$a" ]] && continue
            printf '        ip daddr %-18s log prefix "nft-jobops-drop-wan: " drop\n' "$a"
        done <<< "$extra_addrs"
    else
        cat <<'EOF'
        # TODO: supply the homelab WAN IP + DO droplet public IP via --extra-deny;
        #       these are not present in ansible/inventory/. Example:
        # ip daddr <homelab-wan-ip> log prefix "nft-jobops-drop-wan: " drop
        # ip daddr <do-droplet-public-ip> log prefix "nft-jobops-drop-wan: " drop
EOF
    fi

    cat <<'EOF'

        # Anything else returns to the calling chain -> normal egress unaffected.
    }
EOF
}

if [[ -n "$output" ]]; then
    emit > "$output"
    echo "wrote JobOps nft deny-set snippet -> $output" >&2
else
    emit
fi
