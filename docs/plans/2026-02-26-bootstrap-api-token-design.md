# Bootstrap Cloudflare API Token Creation

**Date:** 2026-02-26
**Status:** Approved

## Problem

The Cloudflare API token used by downstream Terraform resource groups (zone creation, DNS management) is manually created in the Cloudflare dashboard and copied into `.env`. This is a manual step that should be automated as part of the bootstrap process.

## Decision

Add a new bootstrap resource group that creates a scoped Cloudflare API token via Terraform, stores it in state, and passes it to downstream resource groups via Terragrunt dependency outputs with an environment variable fallback.

## Approach

**Approach A (selected):** Separate resource group at `terraform/environments/global/cloudflare/tokens/` with local state, mirroring the existing TFC workspace bootstrap pattern. Each concern gets its own isolated resource group.

Rejected alternatives:
- **B: Inline in TFC bootstrap** -- mixes providers and concerns in one layer.
- **C: Reusable module** -- over-engineering for a single token resource.

## Design

### New resource group: `terraform/environments/global/cloudflare/tokens/terragrunt.hcl`

- Uses local state (no TFC backend) to avoid chicken-and-egg
- Authenticates with `CLOUDFLARE_BOOTSTRAP_API_TOKEN` (manually created token with "API Tokens Write" permission only)
- Reads `CLOUDFLARE_ACCOUNT_ID` from environment
- Uses `cloudflare_api_token_permission_groups` data source to look up permission IDs by name
- Creates one `cloudflare_api_token` with Zone Read + Zone Write scoped to the account
- Outputs the token value (sensitive)
- Token permissions can be broadened in-place later without recreating the token

### Downstream provider change: `terraform/environments/{env}/cloudflare/provider.hcl`

- Adds a `variable "bootstrap_api_token"` (type string, default `""`)
- Provider uses: `api_token = var.bootstrap_api_token != "" ? var.bootstrap_api_token : null`
- When `null`, the provider falls back to reading `CLOUDFLARE_API_TOKEN` from the environment

### Downstream dependency: `terraform/environments/{env}/cloudflare/zones/terragrunt.hcl`

- Declares `dependency "bootstrap_tokens"` pointing at `../../../../global/cloudflare/tokens`
- Uses `mock_outputs` with `api_token = ""` for plan/validate before bootstrap is applied (falls back to env var)
- Passes `bootstrap_api_token = dependency.bootstrap_tokens.outputs.api_token` in inputs

### Bootstrap script: `scripts/bootstrap.sh`

- 12-factor: all config from environment variables sourced from `.env`
- Sources `.env` via shared helper at `scripts/includes/env.sh`
- Validates required bootstrap env vars are set before proceeding
- Runs `terragrunt init && terragrunt apply` for TFC workspaces, then Cloudflare tokens
- Supports `--help`, `--plan` (dry run), and `--skip-tfc` flags
- Documented in README.md

### Helper: `scripts/includes/env.sh`

- `load_env()` -- sources `.env` from repo root (located relative to script)
- `require_vars()` -- checks a list of env var names are non-empty, exits with clear error on missing

## Environment variables

| Variable | Purpose | Where used |
|---|---|---|
| `CLOUDFLARE_BOOTSTRAP_API_TOKEN` | Manually-created token with "API Tokens Write" | Bootstrap only (token creation) |
| `CLOUDFLARE_API_TOKEN` | Fallback for downstream if bootstrap output unavailable | Downstream resource groups |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare account ID | Bootstrap + downstream |

## Apply sequence

```
1. scripts/bootstrap.sh          # or manually:
2.   terragrunt apply             (global/tfc/workspaces)
3.   terragrunt apply             (global/cloudflare/tokens)
4. terragrunt run-all apply       (dev/ or prod/)
```

## Files changed

| File | Change |
|---|---|
| `terraform/environments/global/cloudflare/tokens/terragrunt.hcl` | New -- bootstrap token creation |
| `terraform/environments/dev/cloudflare/provider.hcl` | Add bootstrap_api_token variable + fallback |
| `terraform/environments/prod/cloudflare/provider.hcl` | Same |
| `terraform/environments/dev/cloudflare/zones/terragrunt.hcl` | Add dependency on bootstrap tokens |
| `terraform/environments/prod/cloudflare/zones/terragrunt.hcl` | Same |
| `scripts/bootstrap.sh` | New -- bootstrap orchestration |
| `scripts/includes/env.sh` | New -- shared env helpers |
| `.env.example` | Already updated |
| `.envrc` | Already updated |
| `README.md` | Add bootstrap documentation |

## Caveats

- Known Cloudflare provider bug ([#5547](https://github.com/cloudflare/terraform-provider-cloudflare/issues/5547)): scoping to `com.cloudflare.api.account.zone.*` may fail. Scope to the account level instead.
- The v5.13+ provider requires `jsonencode()` around all policy resource values.
- The token value lives in local state on the operator's machine. Keep the state file secure.
- Destroying the bootstrap layer revokes the downstream token.
