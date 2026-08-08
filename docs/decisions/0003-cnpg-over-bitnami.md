# 0003. CloudNativePG operator over Bitnami postgresql chart

Date: 2026-03-20

## Status

Accepted

## Context

The homelab k3s deployment originally consumed the Bitnami `postgresql` chart (and Bitnami `redis`), with environment overrides in `ansible/helm/postgres/values.yaml` written against the Bitnami values API (`auth.existingSecret`, `primary.extendedConfiguration`, NodePort service).

In its 2025 catalog restructuring, Bitnami (under Broadcom) removed the versioned images these charts depended on from its maintained public catalog -- legacy tags moved to an unsupported namespace while maintained hardened images went subscription-only -- breaking both charts for us (`docs/plans/2026-03-20-homelab-k3s-helm-deployment.md`, Context section). Rather than patch individual charts, the decision was made to stand up an IRL-owned chart repository (`InfiniteRoomLabs/helm-charts`, consumed here as the `helm-charts/` submodule) and replace the broken dependencies with wrapper charts we control. The plan doc also frames the repo as an open-source contribution ("PostHog model").

For PostgreSQL specifically, the replacement candidates recorded in the plan's Decisions Log entry for 2026-03-20 were the CloudNativePG (CNPG) operator and Valkey for the Redis side, with the stated rationale: "Bitnami pulled all versioned images from Docker Hub (Broadcom paywall). CNPG is CNCF, Valkey is Linux Foundation." Foundation governance was the recorded hedge against a second single-vendor rug-pull. No performance benchmarks were run or claimed; this was a supply-chain and governance decision, not a performance one.

## Decision

Replace the Bitnami `postgresql` chart with `irl-postgres`, a thin wrapper chart around the CloudNativePG operator (`helm-charts/charts/irl-postgres/`, initial commit 8243f80, 2026-03-20):

- `Chart.yaml` declares a dependency on `cloudnative-pg` from `https://cloudnative-pg.github.io/charts`, pinned at 0.22.0 (`Chart.lock`), gated behind `operator.enabled`.
- The chart's own templates render a CNPG `Cluster` custom resource (`templates/cluster.yaml`) plus helpers, instead of templating StatefulSets directly.
- Images are official `ghcr.io/cloudnative-pg/postgresql:16`, explicitly "not Bitnami" (`values.yaml` header comment).
- Postgres tuning previously carried in Bitnami `extendedConfiguration` moved to CNPG `postgresql.parameters` (same values: `shared_buffers 512MB`, `effective_cache_size 1536MB`, `work_mem 16MB`, `max_connections 100`), with `scram-sha-256` auth and a `pg_hba` rule for the pod CIDR.
- `ansible/playbooks/helm-deploy.yml` installs the operator separately (`cnpg-operator` release in `cnpg-system`), deploys `irl/irl-postgres` with `operator.enabled: false`, `storageClass: local-path`, and NodePort 30432, then polls `kubectl get cluster` until "Cluster in healthy state".

## Consequences

- Supply-chain exposure to Bitnami/Broadcom is removed for PostgreSQL: images come from the CNCF project's GHCR registry, and the wrapper chart is ours to version (CHANGELOG 0.1.0: "Replaces deprecated Bitnami postgresql chart").
- CNPG manages its own superuser credentials; the external-secret pattern the Bitnami chart supported does not carry over. The chart's original Job-based database creation was broken and removed in v0.2.0 (CHANGELOG 2026-03-21); databases and roles are now created idempotently via `kubectl exec ... psql` tasks in `helm-deploy.yml`. Database provisioning therefore lives in Ansible, not Helm -- a deliberate split recorded in the Decisions Log ("CNPG manages its own superuser credentials", 2026-03-21).
- Consumers changed connection targets to CNPG's managed services: application charts point at `postgresql-rw` (e.g. the Authentik values override written by `helm-deploy.yml` sets `postgresql.host: postgresql-rw`). Downstream IRL wrapper charts (`irl-gitea`, `irl-vaultwarden`, `irl-paperless`) were built against "external CNPG PostgreSQL" and disable any bundled Bitnami subcharts (helm-charts CHANGELOG 0.3.0+).
- Operator lifecycle is now a deployment concern: the playbook installs the CNPG operator as its own Helm release before the cluster chart, and health-gating waits on the `Cluster` CR rather than on pod readiness.
- HA is a values change (`cluster.instances: 1` today, "3 for HA" per `values.yaml`), which the Bitnami chart's primary/replica model did not offer as cleanly; the homelab runs a single instance.
- Monitoring integrates via CNPG's PodMonitor (`cluster.monitoring.enabled: true`), consumed by the kube-prometheus-stack deployed in `irl-monitoring`.
- Known residue for reviewers:
  - `ansible/helm/postgres/values.yaml` is a stale Bitnami-era values file; the postgres deploy task uses inline values and the values-upload loop does not include a `postgres` directory, so the file is dead but still in-tree.
  - helm-charts CHANGELOG v0.2.0 claims "Bump CNPG dependency to 0.27.1", but `Chart.yaml`/`Chart.lock` still pin 0.22.0 (commit dd6b249 only bumped the wrapper chart version). The CHANGELOG entry overstates what shipped.

## Evidence

All claims above trace to in-repo artifacts; nothing is reconstructed from memory:

- `docs/plans/2026-03-20-homelab-k3s-helm-deployment.md` -- Context section (Bitnami/Broadcom trigger) and Decisions Log rows dated 2026-03-20 (Bitnami -> CNPG + Valkey) and 2026-03-21 (superuser credentials / kubectl-exec provisioning).
- `helm-charts/charts/irl-postgres/{Chart.yaml,Chart.lock,values.yaml,templates/cluster.yaml}` -- dependency pin, image source, tuning parameters, Cluster CR shape.
- helm-charts commits 8243f80 (2026-03-20, "Initial charts: irl-postgres (CNPG) and irl-valkey", commit body: "Replaces deprecated Bitnami PostgreSQL and Redis charts") and dd6b249; helm-charts `CHANGELOG.md` entries 0.1.0, 0.2.0, 0.3.0.
- `ansible/playbooks/helm-deploy.yml` -- operator install in `cnpg-system`, `irl/irl-postgres` deploy values, Cluster health wait, psql provisioning tasks, and the Authentik `postgresql-rw` consumer config.
- `ansible/helm/postgres/values.yaml` -- the stranded Bitnami-era values file.
