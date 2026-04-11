# SOP: Create Authentik OIDC Providers via the ak Django Shell

How to create Authentik OAuth2/OIDC providers and applications without
going through the Authentik admin web UI. This SOP exists because the
homelab Authentik admin login is protected by TOTP -- which is great for
security but rules out browser automation, password-based API auth, and
any flow that needs to bootstrap an OAuth2 provider before a human is
available to type a 6-digit code.

The `ak shell` command runs a Django shell inside the authentik worker
pod. It executes as the authentik service user, has direct ORM access
to the entire Authentik database, and bypasses every flow / policy /
auth check the web UI enforces. It's the canonical way to do declarative
or scripted Authentik provisioning.

Use this SOP when you're:
- Bootstrapping a new OIDC client (paperless, gitea, anything new)
- Rotating client_id/client_secret without losing TOTP-protected access
- Recovering an Authentik deployment after losing TOTP devices
- Inspecting flows, certs, scopes, or applications without UI access

## Prerequisites

- `kubectl` with access to the `irl` namespace
- The Authentik worker pod is healthy (`kubectl get pods -n irl -l app.kubernetes.io/name=authentik,app.kubernetes.io/component=worker`)
- You know the slug of the authorization flow + invalidation flow + signing
  cert you want to attach (run the introspection script below if not)

## Open the shell

`ak shell` is a wrapper around `python manage.py shell`. The command
auto-imports common Authentik models so you don't need to write the
imports for trivial queries.

```bash
AUTHENTIK_WORKER=$(kubectl get pod -n irl \
  -l app.kubernetes.io/name=authentik,app.kubernetes.io/component=worker \
  -o jsonpath='{.items[0].metadata.name}')

# Interactive shell (for exploration)
kubectl exec -n irl ${AUTHENTIK_WORKER} -it -- ak shell

# One-shot script (for automation)
kubectl exec -n irl ${AUTHENTIK_WORKER} -- ak shell -c "<python code>"
```

The startup banner and Authentik bootstrap logs print to stderr; your
script's output goes to stdout. Filter with
`2>&1 | grep -v '"event"' | grep -v '"level"'` if you need clean output.

## Introspect what's available

Before creating a new provider, see what flows, certs, and scopes are
available on this Authentik instance:

```bash
kubectl exec -n irl ${AUTHENTIK_WORKER} -- ak shell -c "
from authentik.flows.models import Flow
from authentik.crypto.models import CertificateKeyPair
from authentik.providers.oauth2.models import ScopeMapping
from authentik.core.models import Application

print('--- Flows ---')
for f in Flow.objects.all():
    print(f' {f.slug:60} {f.designation}')

print()
print('--- Signing certificates ---')
for c in CertificateKeyPair.objects.all():
    print(f' {c.name}')

print()
print('--- OAuth2 scope mappings ---')
for s in ScopeMapping.objects.all():
    print(f' {s.scope_name:25} -> {s.name}')

print()
print('--- Existing applications ---')
for a in Application.objects.all():
    print(f' {a.slug:25} -> {a.name}')
" 2>&1 | grep -v '"event"' | grep -v '"level"' | grep -v '^###'
```

The flow you want for OIDC is usually
`default-provider-authorization-implicit-consent` (no consent screen) or
`default-provider-authorization-explicit-consent` (one-click consent
prompt). The invalidation flow is `default-provider-invalidation-flow`.
The default signing cert is `authentik Self-signed Certificate`.

## Create an OAuth2 provider + application

This is the canonical pattern. Replace the literals with your values:

