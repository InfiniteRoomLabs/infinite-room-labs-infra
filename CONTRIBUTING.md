# Contributing to IRL Infrastructure

This document covers everything you need to know to work on the Infinite Room Labs infrastructure repo.

## Architecture Overview

Single-node k3s cluster:

| Node | Location | Role | Spec |
|------|----------|------|------|
| `home` | On-prem (HP Z600) | k3s server, all workloads | Dual Xeon, 40GB RAM, ZFS RAIDZ1 |

All services live in the `irl` namespace. The cloud agent node was retired; the
next nodes to join are KVM/libvirt VMs on the same host -- see
`docs/plans/2026-08-27-k3s-to-vms-migration-design.md`. Flannel VXLAN is bound
to the tailnet so cross-node traffic rides Tailscale when a second node exists.

## Repo Structure

```
terraform/           Terraform + Terragrunt (cloud resources, DNS, Split DNS)
ansible/             Ansible playbooks (server config, k8s deployments)
tests/               Acceptance tests (pytest + Goss + Task orchestrator)
docs/                Plans, runbooks, SOPs, access guides
scripts/             bw-sync.sh, bootstrap scripts
```

## Adding a New Service

This is the most common operation. `pytest -m hygiene` in `tests/` encodes most
of this checklist -- run it before you push and it will tell you what you
forgot.

### 1. Add to the `irl_services` registry

`ansible/inventory/group_vars/all/main.yml`:

```yaml
myservice:
  subdomain: "myservice"        # becomes myservice.lab.infiniteroomlabs.cloud
  internal: false               # true = *.internal.lab.infiniteroomlabs.cloud
  cluster_svc: "myservice"      # k8s Service name Traefik routes to
  cluster_port: 8080
  health_path: "/health"        # optional, defaults to "/" in the tests
  # cluster_only: true          # no HTTP route at all (game servers, S3 API)
  # deploy_tag: "monitoring"    # if a different play/tag deploys it
```

This is the **single source of truth**. It drives the CoreDNS zone file
(`coredns-internal-zone.db.j2`), the derived service list in `tests/conftest.py`
and the hygiene contracts (homepage tile, runbook, DNS record).

There are no NodePorts and no Caddy any more: routing is Traefik IngressRoute
CRDs, and reachability is "the name only resolves on the tailnet".

### 2. Pick or write the chart

Prefer an upstream chart plus a values file. Check that its images are actually
maintained -- Bitnami's community images moved to `bitnamilegacy` in Aug 2025
and are frozen, so a Bitnami chart means pinning stale images.

If no upstream chart fits, write one in the `helm-charts/` submodule
(`charts/irl-{name}/`, see `irl-wordpress` for the shape: app + optional
app-owned database + chart-owned IngressRoute + `existingClaim`/`existingSecret`
everywhere). **Commit and push the submodule first**: ansible installs from the
published IRL Helm repo (`chart_ref: irl/irl-{name}`), not from the local path,
so the chart must exist at `https://infiniteroomlabs.github.io/helm-charts/`
before the deploy task can work. Then update the submodule pointer here.

Keep operator-specific values (hostnames, claim names, secret names) out of
chart defaults -- `helm-charts` is public.

Routing: if the chart owns its IngressRoute, do NOT also add the service to
`irl_traefik_standalone_services`; that list is only for services deployed from
a chart that has no route of its own.

### 3. Storage (if it needs persistence)

Four places, in this order:

1. `irl_zfs_datasets` in `group_vars/all/main.yml` -- dataset + quota (+
   `recordsize: "16K"` for a database).
2. `ansible/playbooks/zfs.yml` -- a chown task tagged with the service name.
   hostPath PVs ignore `fsGroup`, so this is what actually makes the volume
   writable by the container's uid.
3. `ansible/playbooks/k3s.yml` -- a `pv-{service}-{purpose}` entry in the
   ZFS-backed PersistentVolumes loop.
4. `ansible/files/sanoid/sanoid.conf` -- a retention policy. Sanoid is
   per-dataset opt-in (`recursive = no` on the pool); a dataset that is not
   listed is never snapshotted.

The PVC itself is created in `helm-deploy.yml` with an explicit `volumeName`
(a selector alone can bind the wrong PV when a service has two).

### 4. Secrets

Bitwarden is the source of truth and `bw-sync.sh` is the only writer:

1. Create the item in Bitwarden under `IRL/Services/{ServiceName}`.
2. Map it in `scripts/bw-sync-config.yaml` (`k8s_secret` + `k8s_key`; several
   items may target the same Secret).
