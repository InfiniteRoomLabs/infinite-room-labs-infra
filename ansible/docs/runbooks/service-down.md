# Runbook: Service Down

## Severity: MEDIUM (depends on service)

## Detection

- Health check script returns "unhealthy"
- Grafana alerts fire
- User reports service unreachable

## Assessment

```bash
# Run health check
/usr/local/bin/irl-health-check

# Check Docker status
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

# Check specific stack
cd /opt/irl/{stack}
sudo docker compose ps
sudo docker compose logs --tail=50
```

## Common Causes and Fixes

### Container exited
```bash
cd /opt/irl/{stack}
sudo docker compose up -d
sudo docker compose logs -f --tail=20
```

### Out of memory (OOM killed)
```bash
# Check for OOM events
dmesg | grep -i "oom\|killed"

# Check memory usage
docker stats --no-stream

# Increase limit in host_vars/homelab.yml, re-run playbook
```

### Database connection refused
```bash
# Check PostgreSQL health
docker exec irl-postgres pg_isready -U postgres

# If PG is down, restart data stack
cd /opt/irl/data
sudo docker compose restart postgres
```

### Caddy proxy error
```bash
# Check Caddy logs
sudo journalctl -u caddy --since "30 minutes ago"

# Verify upstream is listening
curl -I http://127.0.0.1:{port}

# Reload Caddy
sudo systemctl reload caddy
```

## Escalation

If service cannot be recovered after 15 minutes:
1. Check system resources (`htop`, `df -h`, `zpool status`)
2. Check recent changes (`git log` in infra repo)
3. Consider rolling back last Ansible change