```bash
APP_SLUG="myservice"
APP_NAME="My Service"
LAUNCH_URL="https://myservice.lab.infiniteroomlabs.cloud"
REDIRECT_URI="https://myservice.lab.infiniteroomlabs.cloud/oauth/callback"

kubectl exec -n irl ${AUTHENTIK_WORKER} -- ak shell -c "
from authentik.flows.models import Flow
from authentik.crypto.models import CertificateKeyPair
from authentik.providers.oauth2.models import (
    OAuth2Provider, ScopeMapping, ClientTypes, RedirectURI, RedirectURIMatchingMode
)
from authentik.core.models import Application

# Idempotent: get-or-create so re-running this script is safe
provider, created = OAuth2Provider.objects.get_or_create(
    name='${APP_SLUG}',
    defaults={
        'authorization_flow': Flow.objects.get(slug='default-provider-authorization-implicit-consent'),
        'invalidation_flow': Flow.objects.get(slug='default-provider-invalidation-flow'),
        'client_type': ClientTypes.CONFIDENTIAL,
        'signing_key': CertificateKeyPair.objects.get(name='authentik Self-signed Certificate'),
    },
)
print(f'PROVIDER_CREATED={created}')

# Set the redirect URI(s) -- always rewrite the full list to ensure idempotency
provider.redirect_uris = [
    RedirectURI(
        matching_mode=RedirectURIMatchingMode.STRICT,
        url='${REDIRECT_URI}',
    ),
]

# Wire the standard OIDC scopes (openid is required, email + profile are
# what most clients ask for)
for scope_name in ['openid', 'email', 'profile']:
    scope = ScopeMapping.objects.get(scope_name=scope_name)
    provider.property_mappings.add(scope)

provider.save()

# Create / update the Application that wraps the provider
app, app_created = Application.objects.get_or_create(
    slug='${APP_SLUG}',
    defaults={
        'name': '${APP_NAME}',
        'provider': provider,
        'meta_launch_url': '${LAUNCH_URL}',
    },
)
if not app_created and app.provider_id != provider.id:
    app.provider = provider
    app.save()
print(f'APP_CREATED={app_created}')

# Print the public credentials. CLIENT_SECRET is intentionally NOT printed
# here -- extract it separately via the next snippet to avoid leaving it
# in the kubectl exec output buffer.
print(f'CLIENT_ID={provider.client_id}')
print(f'CLIENT_SECRET_LENGTH={len(provider.client_secret)}')
print(f'APP_SLUG={app.slug}')
print(f'ISSUER_URL=https://auth.lab.infiniteroomlabs.cloud/application/o/{app.slug}/')
" 2>&1 | grep -E '^(PROVIDER|APP|CLIENT|ISSUER)'
```

## Extract the client_secret without printing it

The Bash exec output is logged in your shell history and the kubectl
audit log. NEVER print the client_secret to stdout in a way that would
land in those logs. Instead, pipe it directly to a temp file with
restrictive permissions:

```bash
mkdir -p /tmp/oidc-stage && chmod 700 /tmp/oidc-stage

kubectl exec -n irl ${AUTHENTIK_WORKER} -- ak shell -c "
from authentik.providers.oauth2.models import OAuth2Provider
p = OAuth2Provider.objects.get(name='${APP_SLUG}')
print('MARKER_SECRET_START')
print(p.client_secret)
print('MARKER_SECRET_END')
" 2>&1 | awk '/MARKER_SECRET_START/{flag=1; next} /MARKER_SECRET_END/{flag=0} flag' \
  > /tmp/oidc-stage/client-secret

# Verify it landed (length only, never the value)
wc -c < /tmp/oidc-stage/client-secret
```

The `MARKER_*` sentinels + `awk` filter exist because Authentik's
bootstrap logs are noisy and arrive interleaved with the print output.
The markers give awk something unique to bracket on.

The client_id is fine to print since it's a public identifier that
appears in URLs and JS bundles. Save both for the next step:

```bash
echo "<CLIENT_ID_FROM_ABOVE>" > /tmp/oidc-stage/client-id
```

## Verify via the OIDC discovery endpoint

Authentik publishes OIDC discovery metadata at a well-known URL based on
the application slug. Hit it from outside the cluster to confirm the
provider is reachable end-to-end:

```bash
curl -sS "https://auth.lab.infiniteroomlabs.cloud/application/o/${APP_SLUG}/.well-known/openid-configuration" \
  | jq '{issuer, authorization_endpoint, token_endpoint, userinfo_endpoint, jwks_uri}'
```

Expected: an `issuer` matching `https://auth.lab.infiniteroomlabs.cloud/application/o/${APP_SLUG}/`
and four endpoint URLs all on the same host. If discovery fails (404,
timeout, JSON parse error), the provider/application wasn't saved
correctly -- re-run the create script and check the `created` flags
in the output.

## Update an existing provider's redirect URI

Common need when you rename a service or change its hostname (e.g., the
paperless `docs.lab` -> `archives.lab` rename):

