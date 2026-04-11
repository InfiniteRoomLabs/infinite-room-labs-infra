# SOP: Deploy Paperless-ngx From Scratch

End-to-end deployment of Paperless-ngx on a clean homelab cluster. Use
when:

- Bringing up a new k3s cluster (DR scenario)
- Onboarding a fresh environment that mirrors the homelab
- Reproducing the bringup as a verification exercise

This is the canonical "everything that has to happen, in order" reference.
The original bringup hit several non-obvious issues during execution
(see Gotchas at the end) -- this SOP captures the corrected sequence.

If you only need to redeploy after a code change, use
`ansible-playbook playbooks/helm-deploy.yml --tags paperless` and skip
to step 8.

## Architecture summary

Paperless-ngx runs as `irl-paperless` (a wrapper chart around
gabe565/paperless-ngx), with:

- **Database**: shared CNPG `irl-postgres` cluster, dedicated `paperless`
  DB and role provisioned by the Phase 2 postgres bootstrap
- **Cache + Celery broker**: shared `irl-valkey` (Redis-compatible), DB index 3
- **OCR sidecars**: dedicated Tika + Gotenberg deployments (separate pods,
  not in the main paperless pod)
- **Auth**: Authentik OIDC provider via django-allauth
- **Storage**: 4 hostPath PVs -- consume (under nfs-share), media + data
  (dedicated ZFS datasets), export (local-path, ephemeral)
- **Backup**: nightly CronJob runs `document_exporter`, uploads to
  Garage S3 `paperless-backups` bucket
- **Ingress**: Traefik IngressRoute at `archives.lab.infiniteroomlabs.cloud`
- **External entry**: SMB share via the host samba service +
  existing NFS share, both backed by `/media/root/storage1/nfs-share/paperless-consume/`

## Prerequisites

- The homelab cluster is up: `kubectl get nodes` shows the homelab Ready
- CNPG operator + irl-postgres are deployed and healthy
- irl-valkey is deployed
- Garage S3 is deployed and reachable at `https://s3.internal.lab.infiniteroomlabs.cloud`
- Authentik is deployed at `https://auth.lab.infiniteroomlabs.cloud`
- The hand-managed NFS share at `/media/root/storage1/nfs-share/` exists
- bw-sync.sh is configured and working
- The Bitwarden vault is unlocked (`bw status`)

## Step 1: Create Bitwarden items (8 total)

Three are auto-generatable up front; five depend on Authentik + Garage
setup that happens later in this SOP. Create the first three now:

```bash
FOLDER_ID=$(bw list folders 2>/dev/null \
  | jq -r '.[] | select(.name == "IRL/Services/Paperless") | .id')

# If the folder doesn't exist, create it first:
# echo '{"name":"IRL/Services/Paperless"}' | bw encode | bw create folder

# pg-paperless: Postgres password for the paperless CNPG role
PG_PW=$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)
jq -n --arg name "pg-paperless" --arg pw "$PG_PW" --arg folder "$FOLDER_ID" \
  '{type:1, name:$name, folderId:$folder,
    notes:"Postgres password for the paperless CNPG role.",
    login:{password:$pw, uris:[]}}' \
| bw encode | bw create item 2>/dev/null | jq -r '.name'
unset PG_PW

# paperless-secret-key: Django SECRET_KEY (50+ chars)
SECRET_KEY=$(python3 -c "import secrets, string; print(''.join(secrets.choice(string.ascii_letters + string.digits + '!@#%^&*(-_=+)') for _ in range(64)))")
jq -n --arg name "paperless-secret-key" --arg pw "$SECRET_KEY" --arg folder "$FOLDER_ID" \
  '{type:1, name:$name, folderId:$folder,
    notes:"Django SECRET_KEY for paperless-ngx. Rotating this invalidates encrypted fields and existing sessions.",
    login:{password:$pw, uris:[]}}' \
| bw encode | bw create item 2>/dev/null | jq -r '.name'
unset SECRET_KEY

# paperless-admin: Bootstrap admin password
ADMIN_PW=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)
jq -n --arg name "paperless-admin" --arg pw "$ADMIN_PW" --arg folder "$FOLDER_ID" \
  '{type:1, name:$name, folderId:$folder,
    notes:"Bootstrap admin password for paperless-ngx. Username: admin. Used only for initial login.",
    login:{username:"admin", password:$pw, uris:[{"uri":"https://archives.lab.infiniteroomlabs.cloud","match":null}]}}' \
| bw encode | bw create item 2>/dev/null | jq -r '.name'
unset ADMIN_PW

bw sync 2>&1 | tail -1
```

