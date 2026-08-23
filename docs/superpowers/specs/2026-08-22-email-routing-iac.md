# Task: Email Routing into IaC -- backfill existing config + DMARC client-reporting pipeline

## Objective

Bring infiniteroomlabs.com's Cloudflare Email Routing fully under Terraform and stand up the
client DMARC-report pipeline: any client domain can set
`rua=mailto:clients-dmarc@infiniteroomlabs.com` and reports flow to us with zero per-client
changes on our side. Complete when:

1. `*._report._dmarc.infiniteroomlabs.com` TXT `"v=DMARC1"` exists (wildcard external-report
   authorization per RFC 7489 §7.1 -- what lets Google/Microsoft send reports for third-party
   domains to ours).
2. Our own `_dmarc.infiniteroomlabs.com` gains `rua=mailto:clients-dmarc@infiniteroomlabs.com`
   (currently `v=DMARC1; p=none;` -- we collect nothing today). Same-domain rua needs no
   authorization record. Policy stays `p=none`.
3. All existing dashboard-created Email Routing state is imported and managed: routing
   settings, the verified destination address, the `wes@` forwarding rule, and the catch-all.
4. New Email Routing rule `clients-dmarc@infiniteroomlabs.com` -> the same (imported)
   destination.
5. After imports + apply, `terragrunt plan` is empty across all touched units, and the
   verification commands below pass. Behavioral invariant: `wes@` delivers exactly as before.

## Context & Constraints

- Cloudflare provider pinned `~> 5.17` via `terraform/root.hcl`'s generated providers.tf -- do
  NOT add `required_providers` blocks to new modules (see the comment atop
  `environments/global/cloudflare/tokens/main.tf`; follow the `cloudflare-dns-records` module
  convention, not `cloudflare-pages`).
- Provider 5.x supports everything we need: `cloudflare_email_routing_rule`,
  `cloudflare_email_routing_catch_all`, `cloudflare_email_routing_settings` (zone-scoped), and
  `cloudflare_email_routing_address` (account-scoped, import syntax
  `<account_id>/<destination_address_identifier>`). Check each resource's 5.x registry doc for
  exact schema and import ID format before writing HCL -- several of these changed shape in the
  v4->v5 migration (matchers/actions became attribute lists).
- infiniteroomlabs.com DNS records live in `environments/prod/env.hcl` local
  `sendgrid_dns_records`, consumed by `environments/prod/cloudflare/dns-records/terragrunt.hcl`
  via `modules/cloudflare-dns-records` (`for_each` keyed `"${type}-${name}"`).
- Secrets convention: `get_env(...)` in env.hcl (see `cloudflare_account_id`).

## Tasks

**T1 -- DNS records (`environments/prod/env.hcl` + prod dns-records unit)**
- Rename local `sendgrid_dns_records` -> `email_dns_records`; group entries under comment
  headers (`SendGrid link branding`, `SendGrid domain auth`, `DKIM/DMARC`, `DMARC client
  reporting`). Update the reference in `environments/prod/cloudflare/dns-records/terragrunt.hcl`.
  Churn-free: resource keys derive from `type`+`name`, not the local's name.
- Append: `{ name = "*._report._dmarc", type = "TXT", content = "v=DMARC1" }`
- Edit the existing `_dmarc` entry content to:
  `v=DMARC1; p=none; rua=mailto:clients-dmarc@infiniteroomlabs.com`

