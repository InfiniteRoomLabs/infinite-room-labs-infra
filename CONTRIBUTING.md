# Contributing to IRL Infrastructure

This document covers everything you need to know to work on the Infinite Room Labs infrastructure repo.

## Architecture Overview

2-node k3s cluster connected over Tailscale:

| Node | Location | Role | Spec |
|------|----------|------|------|
| `home` | On-prem (HP Z600) | k3s server, stateful workloads | Dual Xeon, 40GB RAM, ZFS RAIDZ1 |
| `do-k3s-agent-01` | DigitalOcean NYC3 | k3s agent | 4 vCPU, 8GB RAM, $48/mo |

All services live in the `irl` namespace. Flannel VXLAN over Tailscale for cross-node networking.

## Repo Structure

```
terraform/           Terraform + Terragrunt (cloud resources, DNS, Split DNS)
ansible/             Ansible playbooks (server config, k8s deployments)
tests/               Acceptance tests (pytest + Goss + Task orchestrator)
docs/                Plans, runbooks, SOPs, access guides
scripts/             bw-sync.sh, bootstrap scripts
```

## Adding a New Service

This is the most common operation. Follow this checklist exactly:

### 1. Add to `irl_services` dict

`ansible/inventory/group_vars/all/main.yml` -- add an entry:

```yaml
myservice:
  subdomain: "myservice"        # becomes myservice.lab.infiniteroomlabs.cloud
  port: 30XXX                   # NodePort number (pick an unused one)
  internal: false               # true = *.internal.lab domain + Caddy internal TLS
  health_path: "/health"        # optional, used by docs
  caddy_proxy: true             # set false for ClusterIP-only services
```

This is the **single source of truth**. It drives:
- Caddy reverse proxy (Caddyfile.j2 template)
- CoreDNS zone file (coredns-internal-zone.db.j2 template)
- Documentation

### 2. Create Helm values file

`ansible/helm/{service}/values.yaml` -- chart-specific config:
- Set `nodeSelector: { irl.dev/tier: data }` for homelab
- Use `existingSecret` pattern for credentials (never plaintext)
- Set resource limits appropriate for homelab

### 3. Add deployment tasks to `helm-deploy.yml`

`ansible/playbooks/helm-deploy.yml` -- add tasks in the right phase:
- Phase 2: Core infrastructure (databases, storage, DNS)
- Phase 3: Dev platform + monitoring (apps, dashboards)
- Phase 5: Agent integration (AI/ML services)

Each service needs:
- Helm repo addition (if upstream chart)
- Values file upload
- Secret creation (if needed, with `no_log: true`)
- `kubernetes.core.helm` deploy task with proper tags

### 4. Add secrets (if needed)

1. Generate secret values
2. Store in Bitwarden under `IRL/Services/{ServiceName}/`
3. Add to `scripts/bw-sync-config.yaml`
4. Add to `ansible/inventory/group_vars/all/vault.yml` (via `bw-sync.sh --target ansible`)
5. Create K8s Secret in helm-deploy.yml task

### 5. Redeploy Caddy

Run `./ansible/run-ansible.sh playbook playbooks/caddy.yml` -- the Caddyfile template auto-generates from `irl_services`.

### 6. Update tests

- `tests/conftest.py` -- add to SERVICES dict
- `tests/test_dns.py` -- add domain to EXPECTED_RECORDS
- Caddy tests pick it up automatically via parametrization

### 7. Update docs

- `~/.claude/CLAUDE.md` -- service table
- `docs/homelab-access-guide.md` -- access info
- `CHANGELOG.md` -- what changed

## Running Ansible

All Ansible runs through a Docker container. Never install Ansible locally.

```bash
# Run a playbook
ANSIBLE_VAULT_PASSWORD_FILE=~/.secrets/ansible-vault-password \
  bash ansible/run-ansible.sh playbook playbooks/helm-deploy.yml --tags myservice

# Run a specific phase
ANSIBLE_VAULT_PASSWORD_FILE=~/.secrets/ansible-vault-password \
  bash ansible/run-ansible.sh playbook playbooks/helm-deploy.yml --tags phase3

# Full site deploy
ANSIBLE_VAULT_PASSWORD_FILE=~/.secrets/ansible-vault-password \
  bash ansible/run-ansible.sh playbook site.yml
```

The runner needs:
- `~/.ssh/id_ed25519` (SSH key for server access; also the fnox age identity)
- `~/.kube/homelab.yaml` (kubeconfig)
- fnox able to resolve `ANSIBLE_VAULT_PASSWORD` (vault decryption) -- the Docker
  runner resolves it on the host and mounts it.

## Running Terraform

