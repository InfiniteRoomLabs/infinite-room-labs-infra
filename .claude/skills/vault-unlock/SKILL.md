---
name: vault-unlock
description: Unseal HashiCorp Vault on the homelab k3s cluster. Use when Vault is sealed (after pod restart), when a deployment fails because Vault is unavailable, when the user says "unseal vault", "unlock vault", "vault is sealed", or when you detect Vault-related failures in kubectl output. Also use proactively before running Ansible playbooks that depend on Vault.
disable-model-invocation: true
---

# Vault Unlock

HashiCorp Vault re-seals every time its pod restarts. This skill automates the unseal process by fetching keys from Bitwarden and applying them via kubectl.

## Prerequisites

- `bw` CLI must be unlocked (`bw status` shows `unlocked`)
- `kubectl` must have access to the homelab cluster
- Bitwarden item "Vault Unseal Keys + Root Token" must exist in the IRL folder

## Workflow

### 1. Check seal status

```bash
kubectl exec -n irl vault-0 -- vault status 2>&1 | grep -E '(Sealed|Initialized)'
```

If `Sealed: false`, Vault is already unsealed -- tell the user and stop.

### 2. Check Bitwarden is unlocked

```bash
bw status 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','unknown'))"
```

If not `unlocked`, tell the user to run `! bw unlock` in the prompt to unlock it interactively.

### 3. Fetch and apply unseal keys

Fetch the unseal keys from Bitwarden and apply 3 of the 5 keys in a single script. The keys are stored in the notes field of item "Vault Unseal Keys + Root Token" with format `Unseal Key N: <key_value>`.

```bash
bw get item "Vault Unseal Keys + Root Token" 2>/dev/null | python3 -c "
import sys, json, subprocess
item = json.load(sys.stdin)
lines = [l.strip() for l in item['notes'].split('\n') if l.strip()]
keys = [l.split(':', 1)[1].strip() for l in lines if l.startswith('Unseal Key')]

for i, key in enumerate(keys[:3]):
    result = subprocess.run(
        ['kubectl', 'exec', '-n', 'irl', 'vault-0', '--', 'vault', 'operator', 'unseal', key],
        capture_output=True, text=True
    )
    sealed_line = [l for l in result.stdout.split('\n') if 'Sealed' in l]
    status = sealed_line[0].strip() if sealed_line else 'applied'
    print(f'Key {i+1}/3: {status}')
"
```

The script extracts only lines starting with "Unseal Key", takes the first 3, and applies them via kubectl. It never prints the key values -- only the seal status after each key.

### 4. Verify

```bash
kubectl exec -n irl vault-0 -- vault status 2>&1 | grep -E '(Sealed|Initialized)'
```

Confirm `Sealed: false`. If still sealed, something went wrong -- check that the Bitwarden item has the correct keys and that the Vault pod is running.

## Security Notes

- Never print, log, or echo the unseal key values
- Never print the root token
- The script pipes keys directly from Bitwarden to kubectl without intermediate storage
- Keys exist only in memory during the unseal process
