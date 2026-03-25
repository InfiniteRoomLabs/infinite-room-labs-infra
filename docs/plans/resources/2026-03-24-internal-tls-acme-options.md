# Internal TLS via ACME: Options Research

**Date:** 2026-03-24
**Status:** Complete
**Context:** Replace `tls internal` (Caddy self-signed CA, `verify=False` everywhere) with proper
ACME-issued certificates for all services behind `*.lab.infiniteroomlabs.cloud` and
`*.internal.lab.infiniteroomlabs.cloud`.

---

## Infrastructure Snapshot

Before diving into options, the current state that constrains every decision:

| Component | Current state |
|-----------|--------------|
| Caddy version | v2.11.2, installed via APT (standard binary, no DNS plugin) |
| Vault version | **1.17** (running), chart 0.32.0 (latest appVersion 1.21.2) |
| Public DNS | Cloudflare manages `infiniteroomlabs.cloud` |
| Internal DNS | CoreDNS in k3s, served via Tailscale Split DNS |
| Access boundary | All services reachable only over Tailscale |
| Test suite | `session.verify = False` in `tests/conftest.py`, `test_tls_internal_ca` explicitly validates self-signed behavior |

The Caddyfile template at `ansible/templates/Caddyfile.j2` generates one site block per service with `tls internal` on every block. There is no per-site CA differentiation today.

---

## Approach 1: Vault PKI Secrets Engine as ACME CA

### Feature maturity

Vault added ACME protocol support to the PKI secrets engine in **version 1.14** (June 2023). The feature is available in Community Edition (not Enterprise-only). As of 1.21.2 (current chart appVersion), it is stable and production-ready. The running instance is **1.17**, which fully supports ACME.

The official HashiCorp tutorial (`pki-acme-caddy`) demonstrates exactly this stack: Vault PKI as ACME CA + Caddy as ACME client. This is a first-class, documented pattern.

### How it works

Vault PKI operates a two-tier CA hierarchy. Caddy speaks standard RFC 8555 ACME to an endpoint Vault exposes at:

```
https://vault.lab.infiniteroomlabs.cloud/v1/pki_int/acme/directory
```

Caddy proves domain control via the `http-01` challenge (Vault sends an HTTP GET to the domain being certified) or `tls-alpn-01`. Since Vault is inside the same Tailscale network as Caddy, it can reach `http://localhost:{nodePort}/.well-known/acme-challenge/...` by going through Caddy itself. This is how the tutorial does it: both endpoints share a Docker network.

**Critical issue for this environment:** Vault must be able to perform the ACME challenge verification against the domain being certified. With `http-01`, Vault must reach `http://home.lab.infiniteroomlabs.cloud/.well-known/acme-challenge/TOKEN`. Since Tailscale Split DNS routes those names to the homelab Tailscale IP, and Vault runs as a k3s pod, the pod would need to resolve those names and reach Caddy on port 80. k3s pods do not automatically use Tailscale Split DNS. This is a solvable but meaningful operational hurdle - the CoreDNS ConfigMap would need a forwarder for `lab.infiniteroomlabs.cloud` that points to the internal CoreDNS, or a `hostAliases` entry in the Vault pod, or Vault configured to use Tailscale's DNS.

An alternative is `tls-alpn-01`, which validates over port 443 - same reachability problem applies.

The cleanest path is actually `role:sign-verbatim` with domain validation disabled for internal hosts, or configure the challenge to hit a known IP. This requires some care.

### Configuration: Vault PKI setup

After Vault is initialized and unsealed, run via `vault` CLI or API:

