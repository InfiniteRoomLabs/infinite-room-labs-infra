# Ansible -- Infinite Room Labs Homelab Automation

## Running Ansible

**Local (preferred)**: Uses uv-managed virtualenv in this directory.

```bash
cd ansible/
uv run ansible-playbook playbooks/<playbook>.yml
uv run ansible-galaxy install -r requirements.yml
```

**Docker runner (legacy)**: `./run-ansible.sh playbook playbooks/<playbook>.yml` -- runs in a container. Cannot use local SSH config, agent forwarding, or jump boxes.

**Full site run**: `uv run ansible-playbook site.yml` or target a phase with `--tags phase0`.

## Dependencies

- `pyproject.toml` tracks Python deps (ansible-core, jmespath, kubernetes, openshift)
- `requirements.yml` tracks Galaxy collections and roles
- Run `uv sync` then `uv run ansible-galaxy install -r requirements.yml` after cloning

## Directory Layout

```
ansible.cfg                             # YAML output, pipelining, fact caching
pyproject.toml                          # Python dependencies (uv-managed)
Dockerfile                              # Legacy containerized runner
run-ansible.sh                          # Legacy runner wrapper
requirements.yml                        # Galaxy collections and roles
site.yml                                # Master orchestrator (imports playbooks in order)
inventory/
  hosts.ini                             # Homelab via Tailscale IP (100.86.213.22)
  group_vars/all/main.yml               # Global vars (domains, compose paths, services)
  group_vars/all/vault.yml              # Ansible Vault encrypted secrets -- DO NOT EDIT
  group_vars/homelab/main.yml           # Homelab group vars (firewall ports)
  group_vars/digitalocean/main.yml      # DO k3s agent vars (tailscale hostname, firewall)
  host_vars/homelab.yml                 # Resource-scaled params (RAM budgets, PG tuning)
playbooks/                              # One playbook per concern, flat structure
templates/                              # Jinja2 templates for configs and compose files
files/                                  # Static files (dashboards, sanoid config)
docs/sops/                              # Standard operating procedures
docs/runbooks/                          # Incident runbooks
```

## Playbook Conventions

- **Flat structure**: one playbook per concern, no roles. Imported by `site.yml` in dependency order.
- **Phases**: site.yml is tagged `phase0`-`phase5`. Run a phase: `--tags phase0`.
- **FQCN required**: always use fully-qualified collection names (e.g., `ansible.builtin.command`, not `command`).
- **Compose stacks** deploy to `/opt/irl/{stack}/docker-compose.yml` on the server.

## Secrets

- **Source of truth**: Bitwarden vault, `IRL/` folder tree.
- **Sync tool**: `../scripts/bw-sync.sh` -- the only authorized write path to `vault.yml`. Run via `mise run secrets:sync` (wraps it in `fnox exec` so `BW_SESSION` is present).
- **vault.yml** (`inventory/group_vars/all/vault.yml`): Ansible Vault encrypted. Never edit manually.
- **Vault password**: provided by fnox. `ansible.cfg` sets `vault_password_file = ../scripts/vault-pass.sh`, an executable that runs `fnox get ANSIBLE_VAULT_PASSWORD` (Bitwarden item `ansible-vault-password`). No `.vault-password` file, no direnv. Run local ansible from `ansible/` so the relative path resolves. The legacy Docker runner resolves the password on the host via fnox and mounts it (fnox is absent inside the container).
- **fnox session**: the vault-password client needs `BW_SESSION`, resolved and validated by `../scripts/includes/bw-session.sh` (env, then the `~/.bw_session` cache). If missing or invalid, run `bw-unlock` (fish) or `../scripts/bw-unlock-prompt.sh` -- never raw `bw unlock --raw`, which may rotate the key without updating the cache.
- **Rotation policy**: 180 days for infra secrets, 365 days for service secrets. Full SOP: `docs/sops/rotate-secrets.md`.

## SSH Access

- **Homelab**: `100.86.213.22` via Tailscale (`homelab-ts` in SSH config)
- **DO k3s agent**: `100.102.210.70` via Tailscale (`do-k3s` in SSH config)
- **Jump box**: if homelab is unreachable directly, use `ssh -A -J do-k3s homelab-ts` (requires `AllowTcpForwarding yes` on the DO box)
- **ansible.cfg** disables host key checking and enables SSH pipelining with ControlMaster