Items 4-8 (Authentik OIDC + Garage S3) are created in steps 4 and 5 below.

## Step 2: Add bw-sync mappings

Append to `scripts/bw-sync-config.yaml` under the paperless section:

```yaml
  - bw_item: "pg-paperless"
    ansible_var: "vault_pg_passwords.paperless"
    k8s_secret: "postgres-paperless"
    k8s_key: "password"

  - bw_item: "paperless-secret-key"
    ansible_var: "vault_paperless_secret_key"
    k8s_secret: "paperless-secrets"
    k8s_key: "secret-key"

  - bw_item: "paperless-admin"
    ansible_var: "vault_paperless_admin_password"
    k8s_secret: "paperless-secrets"
    k8s_key: "admin-password"
```

The remaining 5 entries (paperless-oidc-client-id, -client-secret,
-socialaccount-providers, -backup-s3-access-key, -backup-s3-secret-key)
get appended in steps 4 and 5.

## Step 3: Sync to vault

```bash
./scripts/bw-sync.sh --dry-run --target ansible
./scripts/bw-sync.sh --target ansible
```

Expected: 3 updated, no errors. The k8s sync target can wait until all
8 secrets are ready in step 6.

## Step 4: Create the Authentik OIDC provider

Authentik admin login is TOTP-protected, so use the `ak shell` (Django
shell) inside the worker pod -- bypasses TOTP because it runs server-side
as the authentik service.

```bash
AUTHENTIK_WORKER=$(kubectl get pod -n irl -l app.kubernetes.io/name=authentik,app.kubernetes.io/component=worker \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n irl ${AUTHENTIK_WORKER} -- ak shell -c "
from authentik.flows.models import Flow
from authentik.crypto.models import CertificateKeyPair
from authentik.providers.oauth2.models import OAuth2Provider, ScopeMapping, ClientTypes, RedirectURI, RedirectURIMatchingMode
from authentik.core.models import Application

provider, created = OAuth2Provider.objects.get_or_create(
    name='paperless',
    defaults={
        'authorization_flow': Flow.objects.get(slug='default-provider-authorization-implicit-consent'),
        'invalidation_flow': Flow.objects.get(slug='default-provider-invalidation-flow'),
        'client_type': ClientTypes.CONFIDENTIAL,
        'signing_key': CertificateKeyPair.objects.get(name='authentik Self-signed Certificate'),
    },
)
provider.redirect_uris = [
    RedirectURI(
        matching_mode=RedirectURIMatchingMode.STRICT,
        url='https://archives.lab.infiniteroomlabs.cloud/accounts/oidc/authentik/login/callback/',
    ),
]
for scope_name in ['openid', 'email', 'profile']:
    provider.property_mappings.add(ScopeMapping.objects.get(scope_name=scope_name))
provider.save()

app, _ = Application.objects.get_or_create(
    slug='paperless',
    defaults={
        'name': 'Paperless-ngx',
        'provider': provider,
        'meta_launch_url': 'https://archives.lab.infiniteroomlabs.cloud',
    },
)
print(f'CLIENT_ID={provider.client_id}')
"
```

The output prints the client_id. The client_secret has to be extracted
WITHOUT printing it -- pipe it directly into a staging file:

```bash
mkdir -p /tmp/paperless-stage && chmod 700 /tmp/paperless-stage
kubectl exec -n irl ${AUTHENTIK_WORKER} -- ak shell -c "
from authentik.providers.oauth2.models import OAuth2Provider
print('MARKER_START')
print(OAuth2Provider.objects.get(name='paperless').client_secret)
print('MARKER_END')
" 2>&1 | awk '/MARKER_START/{flag=1; next} /MARKER_END/{flag=0} flag' \
  > /tmp/paperless-stage/oidc-client-secret
echo "<CLIENT_ID_FROM_ABOVE>" > /tmp/paperless-stage/oidc-client-id
```