**T2 -- Email routing module (`terraform/modules/cloudflare-email-routing`)**
- `main.tf` / `variables.tf` / `outputs.tf`, house module style. Manages, for one zone:
  - `cloudflare_email_routing_settings` (routing enabled -- import current state, don't toggle)
  - `cloudflare_email_routing_rule` `for_each` over `rules` = list of
    `{ custom_address, destination }` (matcher literal/to; action forward)
  - `cloudflare_email_routing_catch_all` (single object var mirroring the live config)
  - `cloudflare_email_routing_address` for the verified destination (account-scoped; takes
    `account_id` + `email`). This exists ONLY to be imported -- never let a plan show it as a
    create, because creating destination addresses triggers a verification-email loop.
- Inputs: `zone_id`, `account_id`, `bootstrap_api_token`, `destination_email` (sensitive),
  `rules`, `catch_all`.

**T3 -- Environment unit (`environments/prod/cloudflare/email-routing/terragrunt.hcl`)**
- Mirror `prod/cloudflare/dns-records/terragrunt.hcl` (root + provider includes,
  `bootstrap_tokens` + `prod_zones` dependencies with mock_outputs for validate/plan).
- Destination from `get_env("IRL_EMAIL_ROUTING_DESTINATION", "")` in env.hcl; sensitive in the
  module. Rules input: the existing `wes@` rule plus the new `clients-dmarc@` rule, both ->
  that destination.

**T4 -- Backfill imports (existing dashboard config -> state)**
- Discover live IDs with the bootstrap-derived token:
  `GET /zones/{zone_id}/email/routing/rules` (rule IDs incl. catch-all),
  `GET /accounts/{account_id}/email/routing/addresses` (destination address identifier).
- Write the module config to match live reality FIRST (field-for-field), then
  `terragrunt import` each: settings, destination address, `wes@` rule, catch-all. Confirm
  each resource's import ID syntax against its 5.x doc page -- do not guess.
- Acceptance: `terragrunt plan` after imports shows exactly ONE create (the `clients-dmarc@`
  rule) and nothing else. Any diff on an imported resource means the config doesn't match
  live -- fix the config, never "apply through" a diff on imported resources.

**T5 -- Token permissions (`environments/global/cloudflare/tokens/main.tf`)**
- The `infra` account token currently has zone/DNS/tunnel/access groups only. Add the zone
  Email Routing write group (read counterpart if paired) AND the account-level Email Routing
  Addresses read/write groups (the destination address is account-scoped). Verify permission-
  group UUIDs against the live API
  (`GET /accounts/{account_id}/tokens/permission_groups`) rather than a gist; comment each
  UUID with name + verification date.
- Apply order, documented in the PR description: `global/cloudflare/tokens` first, then
  `prod/cloudflare/email-routing`.

**T6 -- Docs**
- Add `docs/dmarc-client-reporting.md`: what the wildcard record does, one-step client
  onboarding (set client's `rua=` to `clients-dmarc@infiniteroomlabs.com` -- nothing needed on
  our side), where reports land, note that Email Routing is now Terraform-managed (dashboard
  edits will drift), and that parsedmarc ingestion is a recorded follow-up, not part of this
  task.

## Anti-Goals (do not do)

- No behavioral changes to existing routing: settings, catch-all, and `wes@` are imported
  as-is; values in HCL must mirror live config exactly.
- Never CREATE a `cloudflare_email_routing_address` -- import only (creation fires a
  verification-email loop).
- No changes to any client zone (the pilot client zone is dashboard-managed, different tenancy).
- No `p=` policy changes, no `ruf=` (forensic) tags, no parsedmarc deployment.

## Expected churn

- `prod/cloudflare/dns-records`: 1 create (`TXT-*._report._dmarc`), 1 in-place update
  (`TXT-_dmarc` content). Zero changes to SendGrid records.
- `global/cloudflare/tokens`: 1 in-place update (policy permission groups).
- `prod/cloudflare/email-routing`: 4 imports (settings, destination address, `wes@` rule,
  catch-all), then exactly 1 create (`clients-dmarc@` rule).

Anything beyond this list is a defect -- stop and investigate before apply.

## Verification (post-apply)

```bash
# Wildcard resolves for an arbitrary client label:
dig +short TXT clientdomain.com._report._dmarc.infiniteroomlabs.com @1.1.1.1   # -> "v=DMARC1"
# Own-domain rua present:
dig +short TXT _dmarc.infiniteroomlabs.com @1.1.1.1                          # -> contains rua=mailto:clients-dmarc@
# Plans clean everywhere:
terragrunt plan  # (each touched unit) -> no changes
# Routing works: test message to clients-dmarc@ arrives at destination;
# test message to wes@ still arrives (behavioral invariant).
```
