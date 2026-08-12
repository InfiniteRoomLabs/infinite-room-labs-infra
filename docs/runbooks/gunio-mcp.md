# Runbook: gunio-mcp Incident Response and Operations

Last updated: 2026-08-12

Covers the gunio-mcp deployment: chart/release `irl-gunio-mcp`, namespace
`gunio`, public hostname `gunio-mcp.infiniteroomlabs.com` (MCP endpoint at
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
   Confirm: `curl -sS -o /dev/null -w '%{http_code}\n' https://gunio-mcp.infiniteroomlabs.com/mcp` -> 403.
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
no raw errors). Rotation is host-side harvest -> Vault -> ESO -> rollout.

Preconditions on the operator laptop:

- Firefox (or any local browser) has a live gun.io login. The harvest script
  (`scripts/lib/harvest-cookie.sh` in the gunio-mcp repo) reads the browser
  cookie store via a SHA256-pinned rookie-cli and prints
  `sessionid=...; csrftoken=...` to stdout only -- no manual sqlite spelunking,
  no cookie value in argv or shell history.
- Bitwarden unlocked (`bw status` -> unlocked; else `scripts/bw-unlock-prompt.sh`).
- Vault unsealed (`kubectl exec -n irl vault-0 -- vault status`); if sealed,
  see `docs/runbooks/vault-sealed.md` -- unseal keys live in the BW item
  `Vault Unseal Keys + Root Token` (folder `IRL/Services/Vault`).
- PATH gotcha: `~/.local/bin/vault` is claude-code-tools' dotenv tool, which
  shadows the HashiCorp CLI (mise, `aqua:hashicorp/vault`). Prepend the mise
  shims dir as below or every `vault` call hits the wrong binary.

```bash
# 0. Env: real vault CLI, port-forward, root token from BW (never echoed):
export PATH="$HOME/.local/share/mise/shims:$PATH" VAULT_ADDR=http://127.0.0.1:8200
kubectl -n irl port-forward svc/vault 8200:8200 &   # NodePort 30200 is not exposed
export VAULT_TOKEN=$(bw get notes "Vault Unseal Keys + Root Token" | sed -n 's/^Root Token:[[:space:]]*//p')

# 1. Re-harvest on the machine whose browser is logged in to gun.io:
~/projects/infinite-room-labs/gunio-mcp/scripts/lib/harvest-cookie.sh | vault kv put irl/gunio-mcp/app GUNIO_COOKIE=-
# Success check: the command prints the new KV version metadata (no values).

# 2. Wait for the ESO refresh (interval 1h) or force it now:
kubectl -n gunio annotate externalsecret gunio-mcp-secrets force-sync="$(date +%s)" --overwrite

# 3. envFrom is NOT hot-reloaded -- the running pod keeps the old value until:
kubectl -n gunio rollout restart deploy/irl-gunio-mcp
kubectl -n gunio rollout status deploy/irl-gunio-mcp

# 4. Verify through the MCP endpoint (service-token headers) or a client:
#    auth_status -> {"mode":"cookie","authenticated":true,...}

# 5. Hygiene: kill the port-forward and drop the token from the shell:
kill %1; unset VAULT_TOKEN
```

Failure modes: harvest exits 1 -> no logged-in browser session found (log in
to gun.io in Firefox and re-run); `vault kv put` 403s -> wrong/expired token
or sealed Vault; pod restarts but `auth_status` still false -> ESO hasn't
refreshed the Secret yet (re-run step 2, check
`kubectl -n gunio get externalsecret`).

Phase 2 (credential login, `GUNIO_USERNAME`/`GUNIO_PASSWORD` at the same
Vault path) deletes this whole section -- the server will establish its own
sessions.

### Automated weekly refresh (the manual steps above, on a timer)

The manual rotation is also run weekly by a laptop `--user` systemd timer
(`gunio-cookie-refresh.timer`, Mon 09:00), deployed by
`ansible/playbooks/laptop.yml` from `ansible/files/laptop/gunio-cookie-refresh.*`.
It does exactly steps 1-3 above unattended: harvest -> Vault write -> force ESO
sync -> rollout restart. A locked Bitwarden is a clean skip (logged, shipped to
Loki via Alloy); genuine staleness is still caught by the `auth_status` monitor.

It authenticates NOT with the root token but a dedicated **write-only** AppRole
(policy `gunio-cookie-writer`: create/update on `irl/data/gunio-mcp/app` only --
cannot read the cookie back or touch any other path). One-time bootstrap (root
token, same env setup as above):

```bash
vault policy write gunio-cookie-writer ansible/templates/configs/vault/gunio-cookie-writer-policy.hcl
vault write auth/approle/role/gunio-cookie-writer \
  token_policies=gunio-cookie-writer token_ttl=5m token_max_ttl=15m \
  secret_id_ttl=0 secret_id_num_uses=0
vault read -field=role_id auth/approle/role/gunio-cookie-writer/role-id   # -> BW username
vault write -f -field=secret_id auth/approle/role/gunio-cookie-writer/secret-id  # -> BW password
```

Store both in the Bitwarden Login item `vault-gunio-cookie-writer`
(username=role-id, password=secret-id, notes `{"rotation_days": 180}`). The
timer reads them live with `bw get`; nothing is committed. Rotate the secret-id
by re-running the last command and updating the BW item.

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
