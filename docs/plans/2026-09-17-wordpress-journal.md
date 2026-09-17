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

- **Off-site backup**: sanoid snapshots protect against deletion and bad edits, not against losing the pool. The paperless chart's nightly CronJob (export -> Garage S3 bucket -> prune older than N days) is the pattern to copy; for WordPress it would be `mariadb-dump` plus a tar of `wp-content`. Needs a `wordpress-backups` bucket and S3 credentials in Bitwarden.
- **Drift found while wiring this up**: the live cluster has `allow-egress-internet` and `allow-ingress-tailscale` NetworkPolicies in the `irl` namespace that exist in no playbook -- `k3s.yml` only codifies `default-deny-all`, `allow-intra-namespace`, `allow-dns-egress` and the per-service ones. WordPress depends on the first of those for plugin/theme installs from wp-admin. A rebuild from the repo alone would come up without them.
