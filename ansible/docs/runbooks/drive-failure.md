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

## Pool compatibility (read before any rescue-boot)

`zpool upgrade main` was run on 2026-09-14 after the host moved to Debian 13
(OpenZFS 2.3.9). Feature flags now enabled include `raidz_expansion`,
`block_cloning`, `head_errlog`, `fast_dedup`, `draid`, `blake3`, `longname`,
`large_microzap`, `zilsaxattr`, `vdev_zaps_v2`, `redaction_list_spill`.

Consequences:

- The pool imports read-write only on OpenZFS 2.3 or newer. A rescue USB
  built on Debian 12 (2.1.x) or older Ubuntu LTS will not import it. Use a
  Debian 13 live image or any distro shipping OpenZFS >= 2.3.
- Growing `raidz1-0` in place is now possible with `zpool attach main raidz1-0
  <disk>` (the new disk must be at least 8TB, the size of the existing
  members). Expansion is online; expect 1-2 days for the reflow.
- `dedup=off` is asserted by `playbooks/zfs.yml`. The legacy dedup table
  (85M entries as of 2026-09-14) only shrinks as old blocks are freed or
  rewritten; `zfs rewrite` on a dataset drains its share.
