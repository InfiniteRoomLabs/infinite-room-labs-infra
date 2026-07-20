# gen-jobops-nft-denyset.sh

Generates an nftables deny-set snippet that fences the **JobOps** pod off the k3s host's control plane and private networks. This is a **host-level backstop** behind the in-cluster NetworkPolicy: the CNI (Flannel + kube-router) enforces pod egress at the Kubernetes layer, but it cannot police traffic once it reaches the node's own `input`/`forward` chains. This snippet closes that gap.

## Why JobOps needs it

JobOps (chart/release `irl-jobops`, namespace `jobops`, ZFS dataset `main/jobops-data`, public hostname `jops.infiniteroomlabs.com`) runs a forked `ghcr.io/dakheera47/job-ops` image pinned by digest, with analytics disabled (`JOBOPS_DISABLE_ANALYTICS=true`). It scrapes 10+ external job boards, so it makes a lot of outbound requests to arbitrary public hosts. That is fine and intended.

What is **not** fine is the pod reaching *inward*: the Kubernetes API, the kubelet, NodePorts, other cluster nodes, or the home LAN / tailnet. This deployment has **no in-cluster Service** at all -- a tunnel sidecar reaches the app over `pod-localhost:3001` -- so nothing legitimate needs the node's LAN, tailnet, or API surface. The deny set drops exactly that traffic and leaves normal public egress untouched.

## What it blocks (for the pod CIDR only)

- Every cluster node address: internal + Tailscale + (via `--extra-deny`) external/WAN
- Kubernetes API (`6443`) and kubelet (`10250`) ports
- All NodePorts (`30000-32767`, TCP + UDP)
- The LAN CIDR and the Tailscale CGNAT CIDR (`100.64.0.0/10`)
- The tailnet interface (`tailscale0`), and optionally a named LAN interface

Non-matching packets `return` to the calling chain and follow the existing accept path, so ordinary public egress is preserved.

## Address list is generated, never hardcoded

The node/address list is derived from `ansible/inventory/`:

| Deny-set member        | Inventory source                                        |
|------------------------|---------------------------------------------------------|
| Node addresses (/32)   | each host's `ansible_host` (`hosts.ini`)                |
| Kubernetes API endpoint| `irl_k3s_server_url` (host + port)                      |
| LAN CIDR               | `irl_nfs_allowed_subnets[].cidr` (RFC1918 entry)        |
| Tailnet CIDR           | `irl_nfs_allowed_subnets[].cidr` (`100.64.0.0/10` entry)|
| Control-plane ports    | `6443` from the API URL + kubelet `10250`               |

Primary source is `ansible-inventory --list` (fully resolves group/host vars); if that is unavailable or fails (e.g. no vault password to decrypt `group_vars/all/vault.yml`), it falls back to `grep` over `hosts.ini` + `yq` over `group_vars/**/*.yml`, skipping Ansible-Vault-encrypted files.

**WAN / external node addresses are not declared in the inventory.** The homelab's public IP and the DigitalOcean droplet's public IP live in Terraform / cloud state, not Ansible. Supply them via `--extra-deny` (comma-separated). When omitted, the snippet emits a clearly-marked `TODO` block instead.

## Usage

```bash
# Minimal (default inventory = ../ansible/inventory/hosts.ini):
./gen-jobops-nft-denyset.sh --pod-cidr 10.42.7.0/24

# Full: pin the pod CIDR, add WAN IPs, name the LAN interface, write to a file:
./gen-jobops-nft-denyset.sh \
  --pod-cidr 10.42.7.0/24 \
  --inventory ../ansible/inventory \
  --extra-deny "<homelab-wan-ip>,<do-droplet-public-ip>" \
  --lan-iface enp3s0 \
  --output /tmp/jobops-backstop.nft
```

Flags (`usage` spec; run `--help` for the full list):

| Flag                | Default                          | Purpose |
|---------------------|----------------------------------|---------|
| `--pod-cidr`        | (required)                       | JobOps pod CIDR to fence |
| `--inventory`       | `../ansible/inventory/hosts.ini` | Inventory dir or hosts file |
| `--output`          | stdout                           | Write snippet to this file |
| `--tailnet-iface`   | `tailscale0`                     | Tailnet interface to drop egress on |
| `--lan-iface`       | (none)                           | LAN interface to drop egress on |
| `--nodeport-range`  | `30000-32767`                    | Kubernetes NodePort range |
| `--extra-deny`      | (none)                           | Extra addrs/CIDRs (WAN/external) not in inventory |

The script's `pod-cidr`, `--pod-cidr`, and other args follow the machine `usage`-spec convention (`#!/usr/bin/env -S usage bash` + `#USAGE` header comments; args arrive as `$usage_*` env vars).

## Integration (separate step -- NOT done by this script)

**This generator does not edit any firewall config.** Its output is a raw nftables snippet to be wired into `ansible/templates/nftables.conf.j2` **as a separate integration step owned by the serial ansible lane.** Do not hand-edit `nftables.conf.j2` from this generator's context -- it is a shared file, and concurrent edits collide with the serial lane.

To integrate, the ansible-lane owner:

1. Pastes the generated `chain jobops_backstop { ... }` block **inside** `table inet filter { ... }`.
2. Adds the jump rule to **both** the `input` and `forward` chains, placed **above** the trusted-interface accepts (`iifname "cni0" accept`, `iifname "flannel.1" accept`) -- otherwise those accepts short-circuit the drop. Put it right after `ct state established,related accept`:

   ```
   ip saddr <pod-cidr> jump jobops_backstop
   ```

   Both chains are required: pod -> local node (API/kubelet/NodePort) hits `input`; pod -> other node / LAN / tailnet hits `forward`.
3. Parameterizes the pasted values against inventory vars if desired (the generated output is concrete addresses for review; the lane may template them back onto `irl_*` vars for drift control).

The emitted ruleset has been validated with `nft -c -f` (check mode) for syntax.
