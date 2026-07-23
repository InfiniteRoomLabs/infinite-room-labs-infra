"""Shape contracts for the irl_services registry (group_vars/all/main.yml).

The registry is the single declaration point for services; these tests keep
its shape trustworthy so everything derived from it can be trusted too.
"""

import pytest

pytestmark = pytest.mark.hygiene

REQUIRED = ("subdomain", "internal")
ROUTED_REQUIRED = ("cluster_svc", "cluster_port")


def test_required_keys(registry):
    for name, svc in registry.items():
        missing = [k for k in REQUIRED if k not in svc]
        assert not missing, f"{name}: missing required keys {missing}"
        if not svc.get("cluster_only"):
            missing = [k for k in ROUTED_REQUIRED if k not in svc]
            assert not missing, (
                f"{name}: routed service missing {missing} "
                "(or set cluster_only: true)"
            )


def test_subdomains_unique(registry):
    seen = {}
    for name, svc in registry.items():
        key = (svc["subdomain"], svc["internal"])
        assert key not in seen, (
            f"{name} and {seen[key]} both claim subdomain {svc['subdomain']!r} "
            f"(internal={svc['internal']})"
        )
        seen[key] = name
