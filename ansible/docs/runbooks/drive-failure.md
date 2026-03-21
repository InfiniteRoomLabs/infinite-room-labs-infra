# Runbook: Drive Failure

## Severity: HIGH

## Detection

- ZFS scrub reports errors
- SMART test failures (smartmontools alerts)
- `zpool status` shows DEGRADED

## Assessment

```bash
# Check pool status
sudo zpool status main

# Check SMART health for all drives
sudo smartctl -H /dev/sdb
sudo smartctl -H /dev/sdc
sudo smartctl -H /dev/sdd

# Check for reallocated sectors
sudo smartctl -a /dev/sdX | grep -i "reallocated\|pending\|uncorrectable"
```

## Response

### If RAIDZ1 is DEGRADED (one drive failing)

1. **Order replacement drive immediately** -- RAIDZ1 has zero redundancy remaining
2. Data is still accessible but a second failure means total loss
3. **Create emergency backup** of critical service data:
   ```bash
   docker exec irl-postgres pg_dumpall -U postgres > /tmp/emergency-pg-dump.sql
   ```
4. When replacement arrives:
   ```bash
   sudo zpool replace main /dev/sdX /dev/sdY
   sudo zpool status  # Monitor resilver progress
   ```

### If boot SSD fails

1. Boot SSD has NO redundancy
2. All services go down, ZFS data survives
3. Reinstall Debian on new SSD
4. Re-run Ansible: `./run-ansible.sh playbook site.yml`
5. ZFS pool auto-imports on reboot

## Prevention

- Weekly scrubs (automated via cron)
- Monitor SMART status in Grafana
- Consider upgrading to RAIDZ2 when adding drives
