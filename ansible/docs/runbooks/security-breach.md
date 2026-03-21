# Runbook: Security Breach

## Severity: CRITICAL

## Detection

- Unexpected processes or containers running
- Unknown SSH sessions (`who`, `last`)
- Firewall rules modified
- Docker TCP re-exposed
- Unknown users or SSH keys

## Immediate Response

### 1. Isolate (first 5 minutes)

```bash
# Block all network except your SSH session
sudo nft flush ruleset
sudo nft add table inet emergency
sudo nft add chain inet emergency input '{ type filter hook input priority 0; policy drop; }'
sudo nft add rule inet emergency input ct state established,related accept
sudo nft add rule inet emergency input tcp dport 22 accept
sudo nft add rule inet emergency input iif lo accept
```

### 2. Assess

```bash
# Active sessions
who -a
last -20

# Running processes (look for anomalies)
ps auxf

# Network connections
ss -tlnp
ss -tnp

# Docker containers (should only be irl-* prefixed)
docker ps -a

# Check for unauthorized SSH keys
cat /home/wes/.ssh/authorized_keys
cat /root/.ssh/authorized_keys

# Check crontabs
crontab -l
crontab -l -u wes
ls -la /etc/cron.d/
```

### 3. Contain

```bash
# Kill unauthorized sessions
sudo pkill -u {compromised_user}

# Rotate SSH keys (generate new key on laptop, update server)
# Rotate all database passwords
# Rotate Vault unseal keys if compromised
```

### 4. Recover

1. Restore firewall: `./run-ansible.sh playbook playbooks/security-hardening.yml`
2. Rotate all credentials: update vault.yml, re-run affected playbooks
3. Rebuild compromised containers from scratch
4. Review all changes since last known good state

### 5. Post-incident

- Document what happened, how it was detected, what was affected
- Review logs for timeline
- Add monitoring/alerting to detect similar events
- Update firewall rules if new vectors found