```bash
# 1. Enable root CA mount
vault secrets enable pki
vault secrets tune -max-lease-ttl=87600h pki

# 2. Generate root CA (10-year lifetime)
vault write -field=certificate pki/root/generate/internal \
  common_name="IRL Root CA" \
  issuer_name="irl-root-2026" \
  ttl=87600h > /tmp/irl-root-ca.crt

# 3. Enable intermediate CA mount
vault secrets enable -path=pki_int pki
vault secrets tune -max-lease-ttl=43800h pki_int

# 4. Generate intermediate CSR
vault write -format=json pki_int/intermediate/generate/internal \
  common_name="IRL Intermediate CA" \
  issuer_name="irl-intermediate" \
  | jq -r '.data.csr' > /tmp/irl-intermediate.csr

# 5. Sign intermediate with root
vault write -format=json pki/root/sign-intermediate \
  issuer_ref="irl-root-2026" \
  csr=@/tmp/irl-intermediate.csr \
  format=pem_bundle ttl="43800h" \
  | jq -r '.data.certificate' > /tmp/irl-intermediate.pem

# 6. Import signed intermediate
vault write pki_int/intermediate/set-signed certificate=@/tmp/irl-intermediate.pem

# 7. Set cluster path (REQUIRED for ACME - this is the ACME base URL)
vault write pki_int/config/cluster \
  path=https://vault.lab.infiniteroomlabs.cloud/v1/pki_int \
  aia_path=https://vault.lab.infiniteroomlabs.cloud/v1/pki_int

# 8. Set AIA (CRL, OCSP, issuer) URLs
vault write pki_int/config/urls \
  issuing_certificates="{{cluster_aia_path}}/issuer/{{issuer_id}}/der" \
  crl_distribution_points="{{cluster_aia_path}}/issuer/{{issuer_id}}/crl/der" \
  ocsp_servers="{{cluster_path}}/ocsp" \
  enable_templating=true

# 9. Create a role restricting issuance to the two zones
vault write pki_int/roles/irl-homelab \
  issuer_ref="$(vault read -field=default pki_int/config/issuers)" \
  allowed_domains="lab.infiniteroomlabs.cloud,internal.lab.infiniteroomlabs.cloud" \
  allow_subdomains=true \
  max_ttl="720h" \
  no_store=false

# 10. Tune PKI mount for ACME required response headers
vault secrets tune \
  -passthrough-request-headers=If-Modified-Since \
  -allowed-response-headers=Last-Modified \
  -allowed-response-headers=Location \
  -allowed-response-headers=Replay-Nonce \
  -allowed-response-headers=Link \
  pki_int

# 11. Enable ACME on the intermediate CA
vault write pki_int/config/acme \
  enabled=true \
  default_directory_policy="role:irl-homelab"
```

### Configuration: Caddy

The global `acme_ca` option in the Caddyfile replaces the per-site `tls internal`:

```
{
    admin localhost:2019
    acme_ca https://vault.lab.infiniteroomlabs.cloud/v1/pki_int/acme/directory
    acme_ca_root /etc/caddy/irl-root-ca.crt
}

git.lab.infiniteroomlabs.cloud {
    reverse_proxy localhost:30300
    log { ... }
}

metrics.internal.lab.infiniteroomlabs.cloud {
    reverse_proxy localhost:30090
    log { ... }
}
```

Note: `tls internal` is simply removed. Caddy's automatic HTTPS will now use the ACME CA specified globally. The `acme_ca_root` line points to the root CA PEM file so Caddy can trust Vault's TLS certificate during the ACME exchange (since Vault's own TLS uses Caddy's internal CA today - this is a chicken-and-egg issue discussed in failure modes below).

For **per-site CA override** (different ACME CA for a specific block):

```
some.domain.com {
    tls {
        ca https://other-ca/directory
        ca_root /path/to/root.pem
    }
    ...
}
```

Caddy fully supports per-site ACME CA override via the `tls { ca ... }` subdirective.

### Certificate lifecycle

- Vault issues certs with the `max_ttl` set on the role (720h = 30 days recommended for internal CA)
- Caddy automatically renews at ~2/3 of lifetime (configurable with `renewal_window_ratio`)
- Vault stores issued certificates in its storage backend (already backed by ZFS `local-path` PVC)
- Revocation via `vault revoke pki_int/cert/<serial>` or CRL served at the AIA URL
- Vault's ACME implementation handles account registration, nonce management, and challenge response automatically

### Root CA trust distribution

This is the most operationally significant step:

**Laptop (Ubuntu 24.04):** Add the root CA to the system trust store:
```bash
sudo cp irl-root-ca.crt /usr/local/share/ca-certificates/irl-root-ca.crt
sudo update-ca-certificates
```
After this, `session.verify = True` works in the test suite, browsers trust the cert, curl works without `-k`.

