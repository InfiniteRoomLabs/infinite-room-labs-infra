<!-- CCSM:START -->
## Secret Handling Protocol

This project uses Claude Code Secrets Manager (CCSM). Follow these rules:

1. NEVER read, cat, echo, print, or log secret values.
2. Use placeholder syntax in shell commands: `${{SECRET:credName}}`
3. Use the `authenticated_request` MCP tool for API calls with secrets.
4. Run `ccsm secret list` to see available credentials.
<!-- CCSM:END -->

### Locked vault / stale session recovery

If bw/fnox/bw-sync/ansible-vault reports a locked vault or invalid session, run `./scripts/bw-unlock-prompt.sh` -- it pops a front-and-center terminal for the user to unlock Bitwarden (refreshing the single session cache `~/.bw_session`), then detaches. Tell the user it's waiting, then retry the failed command. Do not ask them to run `bw unlock` by hand, and never use raw `bw unlock --raw` yourself -- it may rotate the key without updating the cache. Sessions have no inactivity TTL; any subsequent unlock/lock/logout may invalidate cached keys, which is why `scripts/includes/bw-session.sh` validates every candidate.

## Repository Structure

This is a multi-tool IaC monorepo. Each IaC tool has its own top-level directory:

| Directory | Tool | Purpose |
|-----------|------|---------|
| `terraform/` | Terraform + Terragrunt | Cloud resource provisioning (domains, DNS, zones) |
| `ansible/` | Ansible | Homelab server configuration and service deployment |
| `helm-charts/` | Helm (git submodule) | IRL custom Helm charts (`irl-caddy`, `irl-garage`, etc.) |
| `docker/` | Docker | Custom container image builds (Dockerfiles only, no compose) |

Do NOT put Terraform files at the repo root -- they live under `terraform/`. Do NOT put Ansible files at the repo root -- they live under `ansible/`.

### Helm Charts (submodule)

`helm-charts/` is a **git submodule** pointing to `InfiniteRoomLabs/helm-charts`. Charts live in `helm-charts/charts/irl-{name}/`.

**Reading charts**: The submodule is always available at `./helm-charts/`. Read chart templates and values from there.

**Modifying charts**: Changes to charts must be committed in the submodule repo, then the submodule pointer updated in this repo:
```bash
cd helm-charts/
# make changes, commit, push to helm-charts remote
git add . && git commit -m "..." && git push origin main
cd ..
# update the submodule pointer in infra repo
git add helm-charts && git commit -m "Update helm-charts submodule"
```

**After cloning**: Run `git submodule update --init` to populate `helm-charts/`.

**Syncing**: If the submodule is behind, run `cd helm-charts && git pull origin main && cd .. && git add helm-charts`.

**Ansible references charts via**: `chart_ref` pointing to the local submodule path (e.g., `{{ playbook_dir }}/../../helm-charts/charts/irl-caddy`) or via the Helm repo (`helm repo add irl https://infiniteroomlabs.github.io/helm-charts/`).

**Values overrides**: Chart default values live in `helm-charts/charts/irl-{name}/values.yaml`. Environment-specific overrides live in `ansible/helm/{name}/values.yaml` (these are NOT charts -- just values files for `helm upgrade -f`).

### Terraform layout

```
terraform/
  root.hcl                              # Global Terragrunt config (TFC backend, provider versions)
  modules/                              # Reusable Terraform modules
  environments/{env}/{provider}/{rg}/   # Leaf terragrunt.hcl files per resource group
```

- **Modules** are in `terraform/modules/`. Module sources in leaf configs use `${get_repo_root()}/terraform/modules//module-name`.
- **Environments** follow `terraform/environments/{env}/{provider}/{resource-group}/`.
- **Domain lists** are in `terraform/environments/{env}/env.hcl`.
- **State** is in Terraform Cloud (org: `infinite-room-labs`). Workspace names derived from path relative to `root.hcl`.
- **Credentials** come from environment variables, never hardcoded. See `.env.example`.

### Ansible

See `ansible/CLAUDE.md` for full Ansible documentation (layout, running, secrets, SSH access).

### Tooling: mise + fnox + usage

- **mise** (`mise.toml`) pins tool versions (terraform, terragrunt, helm, kubectl, task, fnox, usage) and provides the task runner (`mise run bootstrap | secrets:sync | ansible | test:smoke`). Non-secret identifiers live in `[env]`. Run `mise install` after cloning.
- **fnox** is the secret-injection layer over Bitwarden for env-var secrets (Terraform/CLI tokens). Declared in `fnox.toml`; the bitwarden provider in global `~/.config/fnox/config.toml`. Secrets are injected per-command via `fnox exec` / `scripts/with-secrets.sh` -- never ambiently. There is NO `.env`/`.envrc`. `BW_SESSION` comes from the single cache `~/.bw_session` (fish `bw-unlock`), resolved and validated by `scripts/includes/bw-session.sh`.
- **usage** drives arg parsing for `bootstrap.sh`, `bw-sync.sh`, and `run-ansible.sh` (shebang `#!/usr/bin/env -S usage bash`, `#USAGE` directives -- note: no space after `#`).

### Secrets Sync

Two consumers, one source (Bitwarden): cluster secrets flow through `bw-sync.sh`; env-var secrets through `fnox.toml`. `scripts/bw-sync.sh` is the only authorized write path to `vault.yml`.

```
scripts/
  bw-sync.sh          # Sync script -- reads BW, writes to ansible vault and/or K8s
  bw-sync-config.yaml # Mapping of BW item names to ansible_var and k8s_secret targets
  with-secrets.sh     # Wraps a command in `fnox exec` (+ resolves BW_SESSION)
  vault-pass.sh       # Ansible vault-password client (fnox get ANSIBLE_VAULT_PASSWORD)
  includes/bw-session.sh  # Shared BW_SESSION resolver (env -> ~/.bw_session, validated)
```

Usage (prefer `mise run secrets:sync`, which wraps bw-sync in `fnox exec`):

```bash
mise run secrets:sync                         # Sync both (via fnox exec)
./scripts/with-secrets.sh ./scripts/bw-sync.sh --dry-run --target both
./scripts/with-secrets.sh ./scripts/bw-sync.sh --check-rotation
./scripts/with-secrets.sh ./scripts/bw-sync.sh --verify-k8s
```

Rotation policy: 180 days for infra secrets, 365 days for service secrets.
Full procedure: `ansible/docs/sops/rotate-secrets.md`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full guide on adding services, running Ansible/Terraform, secrets management, node labels, networking, and common gotchas.

## Testing

See [TESTING.md](TESTING.md) for the full acceptance test suite documentation.

Quick: `cd tests/ && task smoke` (17 smoke tests). Full: `task validate` (Goss + pytest + report).

## Research Protocol

- **Project-wide research**: `docs/plans/RESEARCH.md` tracks open technical questions and provider evaluations. Detailed outputs go in `docs/plans/resources/{slug}.md`.
- **Feature-scoped research**: `kitty-specs/{feature}/research.md` tracks research for a specific Spec Kitty feature.
- When a conversation surfaces an unresolved technical question (provider limits, tool comparisons, architecture trade-offs), capture it in `docs/plans/RESEARCH.md` as a new open item.
- Before starting infrastructure work that depends on an open research item, run a research round first. See the agent instructions inside `RESEARCH.md` for the workflow.
- Reference `docs/plans/infrastructure-roadmap.md` for the master plan and phase sequencing.
