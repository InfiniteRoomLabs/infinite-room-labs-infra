# Runbook: Vault Sealed

## Severity: HIGH (blocks every secret External Secrets Operator delivers)

Vault runs in the `irl` namespace as the StatefulSet pod `vault-0` (Shamir seal, file storage, 3-of-5 threshold). It re-seals on **every** restart -- pod eviction, node reboot, OOM kill, chart upgrade -- and nothing unseals it automatically.

## Detection

- `kubectl exec -n irl vault-0 -- vault status` shows `Sealed: true` (exit code 2)
- `https://vault.lab.infiniteroomlabs.cloud/v1/sys/health` returns 503 (200 = unsealed and active)
- **The usual first symptom is downstream**: the ClusterSecretStore goes `InvalidProviderConfig` ("unable to create client") and every ExternalSecret stops syncing:

```bash
kubectl get clustersecretstore vault-irl
kubectl get externalsecret -A     # watch the LAST SYNC column go stale
```

Nothing alerts on this today -- Vault is not a Prometheus scrape target and ESO exports no metrics the cluster collects, so a sealed Vault can sit unnoticed for days. Tracked in `docs/plans/RESEARCH.md`.

## Resolution

### 1. Unseal

Keys live in the Bitwarden item **`Vault Unseal Keys + Root Token`** (folder `IRL/Services/Vault`), as a numbered list in the item's notes alongside the root token. Three of the five are required.

```bash
kubectl exec -n irl vault-0 -- vault status | grep -E 'Sealed|Unseal Progress'

# Repeat three times with DIFFERENT keys. Never echo the key; paste it into
# the command, or pull it straight from Bitwarden:
KEY=$(bw get item "Vault Unseal Keys + Root Token" | jq -r '.notes' | sed -n 's/^Unseal Key 1: //p')
kubectl exec -n irl vault-0 -- vault operator unseal "$KEY"; unset KEY
# ... keys 2 and 3

kubectl exec -n irl vault-0 -- vault status | grep Sealed    # Sealed  false
```

`Unseal Progress 2/3` between steps is normal. A wrong key resets progress to 0.

### 2. Kick External Secrets Operator

ESO caches its failed Vault client and will not retry promptly; restart the controller so the store re-validates instead of waiting out the refresh interval:

```bash
kubectl rollout restart -n external-secrets deploy/external-secrets
kubectl rollout status  -n external-secrets deploy/external-secrets

kubectl get clustersecretstore vault-irl          # STATUS Valid, READY True
kubectl get externalsecret -A                     # SecretSynced, LAST SYNC recent
```

### 3. Check what else waited on it

Anything whose Secret is ESO-delivered may have been running on a stale Secret or failing to start:

```bash
kubectl get pods -A | grep -vE 'Running|Completed'
```

## Unseal Key Storage

The keys and the root token are in Bitwarden, which is the single source of truth for this homelab. Deliberate trade-off, written down so nobody "fixes" it by accident: splitting the five keys across separate custodians is the textbook answer, but a single-operator homelab with no second custodian gets *less* available, not more secure, from key-splitting theatre. The real hardening step is auto-unseal (below), not key sharding.

Never write unseal keys onto the server itself, into a values file, or into this repo.

## Prevention

- **Auto-unseal** is the actual fix: Vault's transit seal against a second Vault, or a cloud KMS. Both add an external dependency; neither has been set up. Until then every restart needs a human.
- Keep `vault-0` off nodes that get drained casually; it has no HA peer.
- After any chart upgrade or node reboot, check `vault status` as part of the post-change walk -- it is the one service that comes back "up" and useless.