**k3s pods that need to call internal services:** Mount the root CA as a ConfigMap and add it to each container's trust store, or use a cluster-wide trust bundle (cert-manager has a `ClusterTrustBundle` resource for this in newer Kubernetes).

**Other Tailscale nodes** (DO k3s agent, future nodes): Same APT approach, or deploy the CA cert via Ansible.

### Failure modes

1. **Vault sealed = no cert renewals.** This is the most serious operational risk. Vault re-seals on restart and requires 3-of-5 manual unseal keys. If Caddy's cert expires while Vault is sealed, all services go down. Mitigation: monitor cert expiry separately (Prometheus has `ssl_earliest_cert_expiry` via the blackbox exporter), set max_ttl to 30 days and alert at 7 days remaining.

2. **Chicken-and-egg TLS bootstrap.** Vault itself is currently served over Caddy with `tls internal`. If Caddy tries to get its cert from Vault over HTTPS, but Vault's own HTTPS cert is untrusted, the ACME exchange fails. Solution: during migration, Vault must temporarily use a cert that Caddy trusts, or Caddy must be told to trust Vault's current self-signed cert via `acme_ca_root`. The cleanest migration path is: (a) configure Caddy to trust the new Vault PKI root, (b) have Vault serve its own endpoint with a cert from a different source initially (or use HTTP for the ACME endpoint within the trusted network - acceptable for an internal CA). The tutorial uses HTTP for the Vault ACME endpoint precisely to avoid this.

3. **ACME challenge reachability.** If Vault cannot reach `http://git.lab.infiniteroomlabs.cloud/.well-known/acme-challenge/TOKEN`, cert issuance fails. Needs careful DNS and routing validation before cutover.

4. **Vault upgrade path.** Running 1.17, chart supports 1.21.2. The ACME feature is stable across this range. Upgrading Vault is recommended for security patches but not required for ACME functionality.

### Multi-Caddy architecture

There are two Caddy instances: homelab (bare-metal) and DO (planned for public services). Each would independently register an ACME account with Vault and obtain their own certs. Vault's ACME supports multiple concurrent clients. The DO Caddy must be able to reach Vault over Tailscale for ACME exchanges - which it can, since both are on the same tailnet. This works cleanly.

### Impact on test suite

Remove `session.verify = False` from `conftest.py` once the root CA is in the system trust store on the machine running the tests. The `test_tls_internal_ca` test needs to be rewritten - instead of verifying that certs are self-signed, it should verify that certs are issued by the IRL CA (check issuer CN) or simply verify that `verify=True` succeeds.

### Operational complexity rating: Medium-High

The setup is well-documented and Vault is already deployed. The main complexity is the bootstrap sequence, the Vault sealing risk, and the CA trust distribution. Ongoing operations are low-toil once configured (Caddy auto-renews, Vault auto-issues).

---

## Approach 2: Let's Encrypt with DNS-01 Challenge via Cloudflare

### How it works

DNS-01 challenge proves domain ownership by having the ACME client create a DNS TXT record at `_acme-challenge.<domain>`. Let's Encrypt verifies it by querying public DNS. Crucially, the service itself never needs to be publicly reachable - only the DNS zone needs to be.

Cloudflare manages `infiniteroomlabs.cloud`. The `caddy-dns/cloudflare` plugin for Caddy automates TXT record creation via the Cloudflare API during each cert issuance or renewal.

This issues **publicly trusted certificates** - the same kind your browser trusts for any public website. No CA distribution required. `verify=False` goes away completely and immediately.

### The DNS plugin requirement

The standard Caddy binary installed via APT does **not** include the Cloudflare DNS plugin. Caddy's plugin system requires a custom binary build. The `caddy-dns/cloudflare` plugin (`github.com/caddy-dns/cloudflare`) is maintained by the community and actively developed (858 stars, recent commits as of March 2026).

Building a custom Caddy binary using `xcaddy`:

```bash
xcaddy build \
  --with github.com/caddy-dns/cloudflare
```

Or using the Docker builder approach (better for reproducibility):

```dockerfile
FROM caddy:2.11.2-builder AS builder
RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare

FROM caddy:2.11.2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
```

