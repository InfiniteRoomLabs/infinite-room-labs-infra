# gunio-mcp behind Cloudflare, secrets via HashiCorp Vault (phase 1.5)

**Date:** 2026-08-12
**Status:** DEPLOYED 2026-08-12 -- rollout executed end-to-end (auth_status authenticated:true through the tunnel; smoke suite green; R17 resolved YES)
**Related:** `docs/runbooks/gunio-mcp.md` (incident response + cookie rotation),
`docs/plans/2026-07-10-gitops-cloudflare-tunnel-exposure.md` (parked platform plan;
this deployment reuses its sidecar-per-app JobOps pattern, not the shared connector),
RESEARCH.md R17 (portal origin-Authorization question)

## Objective

Serve the gunio-mcp server (`ghcr.io/infiniteroomlabs/gunio-mcp`, `--serve`
streamable HTTP) publicly at `https://gunio-mcp.infiniteroomlabs.com/mcp`,
fronted by a Cloudflare tunnel + Access exactly like JobOps (cloudflared
sidecar, no in-cluster Service, OTP + Google IdP + non_identity service-token
policy). `{name}-mcp.infiniteroomlabs.com` is the naming convention for future
exposed MCP servers (JobOps' `jops-mcp.` already follows it) -- first-level
labels are covered by the zone's free Universal SSL cert, where a `*.mcp.`
hierarchy would have required paid ACM/Total TLS.

This is also the FIRST RUN of the Vault + ESO secrets pattern: workload
secrets come from the homelab HashiCorp Vault via External Secrets Operator
(AppRole auth), not from the Bitwarden -> bw-sync -> k8s lane. Bitwarden
remains the root of trust for exactly ONE new bootstrap credential (the ESO
AppRole login, item `vault-eso-approle`); everything workload-shaped lives in
Vault under `irl/gunio-mcp/...`.

## Fixed decisions (recorded, do not relitigate)

1. **Vault + ESO with AppRole auth** -- not bw-sync for workload secrets, not
   Vault Agent Injector, not CSI, not Kubernetes auth. AppRole needs no
   Vault-to-kube-API reachability and survives Vault living anywhere.
   Note: the CURRENT Vault is the in-cluster helm release (`vault`, namespace
   `irl`, ClusterIP :8200) -- the legacy Docker Compose stack under
   `ansible/templates/compose/security/` is the deprecated predecessor.
   AppRole keeps us agnostic to which of the two is serving.
2. **Loopback bind**: `GUNIO_MCP_HOST=127.0.0.1`, port 8000. The cloudflared
   sidecar shares the pod netns and forwards to `http://localhost:8000`.
   `GUNIO_MCP_INSECURE` is not needed and must not be set.
3. **`GUNIO_MCP_AUTH_TOKEN` NOT set initially** -- the Cloudflare MCP portal's
   OAuth occupies the Authorization header. Step 7 below verifies whether the
   portal can inject an origin Authorization header; if yes, the operator adds
   the token to Vault path `gunio-mcp/app` and it flows through the chart's
   `dataFrom` extract with zero chart changes. Outcome is recorded HERE and in
   RESEARCH.md R17.
4. **`GUNIO_MCP_WRITE_SCOPE` stays UNSET** -- writes stay disabled until
   decision 3 resolves in favor of an app-level token (without it, anything
   that passes Access could invoke gated writes with `confirm=true`).
5. Hostname `gunio-mcp.infiniteroomlabs.com` (first-level label, rides
   Universal SSL -- an earlier `gunio.mcp.` two-level draft was dropped because
   it required paid ACM); JobOps hostnames do not move.
6. Namespace `gunio`; chart/release `irl-gunio-mcp`; tunnel `irl-gunio`; ESO
   in namespace `external-secrets`.
7. Cookie auth (`GUNIO_COOKIE`) this phase. Phase 2 (credential login) only
   changes which keys live at `irl/gunio-mcp/app` -- nothing here needs
   undoing.

## What the branch delivers

| Piece | Where |
|---|---|
| `irl-gunio-mcp` chart (sidecar, hardened, no Service, ExternalSecrets, tight egress) | helm-charts submodule `charts/irl-gunio-mcp/` |
| Vault bootstrap script (idempotent, operator-run) | `scripts/vault-bootstrap-eso.sh` |
| Least-privilege ESO policy | `ansible/templates/configs/vault/eso-gunio-mcp-policy.hcl` |
| ESO helm release + `ClusterSecretStore/vault-irl` | `ansible/playbooks/helm-deploy.yml` (phase2, tag `external-secrets`), values `ansible/helm/external-secrets/values.yaml` |
| AppRole bootstrap secret mapping (one item, two keys) | `scripts/bw-sync-config.yaml` + `k8s_keys` support in `scripts/bw-sync.sh` |
| Terraform tunnel leaf | `terraform/environments/prod/cloudflare/tunnel-gunio/` |
| CI: conftest render + ROFS ratchet keys; kubeconform picks the chart up automatically | `.github/workflows/conftest.yml`, `policy/readonly-rootfs-ratchet.rego` |
| Smoke tests (skip pre-rollout) | `tests/test_gunio_mcp.py` |
| Runbook | `docs/runbooks/gunio-mcp.md` |

Secret paths in Vault (KV v2 mount `irl/`):

| Path | Keys | Consumer |
|---|---|---|
| `irl/gunio-mcp/app` | `GUNIO_COOKIE` (phase 2: `GUNIO_USERNAME`, `GUNIO_PASSWORD`; maybe `GUNIO_MCP_AUTH_TOKEN`) | k8s Secret `gunio-mcp-secrets` -> envFrom |
| `irl/gunio-mcp/cloudflared` | `token` | k8s Secret `gunio-cloudflared-token` -> --token-file |

No established KV mount predates this: the retired compose-era instructions
suggested `secret/`, a 2026-03 laptop stopgap used `kv/`; neither exists on
the in-cluster Vault (init is manual and no mount was codified). `irl/` is
therefore enabled fresh by the bootstrap script.

---

## ORDERED OPERATOR ROLLOUT

Everything below is operator-run. Steps are in dependency order; do not
reorder. Nothing in this section was executed by the branch author.

### Step A (prereq): release gunio-mcp v0.2.0 and pin digests

The serve mode (`--serve`), bearer-token scaffolding, and `auth_status` tool
live in gunio-mcp's `[Unreleased]`; the deployment needs them in a published
image.

```bash
cd ~/projects/gunio-mcp   # the gunio-mcp repo
# 1. Move the [Unreleased] CHANGELOG.md section to ## [0.2.0] - <date>.
# 2. Bump pyproject.toml version = "0.2.0".
git commit -am "Release v0.2.0" && git tag v0.2.0 && git push origin main v0.2.0
# CI (.github/workflows/publish-docker.yml, v* tags) publishes
# ghcr.io/infiniteroomlabs/gunio-mcp:0.2.0 (mcp target).

# 3. Capture the digests (app + current cloudflared release):
docker buildx imagetools inspect ghcr.io/infiniteroomlabs/gunio-mcp:0.2.0 --format '{{println .Manifest.Digest}}'
docker buildx imagetools inspect cloudflare/cloudflared:latest --format '{{println .Manifest.Digest}}'

# 4. Replace BOTH REPLACE_WITH_DIGEST placeholders in
#    helm-charts/charts/irl-gunio-mcp/values.yaml (image.digest,
#    cloudflared.image.digest). This is a VALUES COMMIT in the helm-charts
#    repo: bump the chart version to 0.1.1 in Chart.yaml, push, then bump the
#    submodule pointer here.
```

### Step B: certificate coverage -- RESOLVED BY NAMING, no action

`gunio-mcp.infiniteroomlabs.com` is a first-level label, covered by the
zone's free Universal SSL wildcard (`*.infiniteroomlabs.com`). No ACM, no
Total TLS, no billing prerequisite. (An earlier draft used the two-level
`gunio.mcp.` and needed paid ACM for edge TLS -- dropped 2026-08-12; future
MCP servers use `{name}-mcp.` first-level names for the same reason.)

Optional post-DNS sanity check (after step 4):

```bash
openssl s_client -connect gunio-mcp.infiniteroomlabs.com:443 -servername gunio-mcp.infiniteroomlabs.com </dev/null 2>/dev/null | openssl x509 -noout -text | grep -A1 "Subject Alternative Name"
# Expect a SAN of *.infiniteroomlabs.com
```

### Step 1: Vault bootstrap (mount, policy, AppRole, Bitwarden item)

```bash
# 1. Unseal if sealed (Vault re-seals on k3s restart -- keys in BW IRL/Services/Vault):
kubectl exec -n irl vault-0 -- vault status | grep Sealed
kubectl exec -n irl vault-0 -- vault operator unseal   # 3x, different keys
# (full procedure: docs/runbooks/vault-sealed.md)

# 2. Reach Vault from the laptop and authenticate. Root token usage is
#    deliberate and interactive; do not persist it anywhere.
kubectl -n irl port-forward svc/vault 8200:8200 &
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=<root token, from the operator-held init material>

# 3. Idempotent bootstrap: irl/ KV v2 mount, eso-gunio-mcp policy, approle
#    role external-secrets. Prints the role-id and the exact follow-ups.
./scripts/vault-bootstrap-eso.sh

# 4. Generate the secret-id (your terminal only; the script never echoes it):
vault write -f -field=secret_id auth/approle/role/external-secrets/secret-id

# 5. Create Bitwarden Login item under the IRL folder tree:
#      name:     vault-eso-approle
#      username: <role-id printed by the script>
#      password: <secret-id from step 4>
#    Add rotation metadata in Notes per the manage-secrets convention:
#      {"rotation_days": 180}

# 6. Seed the app cookie (host-side harvest, stdin -- never argv):
~/projects/gunio-mcp/scripts/lib/harvest-cookie.sh | vault kv put irl/gunio-mcp/app GUNIO_COOKIE=-

# (irl/gunio-mcp/cloudflared token is seeded in step 4 below -- it does not
#  exist until terraform creates the tunnel.)
```

### Step 2: ESO deploy via the ansible lane, then the bootstrap secret

Order matters inside this step: the helm deploy CREATES the
`external-secrets` namespace, so the bw-sync of `vault-eso-approle` can only
land after it. The ClusterSecretStore tolerates the gap (NotReady until the
Secret exists; ESO retries). The gunio chart's ExternalSecrets must NOT be
applied before the store is Ready -- that is why chart install is step 5, and
the helm-deploy task itself retries the store apply until ESO's CRDs are
registered.

```bash
cd ansible/
uv run ansible-playbook playbooks/helm-deploy.yml --tags external-secrets

cd .. && mise run secrets:sync        # lands external-secrets/vault-eso-approle
./scripts/with-secrets.sh ./scripts/bw-sync.sh --verify-k8s   # expect [match] on both keys

# Store must go Ready once the Secret exists:
kubectl get clustersecretstore vault-irl -o wide   # STATUS: Valid, READY: True
```

If READY stays False: `kubectl describe clustersecretstore vault-irl` -- the
usual suspects are a sealed Vault, a wrong secret-id, or the approle role
missing (re-run step 1's script).

### Step 3: sanity -- existing JobOps leaf still a no-op

```bash
cd terraform/environments/prod/cloudflare/tunnel
../../../../../scripts/with-secrets.sh terragrunt plan   # MUST show: No changes.
```

### Step 4: Terraform -- tunnel, DNS, Access; connector token into Vault

```bash
cd terraform/environments/prod/cloudflare/tunnel-gunio
../../../../../scripts/with-secrets.sh terragrunt init
../../../../../scripts/with-secrets.sh terragrunt plan
../../../../../scripts/with-secrets.sh terragrunt apply

# Connector-token bootstrap flip (token never persists in state):
TF_VAR_read_connector_token=true ../../../../../scripts/with-secrets.sh terragrunt apply
../../../../../scripts/with-secrets.sh terragrunt output -raw connector_token \
  | vault kv put irl/gunio-mcp/cloudflared token=-
../../../../../scripts/with-secrets.sh terragrunt apply    # flip back: purges token from state
```

Divergence from the module's storage docs, on purpose: for THIS instance the
token lives in Vault (`irl/gunio-mcp/cloudflared`), not Bitwarden -- gunio-mcp
is the first Vault + ESO workload. JobOps' Bitwarden flow is unchanged.

### Step 5: chart deploy

```bash
# Submodule already bumped by the branch; after the step-A digest commit bump it again.
helm install irl-gunio-mcp helm-charts/charts/irl-gunio-mcp -n gunio --create-namespace

kubectl -n gunio get externalsecret          # both Ready True
kubectl -n gunio get pods -w                 # 2/2 Running
kubectl -n gunio logs deploy/irl-gunio-mcp -c cloudflared | grep -i "registered"   # connector up
```

Cloudflare dashboard cross-check: Zero Trust -> Networks -> Tunnels ->
`irl-gunio` shows the connector HEALTHY.

### Step 6: Cloudflare dashboard -- MCP portal entry

JobOps precedent: portal + MCP server apps are dashboard-managed (their
session duration is set via API PUT -- Access apps reject PATCH with 10405).

1. Zero Trust -> Access -> (AI controls) MCP servers -> Add MCP server:
   URL `https://gunio-mcp.infiniteroomlabs.com/mcp`, name `gunio MCP`.
2. Attach it to the existing IRL MCP portal alongside JobOps.
3. Set its Access app session duration to `730h` (API PUT, same as the
   2026-08-07 JobOps change) so the claude.ai connector is not re-authing daily.

### Step 7: resolve decision 3 (origin Authorization header) -- RECORD OUTCOME

While in the MCP Server config (step 6): check whether the server entry
supports injecting a STATIC ORIGIN Authorization header (a "credentials" /
"authentication" field for the upstream, distinct from the portal's own
OAuth). Then:

- **If yes**: generate a long random token; `vault kv put` it as
  `GUNIO_MCP_AUTH_TOKEN` alongside the cookie at `irl/gunio-mcp/app` (use a
  read-modify-write: `vault kv patch irl/gunio-mcp/app GUNIO_MCP_AUTH_TOKEN=-`);
  configure the portal to send `Authorization: Bearer <token>`; wait for the
  ESO refresh + `kubectl -n gunio rollout restart deploy/irl-gunio-mcp`. From
  then on the app enforces the token itself (defense in depth behind Access),
  and enabling writes (`GUNIO_MCP_WRITE_SCOPE`) becomes a separate,
  deliberate decision.
- **If no**: writes stay disabled (decision 4 stands). Revisit on Cloudflare
  product updates.

Record the outcome here (edit this doc) AND close RESEARCH.md item R17.

**Outcome (2026-08-12 rollout):** YES -- the MCP Server entry's "Custom headers"
authentication type injects arbitrary static headers on every upstream request
(explicitly including `Authorization: Bearer`); multiple header rows supported.
We use it for the CF-Access service-token pair (`CF-Access-Client-Id`/`-Secret`).
Adding `GUNIO_MCP_AUTH_TOKEN` as a third header is therefore available whenever
we choose to enable it; writes remain a separate, deliberate decision. R17 closed.

### Step 8: verification

```bash
# 1. Unauthenticated request is Access-gated (302 to cloudflareaccess.com login or 403):
curl -sS -o /dev/null -D - https://gunio-mcp.infiniteroomlabs.com/mcp | head -5

# 2. Service-token request gets an MCP protocol response (initialize round-trip):
cd terraform/environments/prod/cloudflare/tunnel-gunio
CF_ID=$(../../../../../scripts/with-secrets.sh terragrunt output -raw mcp_service_token_client_id)
CF_SECRET=$(../../../../../scripts/with-secrets.sh terragrunt output -raw mcp_service_token_client_secret)
curl -sS https://gunio-mcp.infiniteroomlabs.com/mcp \
  -H "CF-Access-Client-Id: $CF_ID" -H "CF-Access-Client-Secret: $CF_SECRET" \
  -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"rollout-check","version":"0"}}}'
# Expect a JSON-RPC result naming the gunio-mcp server -- NOT a Cloudflare block page.

# 3. End-to-end through a real client (claude.ai connector via the portal, or
#    any MCP client with the service-token headers): call auth_status; expect
#    {"mode":"cookie","authenticated":true,"checked_at":...}.

# 4. Smoke suite now exercises the live paths instead of skipping:
cd tests && uv run pytest test_gunio_mcp.py -v
```

### Rollback (fast -> full)

1. **Access Deny (fast, reversible):** Zero Trust -> Access -> Applications
   -> `gunio MCP` -> Policies -> add/flip to an explicit Deny. Public path is
   dead; tunnel stays for forensics.
2. **Uninstall (clean):** `helm uninstall irl-gunio-mcp -n gunio` -- removes
   the pod and its ExternalSecrets/Secrets. Vault data is untouched.
3. **Destroy the leaf (full):** `terragrunt destroy` in
   `terraform/environments/prod/cloudflare/tunnel-gunio/` -- removes tunnel,
   DNS record, Access app, policies, service token. JobOps' leaf is a
   separate workspace and is untouched.

---

## Ordering hazards (why the steps are in this order)

- **ESO CRDs vs ClusterSecretStore**: the store apply retries in the ansible
  task (up to ~2.5 min) because the CRDs register asynchronously on first
  install. Charts with ExternalSecrets (gunio) install only after the store
  is Ready.
- **bw-sync vs external-secrets namespace**: bw-sync `kubectl apply` cannot
  create namespaces; the ESO helm release creates it. Sync AFTER the deploy.
- **Digest placeholders**: the chart renders with `REPLACE_WITH_DIGEST` on
  purpose (JobOps precedent, CI renders fine) but the pod cannot pull until
  step A's values commit replaces them.
- **envFrom rotation**: ESO refreshing a Secret never restarts the pod --
  every rotation ends with `kubectl -n gunio rollout restart` (see runbook).
