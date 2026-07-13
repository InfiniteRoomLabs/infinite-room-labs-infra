# Deploy Karakeep to homelab k3s (Tailscale-only)

> Sister plan to `2026-07-10-karakeep-tailscale-only-deployment.md`, drafted independently (without reading it) for comparison.

## Context

Karakeep (bookmark manager, ex-Hoarder) joins the homelab. Upstream's k8s docs are raw kustomize manifests, but an **official Helm chart exists** (`karakeep-app/helm-charts`, bjw-s-based) -- so we follow the exact Firefly/Ghostfolio pattern: upstream chart deployed via `ansible/playbooks/helm-deploy.yml`, values override in `ansible/helm/karakeep/values.yaml`, secrets from Bitwarden via bw-sync, Traefik IngressRoute + CoreDNS split-DNS record.

**Tailscale-only is free**: `*.lab.infiniteroomlabs.cloud` only resolves via Tailscale Split DNS -> internal CoreDNS -> Traefik, with no public port-forward. Adding karakeep to the existing dicts inherits that posture. No new Tailscale work needed.

**Architecture** (all from the one chart): karakeep web StatefulSet (SQLite on PVC, port 3000) + headless Chrome (screenshots/crawling) + Meilisearch subchart (search). No Postgres/Valkey needed.

**Critical gotcha**: the chart auto-generates `NEXTAUTH_SECRET` and `MEILI_MASTER_KEY` with `randAlphaNum` **on every upgrade** if not pinned -- that invalidates sessions and breaks Meilisearch auth. So we disable chart-generated secrets and supply a Bitwarden-backed k8s Secret, same rationale as the Ghostfolio `ACCESS_TOKEN_SALT` comment in `ansible/helm/ghostfolio/values.yaml:35-39`.

## Changes (6 files, all mirroring the Ghostfolio precedent)

### 1. Bitwarden items (manual/CLI, source of truth)

Two new items under `IRL/Services/`:

- `karakeep-nextauth-secret` (generate: `openssl rand -base64 36`)
- `karakeep-meili-master-key` (same)

### 2. `scripts/bw-sync-config.yaml`

```yaml
# ── Karakeep (bookmarks) ────────────────────────────────────
- bw_item: "karakeep-nextauth-secret"
  ansible_var: "vault_karakeep_nextauth_secret"
  k8s_secret: "karakeep-secrets"
  k8s_key: "NEXTAUTH_SECRET"
- bw_item: "karakeep-meili-master-key"
  ansible_var: "vault_karakeep_meili_master_key"
  k8s_secret: "karakeep-secrets"
  k8s_key: "MEILI_MASTER_KEY"
```

### 3. `ansible/playbooks/k8s-secrets.yml`

Add a `karakeep-secrets` task cloned from the Ghostfolio block (`k8s-secrets.yml:292-307`): one Secret, keys `NEXTAUTH_SECRET` + `MEILI_MASTER_KEY`, `no_log`, `when: vault_karakeep_nextauth_secret is defined`. Update the summary debug msg.

### 4. `ansible/inventory/group_vars/all/main.yml`

```yaml
# in irl_services (drives CoreDNS zone + health check):
karakeep:
  subdomain: "bookmarks"
  internal: false
  cluster_svc: "karakeep"
  cluster_port: 3000

# in irl_traefik_standalone_services (drives IngressRoute):
karakeep:
  subdomain: "bookmarks"
  domain: "{{ irl_public_domain }}"
  cluster_svc: "karakeep"
  cluster_port: 3000
```

### 5. `ansible/helm/karakeep/values.yaml` (new)

```yaml
# Karakeep -- bookmarks/read-later. Official chart (bjw-s library base).
# SQLite on PVC; Meilisearch + headless Chrome bundled. No Postgres.
fullnameOverride: karakeep
applicationProtocol: https
applicationHost: bookmarks.lab.infiniteroomlabs.cloud

# NEXTAUTH_SECRET + MEILI_MASTER_KEY come from our K8s Secret (karakeep-secrets,
# Bitwarden-backed), never chart-generated: the chart's randAlphaNum default
# re-rolls on every upgrade, killing sessions and Meilisearch auth.
secrets:
  karakeep:
    enabled: false
  meilesearch:          # sic -- chart's own typo, must match
    enabled: false

controllers:
  karakeep:
    containers:
      karakeep:
        envFrom:
          - secretRef:
              name: karakeep-secrets
    statefulset:
      volumeClaimTemplates:
        - name: data
          accessMode: ReadWriteOnce
          size: 10Gi          # screenshots + page archives grow; chart default 2Gi
          globalMounts:
            - path: /data

meilisearch:
  auth:
    existingMasterKeySecret: karakeep-secrets   # key MEILI_MASTER_KEY
  environment:
    MEILI_ENV: production
  persistence:
    enabled: true
    size: 2Gi

service:
  karakeep:
    controller: karakeep
    ports:
      http:
        port: 3000

ingress:
  karakeep:
    enabled: false      # routed by Traefik IngressRoute (standalone svc)
```

### 6. `ansible/playbooks/helm-deploy.yml`

- Add `karakeep` to the valid tags list (~line 52).
- Add helm repo: `{ name: karakeep-app, url: "https://karakeep-app.github.io/helm-charts" }`.
- Add Phase 3 block cloned from Ghostfolio (`helm-deploy.yml:871-894`): template values -> `kubernetes.core.helm` with `chart_ref: karakeep-app/karakeep`, release name `karakeep`, `tags: [phase3, karakeep]`. (No chart_version pin -- matches firefly/ghostfolio.)

## Deploy sequence

```bash
# 1. Create the two BW items, then:
mise run secrets:sync                    # vault.yml + k8s secrets
cd ansible/
uv run ansible-playbook playbooks/k8s-secrets.yml
uv run ansible-playbook playbooks/helm-deploy.yml --tags karakeep
uv run ansible-playbook playbooks/helm-deploy.yml --tags coredns,traefik   # DNS record + IngressRoute
```

## Verification

- `kubectl get pods -n irl | grep -E 'karakeep|meilisearch|chrome'` -- all Running
- `dig bookmarks.lab.infiniteroomlabs.cloud` from laptop (Tailscale) resolves; from a non-Tailscale network it must NOT resolve
- `curl -s https://bookmarks.lab.infiniteroomlabs.cloud/api/health` -> healthy
- In the UI: sign up, add a bookmark -> screenshot renders (proves Chrome), search finds it (proves Meilisearch + master key)
- `helm upgrade` idempotency: rerun `--tags karakeep`, confirm you're still logged in (proves secrets aren't re-rolled)

## Skipped (add later if wanted)

- **AI tagging via in-cluster Ollama**: 3 env vars in values (`OLLAMA_BASE_URL: http://ollama:11434`, `INFERENCE_TEXT_MODEL: llama3.2`) -- works, but scope-creep for the first deploy.
- Homepage tile, Prometheus scrape, Authentik OIDC -- none of the peer apps (firefly/ghostfolio) have them wired yet either.
