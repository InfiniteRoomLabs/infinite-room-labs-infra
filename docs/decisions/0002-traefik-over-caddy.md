# 0002. Traefik replaces the custom Caddy build as cluster ingress

Date: 2026-04-06 (design approved 2026-04-04, spec `docs/superpowers/specs/2026-04-04-caddy-to-traefik-migration-design.md`; cutover merged as PR #7, commit `c12d223`)

## Status

Accepted

## Context

Ingress for the homelab k3s cluster was a custom-built Caddy image, `irl-caddy:2.11.2-custom` (commit `dbb5412`, 2026-03-25): an xcaddy build adding `caddy-dns/cloudflare` for Let's Encrypt DNS-01 and `certmagic-s3` for S3-backed cert storage. It ran in-cluster with `hostNetwork: true`, configured through a single Ansible-templated `Caddyfile.j2`, with nftables output rules keyed on its UID as a compensating control for the NetworkPolicy bypass that hostNetwork implies (commit `0a8a6a2`).

The documented problems with that setup (design spec, "Motivation" section):

- Caddy is HTTP-only at Layer 7 here. It could not proxy raw TCP, so Gitea SSH required `kubectl port-forward` (the `gitea-connect`/`gitea-disconnect` fish functions). The `caddy-l4` plugin was evaluated and rejected at build time as "too immature for production use" at v0.1.0 (commit `dbb5412`).
- Routing lived in one centralized Ansible template rather than with the services being routed.
- The custom image meant an xcaddy build, manual `k3s ctr images import`, and a rebuild on every Caddy or plugin bump.

## Decision

Replace Caddy with Traefik v3, deployed from the upstream `traefik/traefik` Helm chart via the existing Ansible pipeline (`ansible/playbooks/helm-deploy.yml`, values in `ansible/helm/traefik/values.yaml`). Per the approved design:

- Same network model as Caddy: `hostNetwork: true`, entrypoints bound directly on the node -- `web` 80, `websecure` 443, `gitssh` 2222 (TCP for Gitea SSH).
- TLS via Let's Encrypt DNS-01 through Cloudflare, reusing the existing Bitwarden token item (`cloudflare-caddy-dns01-token`) synced to the renamed k8s secret `traefik-cloudflare-token` (commit `f02e5df`). ACME state on a 1Gi `local-path` PVC instead of S3.
- Routing via Traefik IngressRoute/IngressRouteTCP CRDs, co-located with the services: in the `irl-*` charts where one exists (gitea, monitoring, garage, openviking), and a single Jinja2 template (`ansible/templates/ingressroute-standalone.yaml.j2`) looping over `irl_traefik_standalone_services` for chartless services. CRD lock-in was accepted explicitly for a single-cluster homelab.
- Big-bang cutover after pre-validation on temporary ports 8080/8443 while Caddy still served production, with a documented scale-to-zero rollback (plan `docs/superpowers/plans/2026-04-04-caddy-to-traefik-migration.md`, Tasks 10-11).

Caddy was fully removed at cutover: `Caddyfile.j2`, `docker/caddy/Dockerfile`, and the `irl-caddy` chart deleted; `caddy_proxy` fields stripped from `irl_services` (commits `de24a73`, `09a33ba`).

## Consequences

Positive, verified in-repo:

- Gitea SSH is plain `ssh` to port 2222 through Traefik's TCP entrypoint; the port-forward workflow is retired (the old fish functions are documented as obsolete).
- No custom image or build step. The stock chart also brought zero-code-change capabilities later switched on in values.yaml alone: native Prometheus metrics and OTel tracing for all HTTP requests (commit `3003c50`), plus a Traefik ingress Grafana dashboard (`cc15d75`).
- Route definitions live with their services; adding a routed service is a chart template or one dict entry, exercised by every service added since (karakeep, paperless, firefly, ghostfolio per CHANGELOG).
- Test coverage carried over and widened: `test_caddy.py` was replaced by `test_ingress.py` asserting the same TLS/health behavior across all 16 routed services (derived from the 17-entry `irl_services` registry; `cluster_only` entries are excluded by `tests/conftest.py`), and the dead goss `caddy-pod-running` check (silently collapsed by a duplicate YAML key) was replaced by a working `traefik-pod-running` check (commit `3cb8fb4`).

Negative and costs, also verified in-repo:

- Security regression: the stock Traefik binary lacks setcap file capabilities, so `NET_BIND_SERVICE` alone could not bind 80/443; Traefik runs as root and the UID-keyed nftables output allowlist that constrained Caddy was removed (commit `b69572b`). `TODO.md` carries the follow-up: build a custom Traefik image with setcap to restore non-root operation (commit `de24a73`) -- which partially re-creates the custom-image burden this migration removed.
- hostNetwork port collisions surfaced immediately: Traefik's default dashboard port 8080 collided with CoreDNS and metrics 9100 with node_exporter; both were relocated (9000/9101, commit `9d1e28c`).
- hostNetwork breaks ClusterIP-based ServiceMonitor scraping; Traefik metrics are scraped via the Tailscale IP through `additionalScrapeConfigs` instead (`ansible/helm/traefik/values.yaml`, commit `cc15d75`).
- Chronic operational papercut for three months: the chart-default `LoadBalancer` Service never gets an external IP on this k3s (no LB provider), so every `helm --wait` on Traefik hung to timeout (revisions 13/14/16/18). Fixed 2026-07-13 by forcing `service.type: ClusterIP` and pinning `chart_version: 39.0.7` -- the previously unpinned chart floated to newer versions whose values schema rejects our top-level `logs` key (commit `0ba0464`, CHANGELOG "Traefik helm deploys no longer time out"). The 40+ chart upgrade remains a deferred task.
- The migration deliberately kept the `irl_services` dict for DNS (ExternalDNS would need an etcd backend for CoreDNS); DNS and routing therefore remain two separate declaration points, later hardened by the hygiene test suite (`3cb8fb4`).

Net: the cluster gained Kubernetes-native, multi-protocol ingress with no custom image at the cost of a root-running edge proxy pending the setcap image, and a set of hostNetwork/chart-default sharp edges that took until July 2026 to fully sand down.
