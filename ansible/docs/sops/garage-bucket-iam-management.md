# SOP: Manage Garage S3 Buckets and IAM Keys

How to create, configure, and remove buckets and IAM access keys in the
homelab Garage S3 deployment using the admin HTTP API. Garage doesn't
ship with `mc` admin commands or AWS-CLI-style IAM management; the
admin API is the canonical interface and the only one that exposes
bucket creation, key minting, and permission grants atomically.

The Garage release in the cluster is `irl-garage` and runs as a
ClusterIP service `garage` on ports `3900` (S3 API), `3901` (RPC),
`3902` (Web UI), and `3903` (admin API).

## Prerequisites

- `kubectl` with access to the `irl` namespace
- `jq` for parsing JSON responses
- The Garage admin token in `garage-admin-secret/admin-token` (already
  populated by bw-sync from the `garage-admin-token` Bitwarden item)

## Set up the admin connection

The admin API is ClusterIP-only by design (port 3903 is never exposed
via Traefik). Open a port-forward in a background shell:

```bash
kubectl port-forward -n irl svc/garage 3903:3903 &
PF_PID=$!
sleep 2

# Health check before doing anything
curl -sS http://localhost:3903/health
# Expected: "Garage is fully operational"
```

Load the admin token into a shell variable WITHOUT echoing it:

```bash
GARAGE_ADMIN_TOKEN=$(kubectl get secret garage-admin-secret -n irl \
  -o jsonpath='{.data.admin-token}' | base64 -d)
# Verify it's loaded (length only -- never the value)
echo "token length: $(echo -n "$GARAGE_ADMIN_TOKEN" | wc -c)"
```

All admin requests use `Authorization: Bearer $GARAGE_ADMIN_TOKEN`.

When you're done, always tear down:

```bash
unset GARAGE_ADMIN_TOKEN
kill $PF_PID 2>/dev/null
```

## Create a bucket

```bash
BUCKET_NAME="example-backups"   # adjust

BUCKET_RESPONSE=$(curl -sS -X POST "http://localhost:3903/v1/bucket" \
  -H "Authorization: Bearer $GARAGE_ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"globalAlias\":\"${BUCKET_NAME}\"}")

BUCKET_ID=$(echo "$BUCKET_RESPONSE" | jq -r '.id')
echo "$BUCKET_RESPONSE" | jq '{id, alias: .globalAliases}'
echo "BUCKET_ID=$BUCKET_ID"
```

Bucket IDs are SHA-256 fingerprints, not the alias. Most subsequent
operations take the ID, not the name. Save it.

## List buckets

```bash
curl -sS "http://localhost:3903/v1/bucket?list" \
  -H "Authorization: Bearer $GARAGE_ADMIN_TOKEN" \
  | jq '.[] | {id, aliases: .globalAliases, localAliases}'
```

## Get bucket details (size, object count, key bindings)

```bash
curl -sS "http://localhost:3903/v1/bucket?id=${BUCKET_ID}" \
  -H "Authorization: Bearer $GARAGE_ADMIN_TOKEN" \
  | jq '{
      aliases: .globalAliases,
      objects: .objects,
      bytes: .bytes,
      keys: (.keys | map({name: .name, accessKeyId, permissions}))
    }'
```

## Create an IAM access key

```bash
KEY_NAME="example-backup-uploader"

KEY_RESPONSE=$(curl -sS -X POST "http://localhost:3903/v1/key?list=false" \
  -H "Authorization: Bearer $GARAGE_ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"${KEY_NAME}\"}")

# Stage the credentials WITHOUT echoing them
mkdir -p /tmp/garage-stage && chmod 700 /tmp/garage-stage
echo "$KEY_RESPONSE" | jq -r '.accessKeyId'   > /tmp/garage-stage/access-key
echo "$KEY_RESPONSE" | jq -r '.secretAccessKey' > /tmp/garage-stage/secret-key

# Show only metadata
echo "$KEY_RESPONSE" | jq '{name, accessKeyId}'
echo "secret length: $(wc -c < /tmp/garage-stage/secret-key)"
```

The secret key is only ever returned in this single response. There is
no API to retrieve it again -- if you lose it, you must delete the key
and create a new one. Stash it in Bitwarden immediately:

```bash
FOLDER_ID=$(bw list folders 2>/dev/null \
  | jq -r '.[] | select(.name == "IRL/Services/Garage") | .id')

ACCESS_VAL=$(cat /tmp/garage-stage/access-key)
SECRET_VAL=$(cat /tmp/garage-stage/secret-key)

jq -n --arg name "garage-${KEY_NAME}-access-key" --arg pw "$ACCESS_VAL" --arg folder "$FOLDER_ID" \
  '{type:1, name:$name, folderId:$folder,
    notes:"Garage S3 access key for the example-backup-uploader IAM user.",
    login:{password:$pw, uris:[]}}' \
| bw encode | bw create item 2>/dev/null | jq -r '.name'

jq -n --arg name "garage-${KEY_NAME}-secret-key" --arg pw "$SECRET_VAL" --arg folder "$FOLDER_ID" \
  '{type:1, name:$name, folderId:$folder,
    notes:"Garage S3 secret key, paired with garage-${KEY_NAME}-access-key.",
    login:{password:$pw, uris:[]}}' \
| bw encode | bw create item 2>/dev/null | jq -r '.name'

unset ACCESS_VAL SECRET_VAL
shred -uf /tmp/garage-stage/* && rmdir /tmp/garage-stage
bw sync 2>&1 | tail -1
```

