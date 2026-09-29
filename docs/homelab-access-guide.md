# Homelab Service Access Guide

Last updated: 2026-09-25

## Prerequisites

- **Tailscale** installed and connected to the IRL tailnet
- Homelab server (HP Z600) reachable at `100.86.213.22` (Tailscale IP)
- **kubectl** installed (`/usr/local/bin/kubectl`)
- **KUBECONFIG** set to `~/.kube/homelab.yaml` (done automatically in fish + bashrc)

DNS resolution is handled automatically via Tailscale Split DNS. CoreDNS runs on the homelab node (hostNetwork, port 53) and resolves `*.lab.infiniteroomlabs.cloud` and `*.internal.lab.infiniteroomlabs.cloud`. No `/etc/hosts` changes needed.

## Cluster Nodes

| Node | Location | Tailscale IP | Spec | Role |
|------|----------|--------------|------|------|
| HP Z600 (homelab) | On-prem | 100.86.213.22 | Dual Xeon, 48GB RAM, ZFS | k3s server, all workloads |

The cluster is single-node. The cloud agent node was retired; KVM/libvirt VMs
on the same host are the next nodes to join.

## Service Access Table

All services are routed by in-cluster Traefik (hostNetwork, Let's Encrypt wildcard via DNS-01) and reachable on the tailnet only -- the names resolve solely through the internal CoreDNS zone. Public-facing services use `*.lab.infiniteroomlabs.cloud`, internal services use `*.internal.lab.infiniteroomlabs.cloud`. (Caddy was the bare-metal predecessor and is gone.)

| Service | URL | Node | Credentials |
|---------|-----|------|-------------|
| **Gitea** (git server) | https://git.lab.infiniteroomlabs.cloud | Homelab | Admin: `gitea_admin` / password in BW `gitea-admin` (synced to k8s Secret `gitea-admin` by `bw-sync.sh`) |
| **Grafana** (dashboards) | https://grafana.lab.infiniteroomlabs.cloud | Homelab | Admin: `admin` / password in BW `IRL/Services/Grafana` |
| **Vault** (secrets mgmt) | https://vault.lab.infiniteroomlabs.cloud | Homelab | Root token in BW `IRL/Services/Vault` |
| **Authentik** (SSO) | https://auth.lab.infiniteroomlabs.cloud | Homelab | Bootstrap password in BW `IRL/Services/Authentik` |
| **Garage** (S3 storage) | https://garage.internal.lab.infiniteroomlabs.cloud | Homelab | Admin token in BW `IRL/Services/Garage` |
| **OpenViking** (agent memory/RAG) | https://openviking.internal.lab.infiniteroomlabs.cloud | Homelab | No auth (internal) |
| **Prometheus** (metrics) | https://metrics.internal.lab.infiniteroomlabs.cloud | Homelab | No auth (internal) |
| **Alertmanager** (alerts) | https://alerts.internal.lab.infiniteroomlabs.cloud | Homelab | No auth (internal) |
| **Karakeep** (bookmarks) | https://bookmarks.lab.infiniteroomlabs.cloud | Homelab | Single admin `wes@infiniteroomlabs.com`, password in BW `IRL/Services/Karakeep` (signups disabled) |
| **WordPress** (journal) | https://journal.lab.infiniteroomlabs.cloud | Homelab | Admin account created at `/wp-admin/install.php` on first visit; store it in BW `IRL/Services/WordPress` |
| **OpenMessage** (SMS/RCS MCP server) | https://openmessage.lab.infiniteroomlabs.cloud/mcp | Homelab | `Authorization: Bearer <token>`, token in BW `IRL/Services/OpenMessage` (item `openmessage-control-token`). No web UI -- see below |
| **CoreDNS** (Split DNS) | N/A (hostNetwork port 53) | Homelab | No UI -- DNS resolver only |
| **Ollama** (LLM inference) | ClusterIP only | Homelab | See kubectl access below |
| **Satisfactory** (game server) | Game client only -- see below | Homelab | Admin password set in-game at claim time |
| **Palworld** (game server) | Game client only -- see below | Homelab | RCON admin password in BW `IRL/Services/Palworld` |

## Connecting to the Satisfactory Server

No HTTP UI and no Traefik route -- game traffic goes straight to NodePorts,
which are deliberately open on the LAN so devices without Tailscale (the
Steam Deck) can play:

- **From the LAN**: Server Manager -> Add Server -> `192.168.2.2:30777`
- **From the tailnet**: `100.86.213.22:30777`

Ports: 30777 tcp+udp (game + HTTPS API), 30888 tcp (reliable messaging,
advertised to clients automatically). The server was claimed once in-game;
the admin password lives on the server's PVC, not in Bitwarden. Saves are
snapshotted hourly (sanoid) -- recovery procedures in
`ansible/docs/sops/backup-and-restore.md` and
`ansible/docs/runbooks/satisfactory-down.md`.

## Connecting to the Palworld Server

Same LAN-open NodePort pattern as Satisfactory, but the game protocol is
UDP-only on a single port:

- **From the LAN**: Join Multiplayer Game -> direct connect -> `192.168.2.2:30211`
- **From the tailnet**: `100.86.213.22:30211`

Port: 30211/udp only. RCON (25575) and the REST API (8212) stay pod-internal;
the RCON admin password is env-injected from Secret `palworld-secrets`
(BW item `palworld-admin-password`). No join password -- reachability is
LAN + tailnet only and the server never appears in the community browser.
Saves are snapshotted hourly (sanoid) plus the image's own daily tar backups --
recovery procedures in `ansible/docs/sops/backup-and-restore.md` and
`ansible/docs/runbooks/palworld-down.md`.

## Connecting to OpenMessage (MCP)

One daemon for every machine: the Google Messages pairing is a single logical
device, so Claude Code and Claude Desktop on both the laptop and the desktop
point at this one endpoint. **Never run a second OpenMessage against the same
pairing** -- the two fight over the session and Google can revoke it.

- Endpoint: `https://openmessage.lab.infiniteroomlabs.cloud/mcp`
  (legacy SSE clients: `/mcp/sse`)
- Auth: `Authorization: Bearer <token>` on every request, from BW
  `IRL/Services/OpenMessage`
- Reachable from the tailnet and the home LAN only: no public DNS record, no
  tunnel, and a Traefik IP allowlist for `192.168.2.0/24` + `100.64.0.0/10`

### Client setup is IaC -- do not configure this by hand

Clients do not talk to the endpoint directly. They run a local stdio bridge
that reads the bearer token from a mode-0600 file and adds the header itself:

```
openmessage mcp-bridge --url https://openmessage.lab.infiniteroomlabs.cloud/mcp --token-file <path>
```

Two reasons it is done this way. The token stays out of every Claude config,
so rotation is one file rewrite per machine rather than an edit of four JSON
blobs. And Claude Desktop cannot reach this service any other way: its remote
connectors run from Anthropic's cloud, which has no route to a tailnet-only
host.

| Machine | Converge |
|---|---|
| Laptop | `cd ansible/ && ../scripts/with-secrets.sh uv run ansible-playbook playbooks/laptop.yml --tags openmessage_client` |
| Desktop | `cd <repo>\desktop && fnox exec -- pwsh -File .\Invoke-DesktopConverge.ps1` |

Both take a dry run (`--check` / `-WhatIf`) and both install the pinned
`openmessage` release, write the token file and register the MCP server in
Claude Code and Claude Desktop. See `desktop/README.md` and
`ansible/playbooks/tasks/openmessage_client.yml`.

Quick check (no token needed for the health path):

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://openmessage.lab.infiniteroomlabs.cloud/healthz   # 200
curl -sS -o /dev/null -w '%{http_code}\n' https://openmessage.lab.infiniteroomlabs.cloud/mcp       # 401
```

403 means the IP allowlist or the daemon's Host check rejected you; 401 means
the token is missing or wrong. Full triage:
`ansible/docs/runbooks/openmessage-down.md`.

## Accessing Ollama (ClusterIP-only)

Ollama is intentionally not exposed via NodePort. Access it via port-forward:

```bash
# Forward local port 11434 to Ollama
kubectl port-forward -n irl svc/ollama 11434:11434

# In another terminal, test it
curl http://localhost:11434/api/tags   # List available models
curl -X POST http://localhost:11434/api/generate -d '{"model":"llama3.2","prompt":"Hello"}'
```

Models available: `llama3.2`, `codellama`, `nomic-embed-text`

## Gitea SSH Access

Gitea SSH is exposed on NodePort 30022:

```bash
# Add to ~/.ssh/config for convenient git operations:
Host gitea
    HostName 100.86.213.22
    Port 30022
    User git
```

Then clone repos with: `git clone gitea:org/repo.git`

## Vault CLI Access

```bash
export VAULT_ADDR='https://vault.lab.infiniteroomlabs.cloud'
export VAULT_TOKEN='<root-token-from-bitwarden>'
vault status
vault secrets list
```

## Garage S3 Access

Garage provides S3-compatible object storage. Data is ZFS-backed on the homelab node.

```bash
# Configure AWS CLI or s3cmd with Garage credentials from Bitwarden
aws configure --profile garage
# Endpoint: https://garage.internal.lab.infiniteroomlabs.cloud
# Access Key / Secret Key: from BW IRL/Services/Garage
```

## Troubleshooting

```bash
# Check all pods
kubectl get pods -n irl

# Check a specific service's logs
kubectl logs -n irl -l app.kubernetes.io/name=gitea --tail=50

# Check node resources
kubectl top nodes
kubectl top pods -n irl

# Check cross-node networking (flannel over Tailscale)
kubectl get nodes -o wide   # Verify both nodes are Ready
kubectl exec -n irl <pod-on-homelab> -- ping <pod-ip-on-do>

# Vault re-seal after restart (need 3 of 5 unseal keys from BW)
kubectl exec -n irl vault-0 -- vault operator unseal <key>

# Check Split DNS resolution
dig @100.86.213.22 git.lab.infiniteroomlabs.cloud
```