The Ansible caddy playbook currently installs via APT. Switching to a custom binary means either:
- Building the binary in CI and deploying it via Ansible (recommended)
- Switching to the Caddy Docker image (does not fit current bare-metal deployment model)
- Using the APT package support files with a custom binary swap

The caddy.yml playbook would need significant modification: add a build step, deploy binary, replace APT-managed binary. APT would then fight with the custom binary on system updates.

### Configuration: Caddyfile

```
{
    admin localhost:2019
    acme_dns cloudflare {env.CF_DNS_API_TOKEN}
}

git.lab.infiniteroomlabs.cloud {
    reverse_proxy localhost:30300
    log { ... }
}

metrics.internal.lab.infiniteroomlabs.cloud {
    reverse_proxy localhost:30090
    log { ... }
}
```

The `acme_dns cloudflare` global option configures DNS-01 for all ACME transactions. The Cloudflare API token needs `Zone.Zone:Read` and `Zone.DNS:Edit` permissions for `infiniteroomlabs.cloud`.

For per-site DNS provider override (different token per block):
```
some.domain.com {
    tls {
        dns cloudflare {env.CF_API_TOKEN}
        resolvers 1.1.1.1
    }
    ...
}
```

The `resolvers 1.1.1.1` line is the fix for the propagation check failure documented in the plugin's README: since the homelab uses internal DNS as its default resolver (Tailscale Split DNS), Caddy's DNS challenge verification loop might query the internal CoreDNS instead of Cloudflare's authoritative servers, causing propagation timeouts. Setting `resolvers 1.1.1.1` forces the check to use public resolvers.

### Wildcard certificates

