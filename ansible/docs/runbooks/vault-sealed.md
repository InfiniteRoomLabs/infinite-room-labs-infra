# Runbook: Vault Sealed

## Severity: HIGH (blocks secret access for all services)

## Detection

- Vault health check returns sealed status
- Services that read from Vault fail to start or authenticate
- `docker exec irl-vault vault status` shows `Sealed: true`

## Cause

Vault auto-seals on:
- Container restart
- Server reboot
- Out-of-memory kill
- Manual seal command

## Resolution

### Unseal Vault

Vault requires 3 of 5 unseal keys (key threshold configured at init).

```bash
# Check status
docker exec irl-vault vault status

# Unseal (repeat 3 times with different keys)
docker exec -it irl-vault vault operator unseal
# Enter unseal key 1

docker exec -it irl-vault vault operator unseal
# Enter unseal key 2

docker exec -it irl-vault vault operator unseal
# Enter unseal key 3

# Verify
docker exec irl-vault vault status
# Should show: Sealed: false
```

### After Unseal

Services that depend on Vault may need a restart:
```bash
cd /opt/irl/{stack}
sudo docker compose restart
```

## Unseal Key Storage

Unseal keys must be stored securely and separately:
- Never store all keys in one place
- Never store keys on the server itself
- Consider: password manager, hardware security key, encrypted USB

## Prevention

- Avoid unnecessary Vault container restarts
- Monitor Vault health in Grafana
- Consider auto-unseal with a cloud KMS (future enhancement)