## Grant a key access to a bucket

Permissions are independent of IAM key creation. A new key has access to
NOTHING by default; you must explicitly grant it on each bucket.

```bash
ACCESS_KEY=$(bw get password garage-${KEY_NAME}-access-key)

curl -sS -X POST "http://localhost:3903/v1/bucket/allow" \
  -H "Authorization: Bearer $GARAGE_ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"bucketId\":\"$BUCKET_ID\",
    \"accessKeyId\":\"$ACCESS_KEY\",
    \"permissions\":{\"read\":true,\"write\":true,\"owner\":false}
  }" \
  | jq '{bucket: .globalAliases, keys: (.keys | map({name, permissions}))}'

unset ACCESS_KEY
```

The three permissions:
- `read`: GET, HEAD, LIST objects
- `write`: PUT, POST, multipart upload, DELETE objects
- `owner`: bucket-level ops (set CORS, lifecycle, ACLs, delete the bucket)

For backup CronJobs that just upload tarballs, `read+write` is correct.
`owner` is rarely needed at the application layer; reserve it for admin
keys used by operators.

## Revoke access

```bash
curl -sS -X POST "http://localhost:3903/v1/bucket/deny" \
  -H "Authorization: Bearer $GARAGE_ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"bucketId\":\"$BUCKET_ID\",
    \"accessKeyId\":\"$ACCESS_KEY\",
    \"permissions\":{\"read\":true,\"write\":true,\"owner\":true}
  }"
```

Setting all three to `true` revokes any of them that the key currently
holds. To revoke only writes (leave reads in place), set
`{read:false, write:true, owner:false}`.

## Delete an IAM key

```bash
ACCESS_KEY=$(bw get password garage-${KEY_NAME}-access-key)
curl -sS -X DELETE "http://localhost:3903/v1/key?id=${ACCESS_KEY}" \
  -H "Authorization: Bearer $GARAGE_ADMIN_TOKEN"
unset ACCESS_KEY
```

This is destructive and immediate. The key cannot be used after the
DELETE returns. Buckets it had access to are unaffected; only the key
binding is removed.

Don't forget to also delete the Bitwarden items and remove the
bw-sync-config.yaml entry, otherwise the next sync will report errors
trying to push a now-deleted secret to a (potentially still-existing)
K8s Secret.

## Delete a bucket

Buckets must be empty before deletion. Garage refuses to delete a bucket
with objects in it -- there is no `--force` equivalent.

```bash
# Empty the bucket via aws-cli first
ACCESS_KEY=$(bw get password garage-admin-uploader-access-key)
SECRET_KEY=$(bw get password garage-admin-uploader-secret-key)
AWS_ACCESS_KEY_ID=$ACCESS_KEY \
AWS_SECRET_ACCESS_KEY=$SECRET_KEY \
  aws --endpoint-url=https://s3.internal.lab.infiniteroomlabs.cloud \
      s3 rm s3://${BUCKET_NAME}/ --recursive
unset ACCESS_KEY SECRET_KEY

# Then delete via admin API
curl -sS -X DELETE "http://localhost:3903/v1/bucket?id=${BUCKET_ID}" \
  -H "Authorization: Bearer $GARAGE_ADMIN_TOKEN"
```

## Common pitfalls

### Forgetting to grant permissions after creating a key

A freshly-created IAM key has no access to anything. Trying to use it
returns `AccessDenied` from the S3 API with no useful detail. Always
follow `POST /v1/key` with `POST /v1/bucket/allow` in the same script.

### Confusing aliases and bucket IDs

`globalAlias` is human-friendly (`paperless-backups`). `id` is the
SHA-256 fingerprint. The S3 API and aws-cli use the alias; the admin
API uses the ID. The mapping is in
`curl /v1/bucket?id=$BUCKET_ID | jq .globalAliases`.

### Quota config drifts from cluster reality

Garage supports per-bucket quotas (`quotas.maxObjects`, `quotas.maxSize`)
but they're set at bucket creation time and not visible in the standard
listing. Check explicitly:

```bash
curl -sS "http://localhost:3903/v1/bucket?id=${BUCKET_ID}" \
  -H "Authorization: Bearer $GARAGE_ADMIN_TOKEN" \
  | jq '.quotas'
```

To set or update:

```bash
curl -sS -X PUT "http://localhost:3903/v1/bucket?id=${BUCKET_ID}" \
  -H "Authorization: Bearer $GARAGE_ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"quotas":{"maxObjects":100000,"maxSize":53687091200}}'
```

## See Also

- Garage admin API reference: https://garagehq.deuxfleurs.fr/api/garage-admin-v1.html
- `helm-charts/charts/irl-garage/` -- the chart source
- `deploy-paperless-from-scratch.md` step 5 -- a real example using these commands
