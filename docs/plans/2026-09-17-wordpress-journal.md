# WordPress journal on k3s, tailnet-only

Date: 2026-09-17. Status: implementing (branch `feat/wordpress-journal`).

## Goal

A single WordPress site at `journal.lab.infiniteroomlabs.cloud`, reachable only over the tailnet, deployed the same way every other service in the `irl` namespace is: an IRL Helm chart, ZFS-backed static claims, secrets from the Bitwarden -> bw-sync lane, routing by Traefik IngressRoute.

## Chart choice

Three options were weighed before writing anything:

- **Bitnami `wordpress`** -- the obvious default, and the wrong one now. Bitnami's community images moved to the `bitnamilegacy` repository in August 2025 and receive no further updates; using the chart today means pinning frozen images (and a frozen bundled MariaDB) or buying Bitnami Secure Images. That is the opposite of this repo's supply-chain posture, and renovate would have nothing useful to bump.
- **Two `bjw-s/app-template` releases** (app + database) -- no new IRL chart to maintain, but the IngressRoute and the app<->DB coupling would live as two loosely related values files instead of one chart, and app-template values for a stateful database get verbose fast.
- **A new `irl-wordpress` chart** -- chosen. It is the irl-wotlk shape exactly: official upstream image plus a small single-replica database StatefulSet the app owns, external claims, chart-owned route. Both images (`wordpress`, `mariadb`) are official Docker library images with plain version tags, which renovate already knows how to bump in `helm-charts` values.

## Design