```bash
NEW_REDIRECT="https://archives.lab.infiniteroomlabs.cloud/accounts/oidc/authentik/login/callback/"

kubectl exec -n irl ${AUTHENTIK_WORKER} -- ak shell -c "
from authentik.providers.oauth2.models import OAuth2Provider, RedirectURI, RedirectURIMatchingMode

p = OAuth2Provider.objects.get(name='paperless')
p.redirect_uris = [
    RedirectURI(
        matching_mode=RedirectURIMatchingMode.STRICT,
        url='${NEW_REDIRECT}',
    ),
]
p.save()
print(f'NEW_REDIRECT_URIS=' + str([r.url for r in p.redirect_uris]))
" 2>&1 | grep NEW_REDIRECT
```

Setting `p.redirect_uris = [...]` replaces the entire list. To append
without replacing, use `p.redirect_uris = list(p.redirect_uris) + [...]`.

## Inspect or clean up

```bash
# List all OAuth2 providers
kubectl exec -n irl ${AUTHENTIK_WORKER} -- ak shell -c "
from authentik.providers.oauth2.models import OAuth2Provider
for p in OAuth2Provider.objects.all():
    print(f'{p.name:25} client_id={p.client_id} type={p.client_type}')
" 2>&1 | grep -v '"event"' | grep -v '"level"' | grep -v '^###'

# Delete an unused provider + its application (be sure!)
kubectl exec -n irl ${AUTHENTIK_WORKER} -- ak shell -c "
from authentik.providers.oauth2.models import OAuth2Provider
from authentik.core.models import Application

Application.objects.filter(slug='myservice').delete()
OAuth2Provider.objects.filter(name='myservice').delete()
print('deleted')
"
```

## Stage credentials into Bitwarden

After extracting the client_id and client_secret to `/tmp/oidc-stage/`,
push them into BW so they can be synced to vault.yml + k8s by bw-sync:

```bash
FOLDER_ID=$(bw list folders 2>/dev/null \
  | jq -r '.[] | select(.name == "IRL/Services/Authentik") | .id')

# client_id (public, but stored as a login item for consistency)
ID_VAL=$(cat /tmp/oidc-stage/client-id)
jq -n --arg name "${APP_SLUG}-oidc-client-id" --arg pw "$ID_VAL" --arg folder "$FOLDER_ID" \
  '{type:1, name:$name, folderId:$folder,
    notes:"Authentik OIDC client ID for the ${APP_SLUG} application.",
    login:{password:$pw, uris:[{"uri":"https://auth.lab.infiniteroomlabs.cloud","match":null}]}}' \
| bw encode | bw create item 2>/dev/null | jq -r '.name'

# client_secret
SECRET_VAL=$(cat /tmp/oidc-stage/client-secret)
jq -n --arg name "${APP_SLUG}-oidc-client-secret" --arg pw "$SECRET_VAL" --arg folder "$FOLDER_ID" \
  '{type:1, name:$name, folderId:$folder,
    notes:"Authentik OIDC client secret for the ${APP_SLUG} application. Paired with ${APP_SLUG}-oidc-client-id.",
    login:{password:$pw, uris:[{"uri":"https://auth.lab.infiniteroomlabs.cloud","match":null}]}}' \
| bw encode | bw create item 2>/dev/null | jq -r '.name'

unset ID_VAL SECRET_VAL
shred -uf /tmp/oidc-stage/* && rmdir /tmp/oidc-stage
bw sync 2>&1 | tail -1
```

Then add the matching entries to `scripts/bw-sync-config.yaml` and run
`./scripts/bw-sync.sh --target both`.

## Why not use the Authentik REST API directly?

The Authentik REST API exists and is well-documented at
`https://auth.lab.infiniteroomlabs.cloud/api/v3/`, but there are three
practical issues with it for this use case:

1. **TOTP**: API tokens are issued per-user. To get an API token for
   the admin user, you must first log in as admin via the web UI --
   which requires TOTP. Catch-22.
2. **Permissions**: outpost service tokens (the kind that homepage uses
   to query authentik for user counts) are scoped read-only. They can't
   create providers.
3. **Discoverability**: the REST API has subtle differences in shape
   from the underlying ORM, especially around `redirect_uris` and
   `property_mappings` which both moved between major versions.

`ak shell` sidesteps all three. Use the REST API for read-only queries
that homepage-style integrations make; use `ak shell` for anything that
provisions, modifies, or deletes provider configuration.

## See Also

- Authentik developer docs: https://goauthentik.io/developer-docs/
- `deploy-paperless-from-scratch.md` step 4 -- a real bringup using this pattern
- `garage-bucket-iam-management.md` -- the symmetric pattern for Garage