Let's Encrypt supports wildcard certificates (`*.lab.infiniteroomlabs.cloud`) exclusively via DNS-01. A single wildcard cert covers all services on a zone, which simplifies management. However, Caddy's automatic HTTPS typically issues per-hostname certs by default. To use a wildcard, you would need to either:
- Configure Caddy with explicit cert management for the wildcard domains
- Accept per-hostname certs (simpler, slightly more Let's Encrypt API calls)

For this infrastructure with ~10 services, per-hostname certs are fine and well within rate limits.

### Rate limits

Let's Encrypt rate limits (as of March 2026):
- 50 certificates per registered domain per 7 days (applies to `infiniteroomlabs.cloud` as the registered domain)
- 5 certificates for the same exact set of identifiers per 7 days
- 300 new orders per account per 3 hours

With ~10-12 services, initial issuance consumes 10-12 of the 50/week limit. Renewals of existing certs do not count against limits (they are recognized as renewals). This is not a concern in practice for a homelab.

### CT log implications

Every certificate Let's Encrypt issues is logged to Certificate Transparency logs, which are public and queryable by anyone (via crt.sh, for example). This means:
- `git.lab.infiniteroomlabs.cloud`
- `metrics.internal.lab.infiniteroomlabs.cloud`
- `storage.internal.lab.infiniteroomlabs.cloud`
- `context.internal.lab.infiniteroomlabs.cloud`

...would all appear in public CT logs. For a homelab with no sensitive service names, this is a mild disclosure. The services themselves are unreachable from the internet (Tailscale-only), but their existence as DNS names is logged. Threat model: low for most homelabs. If subdomain names must be kept private (e.g., `passwords.internal.lab.infiniteroomlabs.cloud`), DNS-01 + LE is not appropriate.

For this infrastructure with names like `git`, `grafana`, `metrics`, `storage` - these are completely generic. The disclosure is not meaningful.

Wildcard certs reduce CT log entries: a single `*.lab.infiniteroomlabs.cloud` cert reveals less than 8 individual subdomain certs.

### Certificate lifecycle

Let's Encrypt certs are valid for 90 days. Caddy auto-renews at ~30 days remaining (configurable). The Cloudflare DNS plugin handles challenge creation and cleanup automatically. No human intervention required after initial setup.

Failure mode: if the Cloudflare API token expires or is revoked, cert renewal fails silently until expiry. Set a Prometheus alert on cert expiry.

### Multi-Caddy architecture

Both the homelab Caddy and the DO Caddy can use DNS-01 with the same Cloudflare token. Since the DNS zone is shared, either instance can create `_acme-challenge` TXT records for any subdomain. Both instances would independently get their own certs. This works cleanly - no coordination needed between the two Caddy instances.

### Impact on test suite

Remove `session.verify = False` from `conftest.py` - the certs are publicly trusted. `test_tls_internal_ca` test needs to be inverted: it should now assert that `verify=True` succeeds (i.e., the cert is properly trusted). The `urllib3.disable_warnings(InsecureRequestWarning)` line also goes away.

### Operational complexity rating: Low-Medium

The main complexity is building and deploying a custom Caddy binary. Once that is done, ongoing operations are fully automated. No dependency on Vault availability. No CA trust distribution. Public trust by default.

The Ansible deployment changes to Caddy are non-trivial: binary management, systemd service updates, APT conflict avoidance.

---

## Approach 3: step-ca (Smallstep) as Internal ACME CA

### What it is

Smallstep's `step-ca` is purpose-built as a private ACME CA, originally designed for machine identity in Kubernetes. It supports ACME, OIDC, JWK, SSHPOP, and other provisioners. The `autocert` add-on specifically targets Kubernetes pod cert injection via admission webhooks.

Smallstep publishes a Helm chart at `https://smallstep.github.io/helm-charts/`.

### step-ca vs Vault PKI for this use case

| Factor | step-ca | Vault PKI |
|--------|---------|-----------|
| Purpose-built ACME CA | Yes | Partial (ACME added in 1.14) |
| Already deployed | No | Yes (1.17 running) |
| Kubernetes Helm chart | Yes | Yes (already used) |
| Docs quality for ACME+Caddy | Good (tutorials exist) | Excellent (official tutorial) |
| Storage backend | Built-in (file, DB) | Vault's existing storage |
| HA / clustering | Requires separate setup | Uses Vault's existing HA |
| Sealing risk | No (no sealing concept) | Yes (manual unseal) |
| Operational load | New service to manage | Uses existing service |

For this environment, step-ca adds a new service without meaningfully improving on what Vault PKI already provides. Vault 1.17 fully supports ACME. step-ca's main advantages (no sealing, simpler ACME-first UX) do not outweigh the cost of deploying another CA when Vault is already present and functional.

The `autocert` Kubernetes add-on injects certs into pods as sidecars - this is useful for service mesh / mTLS between pods, but does not address the Caddy reverse proxy use case (which needs Caddy to present certs to external clients).

### Conclusion on step-ca

Do not deploy step-ca. Vault PKI is already present and covers the same functionality. step-ca is the right choice when starting fresh without Vault.

---

## Additional Research: Caddy acme_ca Directive

From the Caddy documentation:

- `acme_ca <url>` in the global options block sets the ACME directory URL for all sites
- `tls { ca <url> }` in a site block overrides the CA for that specific site
- Both directives accept any RFC 8555 ACME directory URL, including Vault's endpoint
- `acme_ca_root <pem_file>` specifies a PEM file for trusting the CA's TLS certificate (needed when the ACME CA itself uses a cert not in the system trust store)
- `acme_dns <provider> <params>` enables DNS-01 challenge globally
- Multiple `cert_issuer` directives can be stacked: if the first fails, the next is tried

Caddy stores obtained certificates in its data directory (`/var/lib/caddy`). The automatic HTTPS feature manages the complete lifecycle: ACME account creation, certificate ordering, challenge response, renewal scheduling. Caddy logs cert events at INFO level.

**Per-site CA override confirmed working:** Yes, Caddy can use Vault PKI for internal services and Let's Encrypt for public-facing ones within the same Caddyfile, via per-block `tls { ca ... }` overrides.

---

## Additional Research: Tailscale cert

`tailscale cert` issues Let's Encrypt certs for nodes in your tailnet using the Tailscale-managed `*.ts.net` or `*.tail-NNNN.ts.net` domain. Tailscale handles the DNS-01 challenge on your behalf via its own internal DNS infrastructure.

**Critical limitation:** This only works for `*.ts.net` domain names assigned by Tailscale (e.g., `homelab.tail1234.ts.net`). It does not work for custom domains like `*.lab.infiniteroomlabs.cloud`. This infrastructure uses custom domains for all services, so `tailscale cert` is not applicable here.

`tailscale cert` would be useful if services were accessed via MagicDNS names (`homelab.yak-bebop.ts.net`) rather than the custom `*.lab.infiniteroomlabs.cloud` zone. Given the CT log privacy note: Tailscale itself warns that machine names appear in CT logs and recommends reviewing machine names before enabling HTTPS.

---

## Recommendation Summary

**Primary recommendation: Approach 2 (Let's Encrypt + DNS-01 + Cloudflare plugin)**

Rationale:
1. Publicly trusted certs with zero CA distribution work. The laptop, the test runner, browsers, curl - all work immediately without any trust store changes.
2. No dependency on Vault availability. Vault sealing does not affect cert renewals.
3. No chicken-and-egg bootstrap problem.
4. Let's Encrypt and the Cloudflare DNS plugin are both extremely mature and well-tested at scale.
5. The CT log disclosure is not a meaningful risk for this service set.
6. Operational path to Remove `verify=False` is one config change + custom binary deploy.

The only meaningful downside is requiring a custom Caddy binary. This is a one-time build and deploy, after which updates follow the same pattern.

**Secondary recommendation if DNS-01 is ruled out: Approach 1 (Vault PKI ACME)**

Vault 1.17 supports ACME fully. The official tutorial covers exactly this stack. The main operational requirements are:
- Solving the ACME challenge reachability problem (Vault must reach Caddy's domains)
- Managing the Vault sealing risk for cert renewals
- Distributing the root CA to all clients

**Do not deploy step-ca** - Vault PKI covers the same need.

---

## Migration Path (Approach 2)

1. Build custom Caddy binary with `caddy-dns/cloudflare` plugin (xcaddy, pin to Caddy 2.11.2)
2. Create Cloudflare API token with `Zone.Zone:Read` + `Zone.DNS:Edit` for `infiniteroomlabs.cloud`
3. Store token in Bitwarden, sync to Ansible Vault via `bw-sync.sh`
4. Update Ansible caddy playbook to deploy custom binary and add `CF_DNS_API_TOKEN` env var to Caddy's systemd unit
5. Update `Caddyfile.j2`: remove `tls internal` from all blocks, add global `acme_dns cloudflare {env.CF_DNS_API_TOKEN}` with `resolvers 1.1.1.1`
6. On deploy, Caddy will obtain certs from Let's Encrypt via DNS-01 - this happens automatically on first reload
7. Update `tests/conftest.py`: remove `session.verify = False`, remove `disable_warnings`, rewrite `test_tls_internal_ca` to assert `verify=True` succeeds

### Migration Path (Approach 1, alternative)

1. Configure Vault PKI (root + intermediate CA, role, ACME enabled) - commands above
2. Export root CA PEM from Vault, install in system trust store on homelab and laptop
3. Add CA cert to Ansible managed files, deploy via `update-ca-certificates`
4. Update `Caddyfile.j2`: remove `tls internal`, add global `acme_ca` pointing to Vault ACME directory and `acme_ca_root` pointing to root CA PEM
5. Validate ACME challenge reachability: Vault pod must be able to HTTP GET to Caddy endpoints
6. Update test suite same as Approach 2

---

## Open Questions

1. **Custom binary deploy process:** How should the Caddy binary be built and versioned? Options: build in CI (Gitea Actions), build in an Ansible task on the homelab, or commit pre-built binary to infra repo. CI is cleanest but requires a runner.

2. **Vault sealing automation:** If Approach 1 is chosen, should unseal be automated via a KMS (e.g., AWS KMS free tier, or a Vault Transit auto-unseal using a second Vault instance)? This is the primary operational risk.

3. **Wildcard vs per-hostname certs:** For Approach 2, a single `*.lab.infiniteroomlabs.cloud` wildcard is cleaner but requires DNS-01 (already required) and a specific Caddy configuration. Per-hostname certs are simpler to configure but slightly increase LE API traffic.

4. **DO Caddy deployment:** The DO Caddy instance (for public services) is not yet described in this research. It would follow the same approach as homelab Caddy once deployed.