Secrets are injected by fnox per-command (no `.envrc`). Wrap terragrunt with
`scripts/with-secrets.sh`:

```bash
cd terraform/environments/homelab/digitalocean/k3s-agent
../../../../../scripts/with-secrets.sh terragrunt init
../../../../../scripts/with-secrets.sh terragrunt plan
../../../../../scripts/with-secrets.sh terragrunt apply
```

The secrets terragrunt consumes are declared in `fnox.toml`; non-secret
identifiers are in `mise.toml [env]`. Verify resolution with `fnox check`.

## Secrets Management

**Source of truth**: Bitwarden vault, `IRL/` folder tree.

**Never**:
- Hardcode secrets in Terraform, Ansible, or Helm values
- Commit secrets to git (vault.yml is encrypted, everything else is clean)
- Echo/log secret values

**Always**:
- Store in Bitwarden first
- For cluster secrets: add to `bw-sync-config.yaml` for the sync pipeline
- For env-var secrets (Terraform/CLI tokens): declare in `fnox.toml`
- Use `existingSecret` pattern in Helm charts
- Use `no_log: true` on Ansible tasks that handle secrets

### Secret flow

Two consumers, one source of truth (Bitwarden):

```
                         +-> bw-sync.sh -> vault.yml (encrypted) -> Ansible -> K8s Secrets
Bitwarden (IRL/ tree) ---+
                         +-> fnox (fnox.toml) -> fnox exec -> env vars -> Terraform / CLIs
```

- **Cluster service secrets** (DB passwords, service tokens) flow through
  `bw-sync.sh` into `vault.yml` and K8s Secrets, as before.
- **Env-var secrets** (provider/API tokens) are declared in `fnox.toml` and
  injected per-command via `fnox exec` (`scripts/with-secrets.sh`). No `.env`,
  no `.envrc`, no ambient loading. `BW_SESSION` comes from the single cache
  `~/.bw_session` (fish `bw-unlock`), validated by `scripts/includes/bw-session.sh`.
- See the `manage-secrets` skill for the full add/rotate/delete procedures.

## Node Labels

All nodes use the `irl.dev/*` label taxonomy:

| Label | Purpose | Values |
|-------|---------|--------|
| `irl.dev/provider` | Who runs the infra | homelab, digitalocean |
| `irl.dev/tier` | Architecture role | data, compute |
| `irl.dev/storage` | Backing storage | zfs, nvme |
| `irl.dev/network` | Cluster connectivity | lan, tailscale |
| `irl.dev/cost` | Billing model | owned, paid |
| `irl.dev/persistence` | How permanent | permanent, ephemeral |
| `irl.dev/gpu` | GPU availability | none |
| `irl.dev/memory-class` | Memory tier | high (24G+), standard (8-24G) |

Use `nodeSelector` in Helm values to target the right node. Cloud nodes have a `irl.dev/cloud=<provider>:NoSchedule` taint -- workloads must explicitly tolerate it.

## Networking

- **Flannel VXLAN** over Tailscale (`flannel-iface: tailscale0` on both nodes)
- **MTU**: 1230 (VXLAN 50 bytes + WireGuard 60 bytes overhead)
- **Split DNS**: CoreDNS on homelab (hostNetwork port 53), Tailscale routes `*.lab.infiniteroomlabs.cloud` to it
- **Caddy**: Bare-metal reverse proxy, internal TLS (Caddy CA), proxies NodePorts
- **NetworkPolicies**: default-deny-all + allow-intra-namespace + allow-dns-egress

## Testing

See [TESTING.md](TESTING.md) for full details.

```bash
cd tests/
task smoke      # Quick: 17 smoke tests
task validate   # Full: Goss + pytest + report
```

## Git Conventions

- Imperative mood commit messages
- CHANGELOG.md must be updated with every commit to master (enforced by hook)
- Feature branches: `feat/{description}`
- PRs for non-trivial changes
- Never rewrite shared branch history
- Never commit `.claude/`, `.codex/`, `fnox.local.toml`, or secrets files. (`fnox.toml` IS committed -- it holds only Bitwarden references, no values.)

## Common Gotchas

- **Vault re-seals on k3s restart**: Need 3 of 5 unseal keys from BW `IRL/Services/Vault`
- **Ansible runner TTY**: `run-ansible.sh` auto-detects TTY. Non-interactive contexts (CI, agents) work fine.
- **CoreDNS needs hostNetwork**: Tailscale Split DNS only works on port 53. Apply `hostNetwork: true` patch after Helm deploy.
- **CHANGELOG guard**: Every commit to master must include a CHANGELOG.md change. Stage it before committing.
- **bw-sync.sh slow**: Iterates all BW folders. For quick vault updates, decrypt/edit/re-encrypt directly.
