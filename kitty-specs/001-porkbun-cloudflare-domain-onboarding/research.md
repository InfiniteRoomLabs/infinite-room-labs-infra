# Research Decision Log

## Summary

- **Feature**: 001-porkbun-cloudflare-domain-onboarding
- **Date**: 2026-02-12
- **Researchers**: cloudflare-researcher, porkbun-researcher, terragrunt-researcher
- **Open Questions**: TFC organization name, TFC execution mode preference, Cloudflare account ID sourcing

## Decisions & Rationale

| Decision | Rationale | Evidence | Status |
|----------|-----------|----------|--------|
| Use `cloudflare_zone` resource for zone creation | Only resource for zone management; returns `name_servers` output needed for Porkbun delegation | E-001 | final |
| Use `porkbun_domain_nameservers` resource for NS updates | Purpose-built resource; accepts domain + nameserver set; exactly matches our use case | E-002 | final |
| Use Terragrunt `generate` block for TFC backend (not `remote_state`) | Terragrunt `remote_state` only auto-creates resources for S3/GCS; TFC requires `generate` approach | E-003 | final |
| Use `cloud {}` block (not `backend "remote"`) | Newer syntax (Terraform 1.1+); recommended going forward; both work but `cloud {}` is the standard | E-003 | final |
| Derive TFC workspace names from directory path: `{env}-{provider}-{resource-group}` | Ensures 1:1 mapping between directory structure and TFC workspaces; workspace names are unique and predictable | E-003 | final |
| Use TFC local execution mode | Terragrunt `inputs` exported as `TF_VAR_*` are NOT honored in TFC remote execution mode; local mode avoids this limitation while still storing state in TFC | E-004 | final |
| Provider credentials via environment variables | Both providers support env vars (`CLOUDFLARE_API_TOKEN`, `PORKBUN_API_KEY`, `PORKBUN_SECRET_KEY`); simplest for local execution; no secrets in code | E-005 | final |
| Zone type `"full"` (default) | Full DNS hosting is required for Cloudflare to serve as authoritative nameserver; partial zones don't apply here | E-001 | final |
| Separate Cloudflare zones and Porkbun nameservers into distinct resource groups | Follows constitution's "small blast radius" principle; allows independent state management; Porkbun NS updates depend on Cloudflare zone outputs via `dependency` block | E-003, E-006 | final |

## Evidence Highlights

### Cloudflare Provider (E-001)

- **`cloudflare_zone`** is the primary resource. Required inputs: `account.id` (string) and `name` (domain string).
- Critical output: `name_servers` (List of String) — the Cloudflare-assigned nameservers that must be set at the registrar.
- Zone starts in `"pending"` status until NS delegation is verified by Cloudflare.
- Data source `cloudflare_zone` available for looking up existing zones by name filter.
- Provider auth: `api_token` via `CLOUDFLARE_API_TOKEN` env var (recommended over global API key).

### Porkbun Provider (E-002)

- **`porkbun_domain_nameservers`** is the exact resource needed. Inputs: `domain` (string) and `nameservers` (Set of String).
- Provider is community-maintained (jianyuan), small and focused: 2 resources, 4 data sources.
- `nameservers` is a **Set** (not List) — ordering doesn't matter.
- Data source `porkbun_domain_nameservers` can read current NS for verification.
- Data source `porkbun_domains` can list all domains in account — useful for validation.
- Auth: `api_key` + `secret_key` via `PORKBUN_API_KEY` and `PORKBUN_SECRET_KEY` env vars.

### Terragrunt Structure (E-003)

- Directory hierarchy `environment/provider/resource-group/` maps cleanly to the constitution's requirements.
- Variable inheritance uses `include` + `read_terragrunt_config(find_in_parent_folders("env.hcl"))` pattern.
- Three levels of config files: `root.hcl` (global), `env.hcl` (per environment), `provider.hcl` (per provider).
- Leaf `terragrunt.hcl` files reference modules via `terraform { source = "${get_repo_root()}/modules//module-name" }`.

### TFC Execution Mode (E-004)

- **Critical caveat**: TFC remote execution mode does NOT honor `TF_VAR_*` environment variables set by Terragrunt `inputs`. This breaks the standard Terragrunt workflow.
- **Local execution mode** stores state in TFC but runs plan/apply locally — `inputs` work normally.
- For a CLI-driven Terragrunt workflow, local execution is the pragmatic choice.

### Credential Management (E-005)

- Both providers support reading credentials from environment variables with no provider block config needed.
- For TFC with local execution: credentials come from the operator's environment.
- For future TFC remote execution: credentials would need to be TFC Variable Sets attached to workspaces.

### Cross-Resource Dependencies (E-006)

- Porkbun nameserver updates depend on Cloudflare zone creation (need the `name_servers` output).
- Terragrunt `dependency` blocks handle this: the Porkbun resource group declares a dependency on the Cloudflare zones resource group.
- This means `terragrunt run-all apply` from the environment root will apply in the correct order.

## Risks / Concerns

- **Porkbun provider maturity**: Community-maintained, v0.2.1, small user base. May have edge cases or lag behind API changes. Mitigated by the simple schema (only 2 resources).
- **Zone pending status**: Cloudflare zones stay `"pending"` until NS records are verified. There may be a delay between Porkbun NS update and Cloudflare verification. This is expected behavior and not a Terraform concern.
- **TFC workspace creation**: Terragrunt does NOT auto-create TFC workspaces (unlike S3 buckets). Workspaces must be created manually in TFC or via a bootstrap `tfe_workspace` resource before first `terragrunt init`.

## Next Actions

1. Confirm TFC organization name with user (needed for `root.hcl` configuration).
2. Confirm Cloudflare account ID sourcing strategy (hardcoded in env vars? data source lookup?).
3. Proceed to `/spec-kitty.plan` to design the module structure and Terragrunt hierarchy.
