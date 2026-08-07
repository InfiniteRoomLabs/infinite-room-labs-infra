# 0005. LAN-reachable game servers via symmetric NodePorts + nftables + NetworkPolicy

Date: 2026-08-01 (Satisfactory, commits b212753 + 9566917; pattern reused for Palworld 2026-08-06, commit 5ab51c9)

## Status

Accepted

## Context

Dedicated game servers (Satisfactory via `wolveix/satisfactory-server`, later Palworld via `thijsvanloef/palworld-server-docker`) run as single Deployments in the `irl` namespace on the homelab k3s node. Unlike every other service in the stack, the primary client is a Steam Deck with no Tailscale: it must connect over the raw LAN at `192.168.2.2:<port>`. Game traffic is not HTTP, so the existing Traefik ingress path does not apply; these are the first services exposed to the LAN rather than tailnet-only.

Three existing layers each block LAN game traffic by default:

1. The node firewall is a default-drop nftables allowlist for LAN traffic (`irl_firewall_allowed_tcp_ports` / `_udp_ports` in `ansible/inventory/group_vars/homelab/main.yml`); only `tailscale0` is accepted unconditionally.
2. The `irl` namespace is default-deny plus `allow-ingress-tailscale` (kube-router enforced NetworkPolicy).
3. Kubernetes NodePorts are restricted to the 30000-32767 range, while games default to vanity ports (Satisfactory 7777-style, Palworld 8211).

Two game-protocol constraints shape the design (documented in the chart values headers, `helm-charts/charts/irl-satisfactory/values.yaml` and `irl-palworld/values.yaml`):

- Satisfactory 1.1+ advertises its reliable-messaging port to clients during the game-port handshake, so the port the container listens on MUST equal the port the client reaches externally -- no NAT-style port translation anywhere in the path.
- Both server images make their listen ports configurable (`SERVERGAMEPORT`/`SERVERMESSAGINGPORT` for Satisfactory; `PORT`, valid 1024-65535, for Palworld), which makes port symmetry achievable without patching images.

A late-breaking discovery (commit 9566917, same day as the initial Satisfactory deploy): NodePort traffic reaches kube-router's filter hooks with its ORIGINAL LAN source IP, because masquerade happens later in POSTROUTING. So LAN clients matched no NetworkPolicy allow rule and got "connection refused" while tailnet clients (covered by `allow-ingress-tailscale`) and node-local tests worked. The nftables allowlist alone is not sufficient.

## Decision

LAN-reachable game servers follow one pattern with three mandatory layers, all symmetric on the same port number:

1. **Symmetric NodePorts.** The container listens directly on the NodePort number (Satisfactory: game 30777, messaging 30888; Palworld: game 30211). Chart values pin `env.gamePort == service.game.port == service.game.nodePort`. A single NodePort Service carries all game ports; where a game uses TCP+UDP on one port (Satisfactory 30777), the Service declares two entries with the same `nodePort` -- Kubernetes allows duplicate nodePorts across protocols (`irl-satisfactory/templates/service.yaml`).
2. **nftables allowlist entries** for each game port/protocol in `irl_firewall_allowed_tcp_ports` / `_udp_ports`, applied by the security playbook. Only ports the game protocol actually needs are opened (Palworld query/RCON/REST are deliberately NOT exposed).
3. **Per-game NetworkPolicy** in `ansible/playbooks/k3s.yml` (`allow-satisfactory-game-lan`, `allow-palworld-game-lan`) admitting `192.168.2.0/24` to the game pod on exactly the game ports, tagged per service. Tailnet clients continue to ride the existing `allow-ingress-tailscale` policy.

Supporting conventions: registry entries are `cluster_only` (no Traefik route, no homepage tile); server images are version-pinned; each game gets a `<svc>-down.md` runbook whose "reachable on tailnet but not from LAN" section documents the two-layer check. Because a UDP game port cannot be probed, health probes target a TCP side channel instead (Satisfactory messaging 30888; Palworld's pod-internal REST API on TCP 8212).

## Consequences

Positive:

- The Tailscale-less Steam Deck connects at `192.168.2.2:30777` / `:30211`; tailnet clients at `100.86.213.22` work with zero extra rules. Verified end-to-end from a LAN client (9566917).
- No LoadBalancer (this k3s has no LB provider -- chart-default LoadBalancer Services were the root cause of the historical `helm --wait` timeouts, per CHANGELOG) and no `hostNetwork` escape hatch.
- Port symmetry removes an entire failure class: any port the server advertises in-protocol is reachable at that same number, so no game-specific NAT translation bugs.
- The pattern is proven reusable: Palworld adopted it wholesale five days later with only game-specific deltas (UDP-only, RCON/backup extras).

Negative / accepted costs:

- Vanity default ports are impossible; players must type NodePort-range numbers (30777, 30211) into their clients.
- Adding a game touches three places (chart values, nftables group_vars + security playbook run, NetworkPolicy in k3s.yml). The runbooks and the k3s.yml comment carry the rationale, but nothing enforces the three-way port agreement mechanically.
- Deliberate LAN exposure widens the attack surface to `192.168.2.0/24`. Mitigations are game-level: Satisfactory is claimed and password-protected in-game (no k8s secret; the claim lives on the PVC), Palworld sets `community: false` and exposes only the game UDP port.
- Re-applying nftables flushes libvirt NAT rules (known interaction, documented in `satisfactory-down.md`): restart libvirt networks if VMs lose connectivity after a firewall run.
- The two-layer LAN path has a distinctive partial-failure signature (tailnet works, LAN "connection refused" = missing NetworkPolicy) that operators must learn; both runbooks document it.

## References

- `ansible/docs/runbooks/satisfactory-down.md`, `ansible/docs/runbooks/palworld-down.md`
- `helm-charts/charts/irl-satisfactory/`, `helm-charts/charts/irl-palworld/`
- `ansible/playbooks/k3s.yml` (NetworkPolicies), `ansible/inventory/group_vars/homelab/main.yml` (allowlist)
- CHANGELOG.md entries for Satisfactory (2026-08-01) and Palworld (2026-08-06)
