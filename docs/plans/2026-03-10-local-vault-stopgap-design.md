# Local Vault Stopgap Design

**Date**: 2026-03-10
**Status**: Approved
**Author**: Wes Gilleland + Claude Opus 4.6
**Relates to**: `infrastructure-roadmap.md`, `2026-03-07-infrastructure-expansion-design.md`

## Overview

Install HashiCorp Vault as a systemd service on the local development laptop (Ubuntu 24.04, x86_64) as a company-wide secrets management stopgap. This runs until the Hetzner CAX21 ARM VPS is provisioned (Phase 1 of the infrastructure roadmap).

This also scaffolds the `ansible/` directory in the infra monorepo -- the first Ansible role in the project.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Install grade | Production-lite | Real secrets storage, but no HA/backup/audit. Transfers to Hetzner deploy. |
| Storage backend | Integrated Raft | HashiCorp-recommended default. Single-node Raft works fine, no migration needed when adding nodes later. |
| TLS | Disabled, localhost-only | Single-user laptop, `127.0.0.1` binding only. TLS added when deploying to Hetzner. |
| Unseal strategy | Single key + auto-unseal script | 1 key share, threshold 1. systemd ExecStartPost auto-unseals. Avoids manual unseal on every reboot. |
| Install method | Official binary | GPG-verified release binary at `/usr/bin/vault`. No snap, no Docker. |
| Ansible layout | Flat roles | `ansible/roles/{service}/` with a single `site.yml` entrypoint and `--tags` per service. |

## Vault Configuration

### Paths

| Path | Purpose | Owner | Mode |
|------|---------|-------|------|
| `/usr/bin/vault` | Vault binary | `root:root` | `0755` |
| `/etc/vault.d/vault.hcl` | Main config | `vault:vault` | `0640` |
| `/etc/vault.d/vault.env` | Environment vars | `vault:vault` | `0640` |
| `/opt/vault/data` | Raft data directory | `vault:vault` | `0700` |
| `/opt/vault/bin/vault-unseal.sh` | Auto-unseal script | `root:root` | `0700` |
| `/root/.vault-init-keys` | Unseal key + root token | `root:root` | `0600` |
| `/etc/profile.d/vault.sh` | Shell env for all users | `root:root` | `0644` |

### Config (`vault.hcl`)

```hcl
ui = true

listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = true
}

storage "raft" {
  path    = "/opt/vault/data"
  node_id = "local-1"
}

api_addr     = "http://127.0.0.1:8200"
cluster_addr = "http://127.0.0.1:8201"

disable_mlock = true
```

- **UI enabled** for visual exploration
- **`disable_mlock = true`** avoids `IPC_LOCK` capability requirement on a laptop
- **Logs** go to systemd journal

### Systemd Unit

- Runs as `vault` user
- `Type=notify` (Vault supports systemd notification)
- `ExecStartPost` calls the unseal script
- `Restart=on-failure`, `RestartSec=5`

### Auto-Unseal Flow

1. First run: `vault operator init -key-shares=1 -key-threshold=1`
2. Saves root token and unseal key to `/root/.vault-init-keys`
3. Unseal script reads the key, calls `vault operator unseal`
4. systemd runs the script after Vault starts

### Not Included (Deferred to Hetzner)

- TLS certificates
- Audit device
- AppRole / OIDC auth backends
- KV engine provisioning (manual post-install)
- Backup automation
- Firewall rules

## Ansible Directory Structure

```
ansible/
  ansible.cfg              # Project-level config (roles path, inventory, defaults)
  site.yml                 # Master playbook entrypoint (--tags selects services)
  requirements.yml         # Galaxy/collection dependencies
  inventory/
    hosts.yml              # Static inventory (localhost now, Hetzner later)
    group_vars/
      all.yml              # Shared variables
      vault_servers.yml    # Vault-specific group variables
  roles/
    vault/
      defaults/main.yml    # All tunables with full documentation
      tasks/main.yml       # Task entrypoint
      tasks/install.yml    # Download + install Vault binary
      tasks/configure.yml  # Config file, data dir, systemd unit
      tasks/init.yml       # vault operator init (first run only)
      tasks/unseal.yml     # Auto-unseal helper
      handlers/main.yml    # Restart/reload handlers
      templates/
        vault.hcl.j2       # Main Vault config template
        vault.service.j2   # Systemd unit template
        vault-unseal.sh.j2 # Auto-unseal script template
      vars/main.yml        # Internal role vars (not user-facing)
      meta/main.yml        # Role metadata, dependencies
      README.md            # Role docs: purpose, variables, examples
```

### Ansible Conventions (Established Here, Applied to All Future Roles)

1. **`defaults/main.yml` is the variable interface.** Every tunable has a comment block: what it does, valid values, default rationale. This is the single source of truth for "what can I configure."
2. **`README.md` per role.** Purpose, requirements, variables table, example playbook, and post-install notes.
3. **`site.yml` with tags.** One entrypoint, `--tags vault` selects the role. No per-service playbook files unless complexity demands it.
4. **No magic.** Explicit variable names, no implicit defaults hiding behavior. An AI agent or new team member operates any role from its interface alone.
5. **Tasks split by phase.** `install.yml`, `configure.yml`, `init.yml` -- not one 200-line `main.yml`.

## Documentation Updates

### Files to Create

| File | Purpose |
|------|---------|
| `ansible/CLAUDE.md` | Ansible conventions, how to run, role structure, variable docs requirements |
| `ansible/roles/vault/README.md` | Role-specific docs |
| `ansible/roles/vault/defaults/main.yml` | Self-documenting defaults |

### Files to Update

| File | Change |
|------|--------|
| `infinite-room-labs-infra/CLAUDE.md` | Add Ansible to repo structure table, add Vault awareness |
| `infinite-room-labs-infra/README.md` | Add Ansible usage section |
| `docs/plans/infrastructure-roadmap.md` | Note local Vault stopgap under Phase 1 |
| `~/CLAUDE.md` | Add Vault binary location and `VAULT_ADDR` |
| `~/.claude/CLAUDE.md` | Add `VAULT_ADDR` to environment |
| `~/.claude/projects/.../memory/MEMORY.md` | Add Vault knowledge |
| `ideas/ideas/005-secrets-iam-framework.md` | Note Vault is now deployed locally |
| `ideas/strategic-roadmap.md` | Update infrastructure layer status |

## Environment Integration

After install, every shell session gets:

```sh
export VAULT_ADDR="http://127.0.0.1:8200"
```

Via `/etc/profile.d/vault.sh` (works for bash, zsh, fish via `fenv` or native support).

The infra repo `.envrc` does NOT need to change -- `VAULT_ADDR` is system-wide, not project-specific.

## Success Criteria

1. `vault status` returns sealed=false after a reboot without manual intervention
2. `vault kv put secret/test foo=bar && vault kv get secret/test` round-trips
3. `systemctl status vault` shows active, enabled
4. All CLAUDE.md files updated so any Claude session knows Vault exists
5. Ansible role is idempotent -- running it twice changes nothing