Verify the OIDC discovery endpoint:

```bash
curl -sS https://auth.lab.infiniteroomlabs.cloud/application/o/paperless/.well-known/openid-configuration | jq .issuer
```

Expected: `"https://auth.lab.infiniteroomlabs.cloud/application/o/paperless/"`

Build the `PAPERLESS_SOCIALACCOUNT_PROVIDERS` JSON blob:

```bash
CLIENT_ID=$(cat /tmp/paperless-stage/oidc-client-id)
CLIENT_SECRET=$(cat /tmp/paperless-stage/oidc-client-secret)
jq -n --arg client_id "$CLIENT_ID" --arg secret "$CLIENT_SECRET" \
  '{
    openid_connect: {
      APPS: [{
        provider_id: "authentik",
        name: "Authentik SSO",
        client_id: $client_id,
        secret: $secret,
        settings: {
          server_url: "https://auth.lab.infiniteroomlabs.cloud/application/o/paperless/.well-known/openid-configuration"
        }
      }],
      OAUTH_PKCE_ENABLED: true
    }
  }' -c > /tmp/paperless-stage/socialaccount-providers.json
unset CLIENT_ID CLIENT_SECRET
```

Create BW items 4, 5, 6 from the staging files (see step 1 pattern).
Append matching bw-sync entries:

```yaml
  - bw_item: "paperless-oidc-client-id"
    ansible_var: "vault_paperless_oidc_client_id"
    k8s_secret: "paperless-oidc"
    k8s_key: "client-id"

  - bw_item: "paperless-oidc-client-secret"
    ansible_var: "vault_paperless_oidc_client_secret"
    k8s_secret: "paperless-oidc"
    k8s_key: "client-secret"

  - bw_item: "paperless-socialaccount-providers"
    ansible_var: "vault_paperless_socialaccount_providers_json"
    k8s_secret: "paperless-secrets"
    k8s_key: "PAPERLESS_SOCIALACCOUNT_PROVIDERS"
```

## Step 5: Create Garage paperless-backups bucket + IAM key

Port-forward the Garage admin API:

```bash
kubectl port-forward -n irl svc/garage 3903:3903 &
PF_PID=$!
sleep 2

GARAGE_ADMIN_TOKEN=$(kubectl get secret garage-admin-secret -n irl \
  -o jsonpath='{.data.admin-token}' | base64 -d)

# Create bucket
BUCKET_RESPONSE=$(curl -sS -X POST "http://localhost:3903/v1/bucket" \
  -H "Authorization: Bearer $GARAGE_ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"globalAlias":"paperless-backups"}')
BUCKET_ID=$(echo "$BUCKET_RESPONSE" | jq -r '.id')
echo "bucket id: $BUCKET_ID"

# Create access key
KEY_RESPONSE=$(curl -sS -X POST "http://localhost:3903/v1/key?list=false" \
  -H "Authorization: Bearer $GARAGE_ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"paperless-backup"}')

# Stage the credentials WITHOUT echoing them
echo "$KEY_RESPONSE" | jq -r '.accessKeyId' > /tmp/paperless-stage/s3-access-key
echo "$KEY_RESPONSE" | jq -r '.secretAccessKey' > /tmp/paperless-stage/s3-secret-key

# Grant the key read+write on the bucket
ACCESS_KEY=$(cat /tmp/paperless-stage/s3-access-key)
curl -sS -X POST "http://localhost:3903/v1/bucket/allow" \
  -H "Authorization: Bearer $GARAGE_ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"bucketId\":\"$BUCKET_ID\",\"accessKeyId\":\"$ACCESS_KEY\",\"permissions\":{\"read\":true,\"write\":true,\"owner\":false}}" \
  | jq '.globalAliases'

unset GARAGE_ADMIN_TOKEN ACCESS_KEY KEY_RESPONSE BUCKET_ID BUCKET_RESPONSE
kill $PF_PID
```

Create BW items 7, 8 from `/tmp/paperless-stage/s3-access-key` and
`/tmp/paperless-stage/s3-secret-key`. Append the matching bw-sync entries.

