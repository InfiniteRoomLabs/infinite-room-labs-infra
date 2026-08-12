"""Fan-out contracts: everything a registry entry promises must exist.

Adding a service to irl_services obligates a deploy tag, secret mappings, a
homepage tile, and a runbook. These tests fail when any obligation is missing,
turning the deploy-new-service SOP from an honor system into a checked one.

The *_GAPS allowlists are ratchets: they may only shrink. A companion test
fails when an allowlisted gap has been fixed but not removed from the list.
"""

import pytest

pytestmark = pytest.mark.hygiene

# Services awaiting a dedicated <svc>-down.md runbook. WS3 of the ops-UX
# plan writes these and empties the list. Do not add entries.
RUNBOOK_GAPS = {
    "gitea",
    "authentik",
    "grafana",
    "vault",
    "prometheus",
    "alertmanager",
    "garage",
    "garage-s3",
    "homepage",
    "vaultwarden",
    "openviking",
    "nextcloud",
    "paperless",
    "firefly",
    "ghostfolio",
    "firefly-importer",
}

# Non-internal services missing a homepage tile. Fixed in WS3/WS4. Do not
# add entries; either add the tile or set `homepage: false` in the registry.
# (Every service here postdates the last real homepage tile update -- the
# exact drift this suite exists to catch.)
HOMEPAGE_GAPS = {
    "vaultwarden",
    "nextcloud",
    "firefly",
    "ghostfolio",
    "firefly-importer",
    "karakeep",
}

# ansible/helm/ dirs that are infrastructure, not registry services.
INFRA_HELM_DIRS = {
    "coredns",
    "external-secrets",
    "loki",
    "monitoring",
    "ollama",
    "postgres",
    "redis",
    "traefik",
}
# jenkins: paused service (commented out in the registry pending plugin fix)
PAUSED_HELM_DIRS = {"jenkins"}


def test_every_service_has_deploy_tag(registry, deploy_tags):
    """Each service must be deployable by tag: helm-deploy.yml needs a tag
    matching the registry key, or the entry declares `deploy_tag` for
    legitimate groupings (e.g. grafana -> monitoring)."""
    missing = {
        name: svc.get("deploy_tag", name)
        for name, svc in registry.items()
        if svc.get("deploy_tag", name) not in deploy_tags
    }
    assert not missing, (
        f"registry services with no matching helm-deploy.yml tag: {missing} "
        "-- add a tagged deploy block or a deploy_tag field"
    )


def test_existing_secrets_are_bw_synced(existing_secrets_by_dir, bw_sync_k8s_secrets):
    """Every existingSecret a chart values file references must be created by
    bw-sync (scripts/bw-sync-config.yaml) -- otherwise the pod can never start
    on a fresh cluster."""
    # Secrets created by playbooks rather than bw-sync (documented exceptions).
    playbook_created = {
        "postgres-superuser",  # k8s-secrets.yml bootstrap
    }
    known = bw_sync_k8s_secrets | playbook_created
    unmapped = {
        d: sorted(s - known)
        for d, s in existing_secrets_by_dir.items()
        if s - known
    }
    assert not unmapped, (
        f"existingSecret refs with no bw-sync-config.yaml mapping: {unmapped}"
    )


def test_noninternal_services_have_homepage_tile(registry, homepage_text):
    missing = []
    for name, svc in registry.items():
        if (
            svc.get("internal")
            or svc.get("cluster_only")
            or svc.get("homepage") is False
            or name == "homepage"
            or name in HOMEPAGE_GAPS
        ):
            continue
        url = f"https://{svc['subdomain']}.lab.infiniteroomlabs.cloud"
        if url not in homepage_text:
            missing.append(f"{name} ({url})")
    assert not missing, (
        f"non-internal services without a homepage tile: {missing} "
        "-- add a tile in ansible/helm/homepage/values.yaml or set homepage: false"
    )


def test_every_service_has_runbook(registry, repo_root):
    missing = [
        name
        for name in registry
        if name not in RUNBOOK_GAPS
        and not (repo_root / f"ansible/docs/runbooks/{name}-down.md").exists()
    ]
    assert not missing, (
        f"services without a <svc>-down.md runbook: {missing} "
        "-- write one in ansible/docs/runbooks/"
    )


def test_helm_dirs_map_to_registry(registry, helm_values_dirs):
    known = set(registry) | INFRA_HELM_DIRS | PAUSED_HELM_DIRS
    unknown = sorted(set(helm_values_dirs) - known)
    assert not unknown, (
        f"ansible/helm/ dirs with no registry entry or allowlist: {unknown}"
    )


def test_gap_allowlists_only_shrink(registry, repo_root, homepage_text):
    """Ratchet: entries in the GAP allowlists must still be real gaps.
    When a gap is fixed, remove it here so it can never regress."""
    stale = [
        name
        for name in RUNBOOK_GAPS
        if (repo_root / f"ansible/docs/runbooks/{name}-down.md").exists()
    ]
    assert not stale, f"runbooks exist now -- remove from RUNBOOK_GAPS: {stale}"

    stale = [
        name
        for name in HOMEPAGE_GAPS
        if f"https://{registry[name]['subdomain']}.lab.infiniteroomlabs.cloud"
        in homepage_text
    ]
    assert not stale, f"tiles exist now -- remove from HOMEPAGE_GAPS: {stale}"