- **Database**: MariaDB 11.8 (LTS) StatefulSet inside the chart. WordPress core speaks MySQL/MariaDB only, so the cluster's CloudNativePG instance is not a candidate; this is the second app-owned SQL database in the cluster after WotLK's MySQL. Server charset/collation is forced to `utf8mb4` / `utf8mb4_unicode_ci` on the command line rather than left to the image default.
- **Exposure**: ClusterIP + a chart-owned IngressRoute on Traefik's `websecure` entrypoint with `certResolver: letsencrypt`. The existing wildcard (`*.lab.infiniteroomlabs.cloud`, DNS-01 via Cloudflare) already covers the host, so no new certificate work. Tailnet-only is a property of the name, not of a firewall rule: `journal.lab` exists only in the internal CoreDNS zone that Tailscale Split DNS serves, and Traefik binds the node's 80/443 which is only reachable over the tailnet or the LAN. No NodePort, no nftables entry.
- **Registry entry**: `irl_services.wordpress` (subdomain `journal`, `internal: false`, `cluster_svc: wordpress`, port 80). That single entry drives the CoreDNS record and the acceptance tests. It is deliberately NOT added to `irl_traefik_standalone_services` -- that list is for services whose chart does not own a route.
- **Storage**: ZFS datasets `main/wordpress-content` (20G) and `main/wordpress-db` (10G, recordsize 16K) as hostPath PVs on `zfs-local`. The content volume is mounted at `/var/www/html`, i.e. the whole install rather than just `wp-content`: the image only unpacks core when `index.php` is missing, so the volume is authoritative after first boot. Core auto-update is therefore disabled (`WP_AUTO_UPDATE_CORE => false`) and the image tag is the source of truth for the core version -- otherwise a self-update in wp-admin would silently outrank the pinned image, which a later image can never downgrade.
- **Secrets**: `wordpress-secrets` carries `MARIADB_ROOT_PASSWORD` and `MARIADB_PASSWORD` (bw-sync items `wordpress-db-root-password` / `wordpress-db-password`). The app gets the latter as `WORDPRESS_DB_PASSWORD`. WordPress's eight auth salts are NOT managed here: the image's entrypoint generates them once into `wp-config.php` on the PV, where they survive every `helm upgrade`. Chart-generated random secrets were explicitly avoided -- that is the re-roll trap the karakeep values document.
- **Behind the proxy**: `wp-config-docker.php` already promotes `X-Forwarded-Proto: https` to `$_SERVER['HTTPS']`, so TLS termination at Traefik is handled. `WP_HOME`/`WP_SITEURL` are pinned through `WORDPRESS_CONFIG_EXTRA` (eval'd per request, so it is live config, unlike the salts) to stop WordPress from serving links for whatever hostname it first saw.
- **Ordering**: a `wait-for-db` initContainer blocks on `mariadb-admin ping`, because WordPress does not retry a dead database -- it just renders "Error establishing a database connection". MariaDB itself carries a startup probe so first-boot datadir init cannot be killed by the liveness probe (the irl-wotlk 0.1.1 lesson).
- **Backups**: sanoid entries for both datasets on the `service_data` template (hourly 24 / daily 30 / weekly 4 / monthly 6). The DB snapshot is crash-consistent, not quiesced; InnoDB replays its redo log on restore.

Skipped on purpose: multisite, Redis/Valkey object cache (a single-author journal on this hardware does not need it), Authentik forward-auth in front of wp-login (WordPress owns its own auth and nothing else in the namespace uses forward-auth), and an off-site S3 backup CronJob. The last one is a real gap, not an oversight -- see below.

## Files

- `helm-charts/charts/irl-wordpress/` (chart 0.1.0)
- `ansible/helm/wordpress/values.yaml`, `ansible/playbooks/helm-deploy.yml` (phase3, tag `wordpress`), `ansible/playbooks/zfs.yml`, `ansible/playbooks/k3s.yml`, `ansible/inventory/group_vars/all/main.yml`, `ansible/files/sanoid/sanoid.conf`
- `scripts/bw-sync-config.yaml`
- `tests/conftest.py`, `tests/test_dns.py`
- `docs/homelab-access-guide.md`

## Follow-ups

All of the gaps this work opened were closed in the same branch:

- **Off-site backup** -- done in chart 0.2.1: a nightly CronJob writes
  `db/wordpress-db-<stamp>.sql.gz` (point-in-time `mariadb-dump`, pruned after
  30 days) and mirrors `wp-content/` with `aws s3 sync` (no `--delete`, never
  pruned) into the Garage bucket `wordpress-backups` (IAM key
  `wordpress-backup`, read+write, 50GiB quota). 0.2.0 tried to stream
  `tar | aws s3 cp -` and every run died on `tar: command not found` -- the
  `amazon/aws-cli` image has no tar, and the failure still left a 0-byte object
  that looked like a backup. Restore procedure is in the runbook.
- **NetworkPolicy drift** -- `allow-egress-internet` and
  `allow-ingress-tailscale` are now defined in `k3s.yml` (tag `netpol`).
  Applying them reported `ok`/`changed=0`, which is the proof that the
  codified YAML matches what was running.
- **`python3-kubernetes` drift** -- the homelab lost it in the Debian 13
  upgrade, so every `kubernetes.core` task failed. Both `k3s.yml` and
  `helm-deploy.yml` now install it (tag `always`).
- **Unpinned charts** -- every `kubernetes.core.helm` task now pins
  `chart_version` to what is deployed. An unpinned task drifts on any unrelated
  run (that is how coredns went 1.47.0 -> 1.47.1 during this work) and renovate
  can only raise upgrade PRs for pins.
- **`yq` unpinned** -- `bw-sync.sh` hard-requires it; it is now in `mise.toml`.
  That in turn exposed `IRL_SSH_PUBKEY`'s `exec()` template aborting the whole
  mise config when `~/.ssh/id_ed25519.pub` is absent, which had been silently
  skipping a hygiene test; the template now tolerates a missing key.
- **`bw get` ambiguity** -- `fnox.toml`'s `AWS_ACCESS_KEY_ID` matched two items
  (the sibling item's notes mention it by name), so it now references the
  Bitwarden item by UUID.

Still open:

- **Restore has not been rehearsed.** The backup runs and the objects are in the
  bucket, but nobody has restored from them yet. An untested backup is a rumour.