Clean up the staging directory:

```bash
shred -uf /tmp/paperless-stage/* && rmdir /tmp/paperless-stage
```

## Step 6: Sync all 8 secrets to vault + k8s

```bash
./scripts/bw-sync.sh --dry-run --target both
./scripts/bw-sync.sh --target both
```

Expected: 8 updated in ansible vault, 4 K8s Secrets created/updated:
- `postgres-paperless` (1 key)
- `paperless-secrets` (3 keys: secret-key, admin-password, PAPERLESS_SOCIALACCOUNT_PROVIDERS)
- `paperless-oidc` (2 keys)
- `paperless-backup-s3` (2 keys)

Verify:

```bash
kubectl get secrets -n irl | grep paperless
```

## Step 7: Run the playbook chain

```bash
cd ansible

# 7a. Update NFS exports + create the consume subdir + apply anonuid mapping
direnv exec . uv run ansible-playbook playbooks/credentials-rotation.yml

# 7b. Create ZFS datasets + chown to UID 1000
direnv exec . uv run ansible-playbook playbooks/zfs.yml

# 7c. Create PVs + StorageClasses
direnv exec . uv run ansible-playbook playbooks/k3s.yml

# 7d. Provision the paperless DB + role in CNPG
direnv exec . uv run ansible-playbook playbooks/helm-deploy.yml --tags postgres

# 7e. Helm install irl-paperless
direnv exec . uv run ansible-playbook playbooks/helm-deploy.yml --tags paperless

# 7f. Refresh CoreDNS so archives.lab.infiniteroomlabs.cloud resolves
direnv exec . uv run ansible-playbook playbooks/helm-deploy.yml --tags coredns
```

Each step is idempotent. Re-run any of them if something fails partway.

## Step 8: Verify the deployment

```bash
# All 3 paperless pods Running 1/1
kubectl get pods -n irl -l app.kubernetes.io/instance=paperless

# Helm release status
helm list -n irl | grep paperless

# HTTP / TLS
curl -I https://archives.lab.infiniteroomlabs.cloud
# Expected: HTTP/2 302, location: /accounts/login/

# Logs (look for "Connected to redis", no auth errors)
kubectl logs -n irl deploy/paperless --tail=30 | grep -iE "celery|redis|consum|error"

# Manual consume test
kubectl exec -n irl deploy/paperless -- bash -c 'echo "test" > /tmp/t.pdf'
kubectl exec -n irl deploy/paperless -- cp /tmp/t.pdf /usr/src/paperless/consume/t.pdf
# Wait ~3 minutes, check the UI
```

## Step 9: Smoke-test the backup CronJob

```bash
kubectl create job --from=cronjob/paperless-backup paperless-backup-smoke -n irl
kubectl logs -n irl job/paperless-backup-smoke -f
# Expected: document_exporter runs, zip uploaded to s3://paperless-backups/

# Verify in the bucket
export AWS_ACCESS_KEY_ID=$(bw get password paperless-backup-s3-access-key)
export AWS_SECRET_ACCESS_KEY=$(bw get password paperless-backup-s3-secret-key)
aws --endpoint-url=https://s3.internal.lab.infiniteroomlabs.cloud s3 ls s3://paperless-backups/
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

kubectl delete job/paperless-backup-smoke -n irl
```

## Step 10: Test SSO end-to-end

1. Browse to https://archives.lab.infiniteroomlabs.cloud
2. Log in with `admin` + the password from the `paperless-admin` BW item
3. Log out
4. Click "Sign in with Authentik SSO" -- should redirect to Authentik,
   prompt for credentials, then redirect back to paperless with an
   auto-provisioned user account

If the SSO loop completes successfully, flip
`PAPERLESS_DISABLE_REGULAR_LOGIN` to `"true"` in the chart values and
redeploy:

```bash
# Edit helm-charts/charts/irl-paperless/values.yaml or
# ansible/helm/paperless/values.yaml to set:
#   PAPERLESS_DISABLE_REGULAR_LOGIN: "true"

direnv exec . uv run ansible-playbook playbooks/helm-deploy.yml --tags paperless
```

## Gotchas (learned the hard way during the original bringup)