3. `./scripts/with-secrets.sh ./scripts/bw-sync.sh --target both`.
4. Reference it from the chart as `existingSecret`. Never author a k8s Secret
   in a playbook task, and never put values in a values file.

### 5. Add the deploy tasks

`ansible/playbooks/helm-deploy.yml`, in the right phase (2 = core infra, 3 =
apps, 5 = agent/AI + game servers): PVC creation, values upload, then the
`kubernetes.core.helm` task. **Pin `chart_version`** -- an unpinned task
silently upgrades whenever the repo cache moves, and renovate can only raise a
PR for versions that are pinned. Tag every task `[phaseN, {service}]`.

### 6. Fan-out obligations (enforced by `pytest -m hygiene`)

- `ansible/helm/homepage/values.yaml` -- a tile for any non-internal service.
- `ansible/docs/runbooks/{service}-down.md` -- detection, assessment, common
  causes, recovery.
- `tests/test_dns.py` -- add the domain to `EXPECTED_RECORDS`.
- `tests/conftest.py` -- only if the service answers something other than 200
  on `/` (`HEALTH_OVERRIDES`); the service list itself is derived from the
  registry.

The `HOMEPAGE_GAPS` / `RUNBOOK_GAPS` allowlists are ratcheted -- they may only
shrink. Do not add a new service to them.

### 7. Deploy

```bash
cd ansible/
ansible-playbook playbooks/zfs.yml   --tags datasets,sanoid,{service}
ansible-playbook playbooks/k3s.yml   --tags pvs
ansible-playbook playbooks/helm-deploy.yml --tags {service}
ansible-playbook playbooks/helm-deploy.yml --tags coredns   # explicit DNS record
ansible-playbook playbooks/helm-deploy.yml --tags homepage  # new tile
```

Then verify from a tailnet host:

```bash
curl -sI https://{subdomain}.lab.infiniteroomlabs.cloud/
cd tests/ && uv run pytest -m "smoke or hygiene"
```

### 8. Update docs

- `docs/plans/YYYY-MM-DD-{slug}.md` -- design doc: what was chosen and what was
  rejected, so the next person does not re-litigate it.
- `docs/homelab-access-guide.md` -- URL, node, credentials.
- `CHANGELOG.md` -- under `## [Unreleased]`.
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
cd terraform/environments/homelab/tailscale/acl
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
| `irl.dev/provider` | Who runs the infra | homelab (cloud providers when a cloud node exists) |
| `irl.dev/tier` | Architecture role | data, compute |
| `irl.dev/storage` | Backing storage | zfs, nvme |
| `irl.dev/network` | Cluster connectivity | lan, tailscale |
| `irl.dev/cost` | Billing model | owned, paid |
| `irl.dev/persistence` | How permanent | permanent, ephemeral |
| `irl.dev/gpu` | GPU availability | none |
| `irl.dev/memory-class` | Memory tier | high (24G+), standard (8-24G) |

The taxonomy is the schema, not the census: the cluster is single-node today,
so only the `home` node carries labels. Use `nodeSelector` in Helm values to
target the right node. A cloud node, if one is ever added back, carries an
`irl.dev/cloud=<provider>:NoSchedule` taint -- workloads must explicitly
tolerate it.

## Networking

- **Flannel VXLAN** over Tailscale (`flannel-iface: tailscale0`)
- **MTU**: 1230 (VXLAN 50 bytes + WireGuard 60 bytes overhead)
- **Split DNS**: CoreDNS on homelab (hostNetwork port 53), Tailscale routes `*.lab.infiniteroomlabs.cloud` to it
- **Traefik**: in-cluster, hostNetwork on 80/443, LE wildcard via DNS-01 (Cloudflare). Services are routed by IngressRoute CRDs -- either owned by their own chart or generated from `irl_traefik_standalone_services`. (Caddy was the bare-metal predecessor and is gone.)
- **NetworkPolicies** (all in `k3s.yml`, namespace-wide unless noted):
  `default-deny-all`, `allow-intra-namespace`, `allow-dns-egress`,
  `allow-ingress-tailscale` (100.64.0.0/10 -- the ONLY external entry path,
  which is what makes every service tailnet-only), `allow-egress-internet`
  (0.0.0.0/0 minus RFC1918), plus per-service ones
  (`allow-homepage-kube-api`, `allow-satisfactory-game-lan`,
  `allow-palworld-game-lan`).

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
