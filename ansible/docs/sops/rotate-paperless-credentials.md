# SOP: Rotate Paperless-ngx Credentials

Walks through rotating each of the 8 credentials Paperless-ngx depends
on. Most are generic Bitwarden + bw-sync rotations, but some have
Paperless-specific gotchas (the SECRET_KEY irreversibly invalidates
encrypted fields, the OIDC client_secret needs to be updated in BOTH
Authentik AND Bitwarden in the right order, etc.).

The general "how to rotate any IRL secret" pattern is in
`rotate-secrets.md`. This SOP layers the Paperless-specific concerns on
top of that.

## The 8 paperless secrets at a glance

| BW item | Used by | Rotation safety | Procedure |
|---|---|---|---|
| `pg-paperless` | CNPG postgres role | Safe | Routine |
| `paperless-secret-key` | Django field encryption | **DESTRUCTIVE** | Special |
| `paperless-admin` | Bootstrap admin login | Safe | Routine |
| `paperless-oidc-client-id` | Authentik OIDC binding | Coordinated | Special |
| `paperless-oidc-client-secret` | Authentik OIDC binding | Coordinated | Special |
| `paperless-socialaccount-providers` | Derived JSON blob | Coordinated | Special (re-rendered) |
| `paperless-backup-s3-access-key` | Garage IAM | Coordinated | Special |
| `paperless-backup-s3-secret-key` | Garage IAM | Coordinated | Special |

## Routine rotations (pg-paperless, paperless-admin)

These two are independent of any other system and rotate via the
standard pattern.

```bash
# Generate a new value (32 chars, no shell-special chars)
NEW_PW=$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)

# Update the BW item
ITEM_ID=$(bw list items --search "<item-name>" 2>/dev/null \
  | jq -r '.[0].id')
bw get item "$ITEM_ID" 2>/dev/null \
  | jq --arg pw "$NEW_PW" '.login.password = $pw' \
  | bw encode | bw edit item "$ITEM_ID" 2>/dev/null \
  | jq -r '"Rotated: \(.name)"'
unset NEW_PW
bw sync 2>&1 | tail -1

# Push to vault + k8s
./scripts/bw-sync.sh --target both
```

### After rotating pg-paperless

The new password lands in `postgres-paperless` K8s Secret immediately,
but CNPG's postgres user still has the OLD password. The CNPG operator
reconciles role passwords from Secret state on a polling cycle, so the
new password takes effect within ~30 seconds. To force it:

```bash
kubectl -n irl annotate cluster postgresql cnpg.io/reloadedAt=$(date +%s) --overwrite
```

Then restart paperless to pick up the new env value:

```bash
kubectl rollout restart deploy/paperless -n irl
```

Verify:

```bash
kubectl logs -n irl deploy/paperless --tail=20 | grep -iE "postgres|connect"
```

Expected: "Connected to PostgreSQL", no `password authentication failed`
errors.

### After rotating paperless-admin

The new password lands in `paperless-secrets/admin-password` immediately,
but the env var only takes effect on pod restart AND only matters during
the first-run admin user creation. For an EXISTING `admin` user, the
password change is NOT applied automatically -- the env var is only used
to seed the user the first time.

To rotate the password for an existing admin user, log into the paperless
UI as that admin (with the OLD password) and change it via Settings ->
User Profile, then update the BW item to match. This only matters if
you actually need the local admin login -- if SSO is the only access
path, the local admin is dormant and rotation is theater.

If you've lost the old password entirely:

```bash
kubectl exec -n irl deploy/paperless -it -- \
  python /usr/src/paperless/src/manage.py changepassword admin
```

This prompts for a new password interactively. Then update the BW item
to match what you typed.

## SECRET_KEY rotation (DESTRUCTIVE -- read carefully)

`PAPERLESS_SECRET_KEY` is used by Django to encrypt sensitive fields in
the database (OAuth tokens, mail account passwords, custom field
values flagged as sensitive). **Rotating it invalidates every encrypted
field**. Documents themselves are unaffected -- only the small set of
encrypted-at-rest fields.

