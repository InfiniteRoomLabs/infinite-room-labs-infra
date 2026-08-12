# Runbook: gunio-mcp Incident Response and Operations

Last updated: 2026-08-12

Covers the gunio-mcp deployment: chart/release `irl-gunio-mcp`, namespace
`gunio`, public hostname `gunio.mcp.infiniteroomlabs.com` (MCP endpoint at
`/mcp`). The app binds pod-loopback `127.0.0.1:8000`; a cloudflared sidecar is
the only path in. There is **no in-cluster Service** and no persistence --
the workload is stateless. Secrets come from HashiCorp Vault via External
Secrets Operator (`ClusterSecretStore/vault-irl`), NOT from bw-sync.

Deployment/rollout: `docs/plans/2026-08-12-gunio-mcp-cloudflare-serving.md`.

## Threat Model

The pod holds exactly one high-value secret: a live gun.io session cookie
(`GUNIO_COOKIE`), which is **full control of the operator's gun.io account**
(profile, applications, interviews -- the MCP write gate protects against
tool misuse, not against an attacker holding the cookie itself). Mitigations
that shape the response:

- Unlike JobOps there is **no scraping egress**: NetworkPolicy allows only
  DNS, 443/tcp, and 7844/udp+tcp to public addresses. Bulk exfil to an
  arbitrary host is at least constrained to those ports; egress to
  RFC1918/CGNAT/link-local is denied.
- Writes are dark: `GUNIO_MCP_WRITE_SCOPE` is unset, so even a client that
  passes Access cannot mutate the account through the MCP tools.
- The cookie is a SESSION, revocable server-side at gun.io -- killing the
  session beats any amount of infra containment.

## Containment Sequence

Run in order; 1-2 take under a minute.

1. **Access Deny (cut the public path).** Zero Trust -> Access ->
   Applications -> `gunio MCP` -> Policies -> flip to explicit Deny.
   Confirm: `curl -sS -o /dev/null -w '%{http_code}\n' https://gunio.mcp.infiniteroomlabs.com/mcp` -> 403.
2. **Deny-all egress NetworkPolicy** (stops any in-flight exfil):

   ```bash
   kubectl apply -n gunio -f - <<'EOF'
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: gunio-deny-all-egress
     namespace: gunio
   spec:
     podSelector: {}
     policyTypes:
       - Egress
     egress: []
   EOF
   kubectl scale -n gunio deploy/irl-gunio-mcp --replicas=0
   ```

3. **Kill the session server-side** (the step that actually revokes the
   secret): change the gun.io account password, or log out the harvested
   browser session at gun.io -- either invalidates the `sessionid`. Verify:
   `uv run gunio auth status` (gunio-mcp repo, host-side) reports
   `authenticated: false` for the old cookie.
4. **Rotate the Vault entry** so nothing re-syncs the dead (or stolen)
   value: re-harvest and `vault kv put` per the rotation procedure below.
   If the cloudflared token may have leaked too, refresh it (Zero Trust ->
   Networks -> Tunnels -> irl-gunio -> Refresh token) and
   `vault kv put irl/gunio-mcp/cloudflared token=-`.

Recovery: remove the deny-all policy, scale back to 1, re-enable the Access
policy last.

## Cookie Rotation (the operational tax of phase 1)

The gun.io session cookie expires or gets logged out; when it does the MCP
`auth_status` tool reports `authenticated:false` (this is the observable --
no raw errors). Rotation is host-side harvest -> Vault -> ESO -> rollout:

```bash
# 1. Re-harvest on the machine whose browser is logged in to gun.io:
~/projects/gunio-mcp/scripts/lib/harvest-cookie.sh | vault kv put irl/gunio-mcp/app GUNIO_COOKIE=-

# 2. Wait for the ESO refresh (interval 1h) or force it now:
kubectl -n gunio annotate externalsecret gunio-mcp-secrets force-sync="$(date +%s)" --overwrite

# 3. envFrom is NOT hot-reloaded -- the running pod keeps the old value until:
kubectl -n gunio rollout restart deploy/irl-gunio-mcp
kubectl -n gunio rollout status deploy/irl-gunio-mcp

# 4. Verify through the MCP endpoint (service-token headers) or a client:
#    auth_status -> {"mode":"cookie","authenticated":true,...}
```

Phase 2 (credential login, `GUNIO_USERNAME`/`GUNIO_PASSWORD` at the same
Vault path) deletes this whole section -- the server will establish its own
sessions.

## Sealed-Vault Caveat

Vault re-seals on k3s restart (see `docs/runbooks/vault-sealed.md`). A sealed
Vault blocks ESO refreshes -- `ClusterSecretStore/vault-irl` goes NotReady and
rotations stall -- but ESO **leaves the last-synced Secrets in place**, so
running pods (and pod restarts on an intact node) survive host reboots
without Vault being up. Consequences:

- A sealed Vault is NOT an outage for gunio-mcp; it is a frozen-secrets state.
- Any rotation (cookie, tunnel token, approle secret-id) requires unsealing
  FIRST. `auth_status: false` + sealed Vault means unseal, then rotate.

## Monitoring

| Signal | Alert on | Why |
|---|---|---|
| Pod readiness | `irl-gunio-mcp` 0 ready replicas > 5m | Public route can look fine (Cloudflare answers) while the app is down. |
| Tunnel health | `irl-gunio` connector down (Cloudflare tunnel health) | Tunnel health != app health; alert on both. |
| Session validity | `auth_status.authenticated == false` (scheduled MCP probe or manual) | The cookie expiring is expected lifecycle, not an incident -- catch it before users do. |
| ESO store | `ClusterSecretStore/vault-irl` NotReady > 1h | Sealed Vault or dead approle credential; rotations are silently stalled. |