Each of these will bite you again on a fresh deploy if you skip the
fix in the corresponding step above.

1. **bw-sync.sh state file collision** -- if you run `--target both` for
   the first time on new secrets, the ansible sync will save checksums
   for ALL items, then the k8s sync sees matching checksums and skips
   the kubectl apply silently. The script reports 0 errors but the
   K8s Secrets don't exist. Fixed in commit `ac7e442`. If you hit this
   on a state file from before that fix: `jq 'with_entries(select(.key | startswith("paperless") | not))' ~/.local/share/irl/bw-sync-state.json`
   to clear the relevant entries.

2. **bw-sync.sh JSON value handling** -- the `PAPERLESS_SOCIALACCOUNT_PROVIDERS`
   value is JSON with lots of double quotes. Old `bw-sync.sh` shell-
   interpolated values into the yq expression and broke on the lexer.
   Fixed in commit `117ed15`.

3. **bjw-s/common alphabetizes env vars** -- the chart's
   `PAPERLESS_REDIS = "redis://:$(PAPERLESS_REDIS_PASSWORD)@..."` does NOT
   work because PAPERLESS_REDIS sorts before PAPERLESS_REDIS_PASSWORD in
   the rendered Deployment, breaking the k8s `$(VAR)` substitution. The
   chart now marks PAPERLESS_REDIS as `OVERRIDE-ME` and the playbook
   renders the URL inline from `vault_redis_password` via a
   secrets-override values file. See the "Phase 3: Write Paperless secrets
   override" task in helm-deploy.yml.

4. **Tika image** -- the upstream paperless docs sometimes reference
   `ghcr.io/paperless-ngx/tika:latest` which returns 403. Use
   `docker.io/apache/tika:latest`. Fixed in chart v0.1.1.

5. **NFS UID alignment** -- the parent nfs-share export needs `anonuid=1000,anongid=1000`
   alongside `all_squash`, otherwise SMB/NFS writes from clients land as
   `nobody` and the paperless container (UID 1000) can't delete its own
   ingested files. Handled in `credentials-rotation.yml`.

6. **/media/root permissions** -- ships as `0750 root:root` which blocks
   POSIX traversal for non-root users. NFS doesn't care (nfsd bypasses
   POSIX), but Samba does. The samba.yml playbook chmods this to `0755`.
   Don't undo it.

7. **`--tags paperless` filter on zfs.yml** -- if you only tag the
   chown task with `[paperless]` and not the dataset-creation task,
   `--tags paperless` will create directories without the underlying
   ZFS datasets. Always run zfs.yml without the tag filter on a fresh
   deploy.

8. **paperless-consume PV hostPath** -- it points at
   `/media/root/storage1/nfs-share/paperless-consume/` (under the
   existing nfs-share), NOT at a dedicated ZFS dataset. This is so the
   laptop's existing /mnt/homelab-nfs mount can write to the same path
   without a new export. Don't "fix" this by moving it to a dedicated
   dataset.

## Rollback

To completely tear down a paperless deployment for a clean re-test:

```bash
helm uninstall paperless -n irl
kubectl delete pvc -n irl paperless-consume-pvc paperless-media-pvc paperless-data-pvc paperless-export-pvc
kubectl delete pv pv-paperless-consume pv-paperless-media pv-paperless-data
kubectl delete secret -n irl postgres-paperless paperless-secrets paperless-oidc paperless-backup-s3
kubectl exec -n irl postgresql-1 -c postgres -- psql -U postgres -c "DROP DATABASE paperless; DROP ROLE paperless;"
ssh homelab "sudo zfs destroy main/paperless-media; sudo zfs destroy main/paperless-data"
ssh homelab "sudo rm -rf /media/root/storage1/nfs-share/paperless-consume"
```

The Authentik provider, Garage bucket, and Bitwarden items survive --
delete those manually if you need a complete clean slate. They're
re-created idempotently by the steps above.

## See Also

- `setup-windows-paperless-ingestion.md` -- end-user setup after deploy
- `restore-paperless.md` -- DR / migration procedure
- `samba-add-auth.md` -- Samba hardening (post-rollout)
- `helm-charts/charts/irl-paperless/` -- the chart source