Specifically broken after rotation:
- Existing OIDC sessions (users will be forced to re-login)
- Stored mail account credentials (mail polling will fail until re-entered)
- Stored share-link tokens
- Custom field values where the field is type "Encrypted Text"

Documents, OCR text, tags, correspondents, document types, and
non-encrypted custom fields are unaffected.

### Procedure

1. **Verify what depends on encrypted state.** If you have mail polling
   accounts configured in Paperless, write down the IMAP credentials
   somewhere -- you'll re-enter them after the rotation.

2. **Take a fresh backup before rotating** so you can roll back if
   needed:

   ```bash
   kubectl create job --from=cronjob/paperless-backup paperless-backup-pre-rotation -n irl
   kubectl wait --for=condition=complete job/paperless-backup-pre-rotation -n irl --timeout=10m
   kubectl delete job/paperless-backup-pre-rotation -n irl
   ```

3. **Generate the new key**:

   ```bash
   NEW_KEY=$(python3 -c "import secrets, string; print(''.join(secrets.choice(string.ascii_letters + string.digits + '!@#%^&*(-_=+)') for _ in range(64)))")
   ```

4. **Update Bitwarden, sync, restart**:

   ```bash
   ITEM_ID=$(bw list items --search "paperless-secret-key" 2>/dev/null | jq -r '.[0].id')
   bw get item "$ITEM_ID" 2>/dev/null \
     | jq --arg pw "$NEW_KEY" '.login.password = $pw' \
     | bw encode | bw edit item "$ITEM_ID" 2>/dev/null
   unset NEW_KEY
   bw sync
   ./scripts/bw-sync.sh --target both
   kubectl rollout restart deploy/paperless -n irl
   ```

5. **Re-enter mail credentials** in the Paperless UI under
   Settings -> Mail (if you had any).

6. **Verify nothing else is broken**: log in via SSO, open a few
   documents, check the inbox.

### Rollback (if rotation breaks something critical)

Restore the OLD secret key value from the BW item history (BW keeps
revisions of every login item):

```bash
bw get item paperless-secret-key 2>/dev/null | jq '.passwordHistory'
```

Pick the previous value, paste it back into the item via `bw edit item`,
re-sync, restart paperless. The previously-encrypted fields will work
again because they were never re-encrypted with the new key (the rotation
only changes the active key, not existing ciphertext on disk).

If you want to rotate WITHOUT breaking encrypted fields, use Django's
`KEY_ROTATION` settings to support both old and new keys simultaneously.
This requires a chart change and is not currently configured -- file
an issue if you need it.

## OIDC client_secret rotation (coordinated, in order)

The OIDC client_secret lives in TWO places that must agree:
1. Authentik's `OAuth2Provider.client_secret` field
2. Bitwarden's `paperless-oidc-client-secret` item -> synced to
   `paperless-secrets/PAPERLESS_SOCIALACCOUNT_PROVIDERS` (the JSON blob
   embeds it)

Order matters: rotate Authentik first, capture the new secret, then
update BW + the JSON blob, sync, restart paperless. If you do it in the
other order, paperless will use the new secret to authenticate against
the old Authentik provider and SSO will break.

### Procedure

1. **Generate a new secret in Authentik via ak shell**:

   ```bash
   AUTHENTIK_WORKER=$(kubectl get pod -n irl \
     -l app.kubernetes.io/name=authentik,app.kubernetes.io/component=worker \
     -o jsonpath='{.items[0].metadata.name}')

   kubectl exec -n irl ${AUTHENTIK_WORKER} -- ak shell -c "
   from authentik.providers.oauth2.models import OAuth2Provider
   from authentik.lib.generators import generate_key
   p = OAuth2Provider.objects.get(name='paperless')
   p.client_secret = generate_key()
   p.save()
   print('ROTATED')
   " 2>&1 | grep ROTATED
   ```

