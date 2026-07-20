# AGENTS.md -- infinite-room-labs-infra (for Codex)

Read `~/.codex/AGENTS.md` (global) and `./CLAUDE.md` (this repo) first. `CLAUDE.md`
is the authoritative brief and applies to you too.

## What this repo is

Multi-tool IaC monorepo. Each tool has its own top-level dir -- do NOT put files at
the repo root:
- `terraform/` -- Terraform + Terragrunt (cloud/DNS/zones). Hierarchy:
  `terraform/environments/{env}/{provider}/{resource-group}/`; modules in
  `terraform/modules/`; state in Terraform Cloud (org `infinite-room-labs`).
- `ansible/` -- homelab server config + Helm deploys (run via
  `ansible/run-ansible.sh`). Deploys go through Ansible, never `helm` by hand.
- `helm-charts/` -- git SUBMODULE (`InfiniteRoomLabs/helm-charts`); edit + commit
  in the submodule, then bump the pointer here.
- `docker/` -- Dockerfiles only (no compose).

## Codex-critical: secret handling differs for you

This repo's `CLAUDE.md` documents **CCSM (Claude Code Secrets Manager)**: the
`${{SECRET:credName}}` placeholder syntax and the `authenticated_request` MCP tool.
**That MCP tool is Claude-Code-only and is NOT available to you.** Therefore:
- Never read/cat/echo/log secret values (same hard rule as always).
- Do not fabricate or hand-expand `${{SECRET:...}}` placeholders.
- For any operation that actually needs a secret, use `bw`/`fnox` per the global
  brief, or defer it and tell Wes -- do not route around the missing MCP tool.

Vault password for Ansible lives at `~/.secrets/ansible-vault-password`
(`ANSIBLE_VAULT_PASSWORD_FILE`). Bitwarden is the source of truth; cluster secrets
sync via `scripts/bw-sync.sh`.

## Docs

`docs/homelab-access-guide.md` (full access instructions), `docs/plans/` (infra
plans incl. the k3s/Helm deployment + observability architecture).

Keep this AGENTS.md and `CLAUDE.md` in sync.
