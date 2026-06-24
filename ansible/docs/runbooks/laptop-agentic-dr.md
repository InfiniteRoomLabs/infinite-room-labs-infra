# Runbook: Laptop Agentic Context -- Disaster Recovery

Rebuild the laptop-local agentic automation stack on a fresh or wiped machine.
The stack is three systemd `--user` timers plus the knowledge data they operate
on. All of it is version-controlled or backed up; this runbook is the order of
operations to get it running again.

## System inventory

| Component | What it does | Source of truth | Deployed to |
|-----------|--------------|-----------------|-------------|
| threadwatch | 5-hourly read-only `claude -p` scan of the archives -> `~/threadwatch/THREADWATCH.md` | GitHub `InfiniteRoomLabs/threadwatch` (pinned SHA) | `~/.local/share/threadwatch` |
| claudesync | hourly `claude.ai` export + git commit into the archive | units in Gitea `InfiniteRoomLabs/claude-ai-export` (`systemd/`, `scripts/`) | symlinked from `~/claude-ai-export` |
| knowledge-backup | 6-hourly Tailscale-gated rsync of the archives to the homelab | infra `ansible/files/laptop/` | `~/.local/bin` + `~/.config/systemd/user` |
| deploy driver | installs + enables all three | infra `ansible/playbooks/laptop.yml` | run with `uv run ansible-playbook` |

Data archives (the "knowledge"): `~/claude-ai-export`, `~/private-email-archive`,
`~/threadwatch`.

Backup location: homelab ZFS share `/media/root/storage1/nfs-share/laptop-knowledge-backup`,
reached from the laptop via the NFS automount at `/mnt/homelab-nfs` (fstab,
`100.86.213.22` over Tailscale).

## Prerequisites on a fresh laptop

1. Tailscale joined and up (`tailscale status`) -- needed for the homelab, NFS, and Gitea.
2. mise (node/pnpm/java), uv, fish, docker, git, rsync installed.
3. `claude` CLI installed and logged in on the subscription (OAuth) -- threadwatch rides this.
4. claudesync cookie broker working: a browser logged into claude.ai, and
   `sh ~/.local/share/claudesync/harvest-cookie.sh` prints `sessionKey=...`. The
   Docker image is digest-pinned; `docker pull deathnerd/claudesync@sha256:a59ee9617f395b558e1ed82ea117b8ae98ed677fd932912dc4c92ad6e30d85b1` if absent.
5. Bitwarden + fnox unlocked (`bw-unlock`) so the ansible vault password resolves.
6. git access: GitHub (threadwatch), Gitea over Tailscale (claude-ai-export, infra).

## Recovery procedure

### 1. Restore the data from the homelab backup

```bash
ls -l /mnt/homelab-nfs/laptop-knowledge-backup/LAST-BACKUP.txt   # check freshness
rsync -a /mnt/homelab-nfs/laptop-knowledge-backup/claude-ai-export/      ~/claude-ai-export/
rsync -a /mnt/homelab-nfs/laptop-knowledge-backup/private-email-archive/ ~/private-email-archive/
rsync -a /mnt/homelab-nfs/laptop-knowledge-backup/threadwatch/           ~/threadwatch/
```

Alternative (or in addition): re-clone `claude-ai-export` from Gitea and let the
hourly `claudesync` timer re-pull deltas. The backup is the fast path and also
holds `~/threadwatch` state and the email archive, which the git remotes may not.

### 2. Clone the infra repo

```bash
git clone git@git.lab.infiniteroomlabs.cloud:InfiniteRoomLabs/infinite-room-labs-infra.git
cd infinite-room-labs-infra/ansible && uv sync && uv run ansible-galaxy install -r requirements.yml
```

### 3. Re-establish auth (the fragile bits)

- `claude` CLI: log in on the subscription. (threadwatch exits `69/UNAVAILABLE` until this works.)
- claudesync cookie: log the browser into claude.ai; confirm `harvest-cookie.sh` returns a `sessionKey`.
- fnox/Bitwarden: `bw-unlock` so `uv run ansible-playbook` can read the vault password.

### 4. Re-deploy the timers

```bash
cd infinite-room-labs-infra/ansible
uv run ansible-playbook playbooks/laptop.yml
```

This clones + pins threadwatch, symlinks the claudesync units (needs `~/claude-ai-export`
present from step 1), installs knowledge-backup, and enables all three timers.

### 5. Verify

```bash
systemctl --user list-timers threadwatch.timer claudesync.timer knowledge-backup.timer
~/.local/share/threadwatch/smoke.sh --full        # threadwatch end-to-end (spends a little quota)
systemctl --user start claudesync.service         # one export + commit
systemctl --user start knowledge-backup.service   # one backup
journalctl --user -u threadwatch -u claudesync -u knowledge-backup -o cat -e
```

## Cadence reference

| Timer | Cadence | Fires at | Claude usage |
|-------|---------|----------|--------------|
| claudesync | hourly | `:00` | none (claude.ai pull) |
| threadwatch | every 5h | `:15` | one 5h usage window |
| knowledge-backup | every 6h | `:40` | none |

Staggered so each later job sees fresh output from the earlier one.

## Failure modes

| Symptom (journal) | Cause | Fix |
|-------------------|-------|-----|
| threadwatch `69/UNAVAILABLE` | `claude` OAuth session expired | re-login with `claude` |
| claudesync `sync_failed` | claude.ai cookie stale | re-login the browser into claude.ai |
| knowledge-backup `skipped` | Tailscale down / homelab unreachable | expected off-network; check `tailscale status` |
| knowledge-backup `error` rc 75 | NFS dest not writable | check the `/mnt/homelab-nfs` automount + Tailscale |

## Backup details

- Scope: `~/claude-ai-export`, `~/private-email-archive`, `~/threadwatch`
  (excludes `.venv`, `__pycache__`, caches, reindex runtime state).
- Append-only (no `--delete`): a local wipe can never propagate to the backup.
  Git history (in the repos) and ZFS snapshots (if sanoid covers the `nfs-share`
  dataset) are the point-in-time versioning layer.
- Freshness marker: `LAST-BACKUP.txt` in the backup root.
- Transport: rsync to the local NFS automount; the homelab squashes writes to
  uid/gid 1000 (`all_squash` on the Tailscale-range export).