2. **Extract the new secret to a stage file** (without printing):

   ```bash
   mkdir -p /tmp/oidc-rotate && chmod 700 /tmp/oidc-rotate
   kubectl exec -n irl ${AUTHENTIK_WORKER} -- ak shell -c "
   from authentik.providers.oauth2.models import OAuth2Provider
   p = OAuth2Provider.objects.get(name='paperless')
   print('MARKER_SECRET_START')
   print(p.client_secret)
   print('MARKER_SECRET_END')
   " 2>&1 | awk '/MARKER_SECRET_START/{flag=1; next} /MARKER_SECRET_END/{flag=0} flag' \
     > /tmp/oidc-rotate/client-secret
   wc -c < /tmp/oidc-rotate/client-secret  # length only
   ```

3. **Update the BW client_secret item**:

   ```bash
   NEW_SECRET=$(cat /tmp/oidc-rotate/client-secret)
   ITEM_ID=$(bw list items --search "paperless-oidc-client-secret" 2>/dev/null | jq -r '.[0].id')
   bw get item "$ITEM_ID" 2>/dev/null \
     | jq --arg pw "$NEW_SECRET" '.login.password = $pw' \
     | bw encode | bw edit item "$ITEM_ID" 2>/dev/null
   unset NEW_SECRET
   ```

4. **Re-render the SOCIALACCOUNT_PROVIDERS JSON** (it embeds the secret):

   ```bash
   CLIENT_ID=$(bw get password paperless-oidc-client-id)
   CLIENT_SECRET=$(cat /tmp/oidc-rotate/client-secret)
   NEW_JSON=$(jq -n --arg client_id "$CLIENT_ID" --arg secret "$CLIENT_SECRET" \
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
     }' -c)

   ITEM_ID=$(bw list items --search "paperless-socialaccount-providers" 2>/dev/null | jq -r '.[0].id')
   bw get item "$ITEM_ID" 2>/dev/null \
     | jq --arg pw "$NEW_JSON" '.login.password = $pw' \
     | bw encode | bw edit item "$ITEM_ID" 2>/dev/null

   unset CLIENT_ID CLIENT_SECRET NEW_JSON
   shred -uf /tmp/oidc-rotate/* && rmdir /tmp/oidc-rotate
   ```

5. **Sync + restart**:

   ```bash
   bw sync
   ./scripts/bw-sync.sh --target both
   kubectl rollout restart deploy/paperless -n irl
   ```

6. **Verify SSO works**: log out of paperless, click "Sign in with
   Authentik SSO", complete the loop. Check `kubectl logs -n irl deploy/paperless`
   for OIDC errors during the test.

## OIDC client_id rotation

You generally don't rotate the client_id -- it's a public identifier
and rotating it doesn't add security. If you have a reason to (e.g.,
the value leaked into a stack trace and you want a clean slate), the
procedure is the same as the client_secret rotation but you regenerate
`client_id` instead of `client_secret`:

```python
# inside ak shell
from authentik.lib.generators import generate_id
p.client_id = generate_id()
```

You'll also need to update the redirect URIs if any external system
hardcoded the client_id in a callback path. None do for the paperless
setup, but other OIDC clients might.

## S3 backup credential rotation

The Garage IAM key pair used by the backup CronJob can be rotated
without any Authentik or Postgres coordination. The CronJob picks up
the new credentials from the K8s Secret on its next run.

### Procedure

1. **Create a new IAM key in Garage** (see `garage-bucket-iam-management.md`):

   ```bash
   kubectl port-forward -n irl svc/garage 3903:3903 &
   PF_PID=$!
   sleep 2

   GARAGE_ADMIN_TOKEN=$(kubectl get secret garage-admin-secret -n irl \
     -o jsonpath='{.data.admin-token}' | base64 -d)

   KEY_RESPONSE=$(curl -sS -X POST "http://localhost:3903/v1/key?list=false" \
     -H "Authorization: Bearer $GARAGE_ADMIN_TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"name":"paperless-backup-rotated"}')

   mkdir -p /tmp/s3-rotate && chmod 700 /tmp/s3-rotate
   echo "$KEY_RESPONSE" | jq -r '.accessKeyId'   > /tmp/s3-rotate/access-key
   echo "$KEY_RESPONSE" | jq -r '.secretAccessKey' > /tmp/s3-rotate/secret-key
   ```

