# DMARC client reporting

Any client domain can send its DMARC aggregate reports to `clients-dmarc@infiniteroomlabs.com` with no per-client change on our side.

## How it works

- `_dmarc.<client-domain>` carries `rua=mailto:clients-dmarc@infiniteroomlabs.com`.
- Receivers (Google, Microsoft, Yahoo, ...) check that infiniteroomlabs.com agrees to receive reports for that domain by looking up `<client-domain>._report._dmarc.infiniteroomlabs.com` TXT (RFC 7489 section 7.1).
- We publish the wildcard `*._report._dmarc.infiniteroomlabs.com TXT "v=DMARC1"`, which answers that lookup for every client domain at once.
- Cloudflare Email Routing forwards `clients-dmarc@` to the operator mailbox (same destination as `wes@`).

Our own `_dmarc.infiniteroomlabs.com` also sets `rua=mailto:clients-dmarc@infiniteroomlabs.com`; same-domain `rua` needs no authorization record. Policy stays `p=none`.

## Onboarding a client (one step)

Set, in the client's DNS:

```
_dmarc.<client-domain>  TXT  "v=DMARC1; p=none; rua=mailto:clients-dmarc@infiniteroomlabs.com"
```

Nothing else. Verify with `dig +short TXT <client-domain>._report._dmarc.infiniteroomlabs.com @1.1.1.1` -> `"v=DMARC1"`. Reports (zipped XML, daily per receiver) land in the destination mailbox.

## Where this lives in IaC

| Piece | Location |
|-------|----------|
| `*._report._dmarc` + `_dmarc` TXT | `terraform/environments/prod/env.hcl` (`email_dns_records`) via `prod/cloudflare/dns-records` |
| Email Routing (destination address, forward rules incl. `clients-dmarc@`, catch-all) | `terraform/modules/cloudflare-email-routing` via `prod/cloudflare/email-routing` |
| Token permissions | `terraform/environments/global/cloudflare/tokens` |
| Destination address | Bitwarden `email-routing-destination` -> fnox `IRL_EMAIL_ROUTING_DESTINATION` |

Email Routing is Terraform-managed as of 2026-08-22. Dashboard edits will show as drift on the next `terragrunt plan` in `prod/cloudflare/email-routing`.

The destination address resource is import-only: never let a plan create `cloudflare_email_routing_address` (it triggers a verification-email loop).

## Follow-up (not done)

Automated ingestion/parsing of the reports (parsedmarc or similar) is tracked as `R18` in `docs/plans/RESEARCH.md`. Today reports simply accumulate in the mailbox.
