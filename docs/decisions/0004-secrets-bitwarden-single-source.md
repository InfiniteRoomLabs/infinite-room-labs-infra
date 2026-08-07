# 0004. Bitwarden as single secret source: bw-sync for cluster, fnox for env-vars

Date: 2026-05-29 (fnox migration commit 55c5c5d; the cluster-sync half predates it, commit fa98a3b, 2026-03-21)

## Status

Accepted

## Context

Secrets in this repo serve two different consumers with different lifecycles:

1. **Cluster secrets**: passwords and tokens that must exist as Ansible Vault variables (`ansible/inventory/group_vars/all/vault.yml`) and/or Kubernetes Secrets in the `irl` namespace, consumed by playbooks and Helm charts via `existingSecret` references.
2. **Env-var secrets**: provider tokens (Cloudflare, Terraform Cloud, DigitalOcean, Porkbun, Tailscale, Docker Hub, SendGrid, Garage S3 state-backend keys, the Ansible vault password itself) that CLIs and Terraform expect as environment variables at invocation time.

Before 2026-05-29, env-var secrets were loaded ambiently: two `.envrc` files (direnv) and reads from `~/.secrets/` files. Ambient loading means any process started in the directory inherits every credential, and there is no per-command scoping. Cluster secrets already flowed through `scripts/bw-sync.sh` (introduced 2026-03-21 with the initial homelab automation), which reads Bitwarden and writes Ansible Vault and Kubernetes Secrets from a declarative mapping file.

Maintaining hand-edited vault.yml entries or scattered secret files invites drift between stores and makes rotation auditing impossible. A single authoritative store with mechanical, declarative fan-out was needed for both consumer paths.

## Decision

**Bitwarden is the single source of truth for all secrets**, held under the `IRL/` folder. Two mechanical consumer paths fan out from it; no secret value is ever committed or hand-copied into a second store.

**Cluster path -- `scripts/bw-sync.sh`:**

- Declarative mapping in `scripts/bw-sync-config.yaml`: each entry names a `bw_item` plus optional `ansible_var` (dotted path into vault.yml) and `k8s_secret`/`k8s_key`/`k8s_namespace` targets.
- `bw-sync.sh --target ansible|k8s|both` performs the sync; it is the only authorized write path to `vault.yml` (CLAUDE.md). Supporting modes: `--dry-run`, `--verify-k8s` (read-only drift check), `--check-rotation` (reports secrets past their rotation deadline; policy is 180 days for infra secrets, 365 for service secrets).
- The script keeps a per-target checksum state file to skip unchanged items, writes an audit log that "never logs values", and emits Prometheus textfile metrics (`irl_secrets.prom`).

**Env-var path -- fnox:**

- `fnox.toml [secrets]` declares each env var with a Bitwarden item reference (`value = "item"` for a Login password field, `"item/notes"` for a secure-note body). Values are fetched live from Bitwarden and never stored in the file, so it is safe to commit.
- Secrets materialize only per-command via `fnox exec` (wrapped by `scripts/with-secrets.sh`), never ambiently. Both `.envrc` files were deleted in the migration commit; six migrated `~/.secrets/` files were retired after verifying fnox served their values.
- The Ansible vault password rides the same path: `ansible.cfg` points `vault_password_file` at `scripts/vault-pass.sh`, which resolves `ANSIBLE_VAULT_PASSWORD` through fnox.
- Non-secret identifiers (account ids, URLs, usernames) deliberately live in `mise.toml [env]`, not fnox.

Both paths depend on an unlocked Bitwarden session. `BW_SESSION` is resolved from a single cache (`~/.bw_session`) by the shared `scripts/includes/bw-session.sh`, with every candidate validated against `bw status` before use.

## Consequences

Positive:

- One place to create, rotate, or revoke a secret; both fan-out paths are re-runs of an idempotent sync, and `--verify-k8s` detects drift between Bitwarden and the cluster.
- No ambient credentials: a shell sitting in the repo directory holds nothing; only the exact command under `fnox exec` sees the declared env vars. `scripts/mcp-grafana.sh` goes further, fetching a single token via `fnox get` under `env -i` so a third-party binary never sees infra-wide credentials.
- The mappings themselves (`bw-sync-config.yaml`, `fnox.toml`) are reviewable, diffable code; the hygiene test suite asserts every `existingSecret` in `ansible/helm/*/values.yaml` maps to a `bw-sync-config.yaml` entry (commit 3cb8fb4).
- Rotation policy is enforceable mechanically (`--check-rotation`, run by a daily cron per the parent CLAUDE.md).

Negative / accepted costs:

- Everything hinges on one dependency chain: Bitwarden availability plus a valid `BW_SESSION`. Session-handling bugs were the dominant failure mode in practice -- stale inherited sessions silently broke vault decryption (fixed 2026-07-13, commit 3728a7d, by validating candidates) and a second age-encrypted session copy in the global fnox config shadowed the cache (removed 2026-07-28, commit a963eed, collapsing to the single `~/.bw_session` store plus shared resolver, covered by stub-`bw` hygiene tests).
- The sync script accretes real complexity: shipped bugs include yq shell-interpolation breaking on JSON values and the unscoped checksum state making `--target both` skip k8s writes (both fixed 2026-04-10, commits 9ea8b88 and 9335446), and a vault-id conflict (ccf36da). A troubleshooting runbook exists for it (`ansible/docs/runbooks/bw-sync-troubleshooting.md`).
- Field-mapping is convention-dependent: pointing `ANSIBLE_VAULT_PASSWORD` at `/notes` instead of the password field silently fed rotation-metadata JSON to ansible and broke vault decryption (fixed 2026-06-02, commit 2be5069; warning now inlined in `fnox.toml`).
- Two config files must stay coherent with Bitwarden item names; adding a secret is a three-step process (BW item, mapping entry, sync) documented in the parent CLAUDE.md and the `manage-secrets` skill.