2. **Grant the new key access to paperless-backups**:

   ```bash
   BUCKET_ID=$(curl -sS "http://localhost:3903/v1/bucket?globalAlias=paperless-backups" \
     -H "Authorization: Bearer $GARAGE_ADMIN_TOKEN" | jq -r '.id')

   ACCESS_KEY=$(cat /tmp/s3-rotate/access-key)
   curl -sS -X POST "http://localhost:3903/v1/bucket/allow" \
     -H "Authorization: Bearer $GARAGE_ADMIN_TOKEN" \
     -H "Content-Type: application/json" \
     -d "{\"bucketId\":\"$BUCKET_ID\",\"accessKeyId\":\"$ACCESS_KEY\",\"permissions\":{\"read\":true,\"write\":true,\"owner\":false}}"
   unset ACCESS_KEY
   ```

3. **Update the BW items**:

   ```bash
   for kind in access-key secret-key; do
     NEW_VAL=$(cat /tmp/s3-rotate/$kind)
     ITEM_ID=$(bw list items --search "paperless-backup-s3-$kind" 2>/dev/null | jq -r '.[0].id')
     bw get item "$ITEM_ID" 2>/dev/null \
       | jq --arg pw "$NEW_VAL" '.login.password = $pw' \
       | bw encode | bw edit item "$ITEM_ID" 2>/dev/null
   done
   unset NEW_VAL
   shred -uf /tmp/s3-rotate/* && rmdir /tmp/s3-rotate
   ```

4. **Sync + verify**:

   ```bash
   bw sync
   ./scripts/bw-sync.sh --target both

   # Trigger a manual backup run to confirm the new creds work
   kubectl create job --from=cronjob/paperless-backup paperless-backup-rotation-test -n irl
   kubectl logs -n irl job/paperless-backup-rotation-test -f
   kubectl delete job/paperless-backup-rotation-test -n irl
   ```

5. **Delete the OLD Garage IAM key** (only after verifying the new one
   works):

   ```bash
   # Find the old key by name
   OLD_ACCESS_KEY=$(curl -sS "http://localhost:3903/v1/key?list" \
     -H "Authorization: Bearer $GARAGE_ADMIN_TOKEN" \
     | jq -r '.[] | select(.name == "paperless-backup") | .id')
   curl -sS -X DELETE "http://localhost:3903/v1/key?id=${OLD_ACCESS_KEY}" \
     -H "Authorization: Bearer $GARAGE_ADMIN_TOKEN"

   unset GARAGE_ADMIN_TOKEN OLD_ACCESS_KEY
   kill $PF_PID
   ```

   The old key is now invalid. Any other system that was using it (none,
   in this case) will break -- worth checking before the delete.

## Bulk rotation

There's no "rotate everything" command. The rotation policy in
`rotate-secrets.md` is 180 days for infra and 365 days for service
secrets, but each item has its own rotation timer in the bw-sync state.
Run the rotation check to find what's overdue:

```bash
./scripts/bw-sync.sh --check-rotation
```

For paperless-specific items, the check looks at the BW item's
`revisionDate` field, not the actual cryptographic age of the secret.
If you've never edited the BW item (just rotated the underlying value
and re-synced), the item's revisionDate doesn't update -- the rotation
check thinks the item is fresher than the actual stored secret.

## See Also

- `rotate-secrets.md` -- generic rotation pattern + policy
- `bw-sync-troubleshooting.md` -- if rotation triggers a sync failure
- `authentik-oidc-via-ak-shell.md` -- the ak shell pattern for OIDC ops
- `garage-bucket-iam-management.md` -- the garage admin API pattern for S3 ops
- `restore-paperless.md` -- DR if a SECRET_KEY rotation breaks something
