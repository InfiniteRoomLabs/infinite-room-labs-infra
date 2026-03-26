"""Kubernetes resource state tests: Helm releases, PVs, secrets, NetworkPolicies."""

import subprocess
import json
import pytest
from conftest import NAMESPACE

EXPECTED_RELEASES = [
    "postgresql", "valkey", "vault", "gitea", "authentik",
    "monitoring", "ollama", "garage", "openviking", "coredns-internal",
]

EXPECTED_PVS = [
    "pv-garage-data", "pv-garage-meta", "pv-ollama-models",
    "pv-openviking-data", "pv-gitea-lfs", "pv-postgres-data",
    "pv-prometheus-data", "pv-loki-data", "pv-grafana-data",
    "pv-vault-data",
]

EXPECTED_SECRETS = [
    "garage-rpc-secret", "garage-admin-secret", "openviking-api-key",
]

EXPECTED_NETWORK_POLICIES = [
    "default-deny-all", "allow-intra-namespace", "allow-dns-egress",
]


@pytest.mark.acceptance
class TestHelmReleases:
    @pytest.fixture(scope="class")
    def helm_releases(self):
        result = subprocess.run(
            ["helm", "list", "-n", NAMESPACE, "-o", "json"],
            capture_output=True, text=True,
        )
        return json.loads(result.stdout)

    @pytest.mark.parametrize("release_name", EXPECTED_RELEASES)
    def test_release_deployed(self, helm_releases, release_name):
        release = next(
            (r for r in helm_releases if r["name"] == release_name), None
        )
        if release is None:
            pytest.skip(f"Release '{release_name}' not installed")
        assert release["status"] == "deployed", (
            f"{release_name}: status={release['status']}, expected deployed"
        )


@pytest.mark.acceptance
class TestPersistentVolumes:
    @pytest.mark.parametrize("pv_name", EXPECTED_PVS)
    def test_pv_exists(self, k8s, pv_name):
        pvs = k8s.list_persistent_volume().items
        pv = next((p for p in pvs if p.metadata.name == pv_name), None)
        assert pv is not None, f"PV '{pv_name}' does not exist"


@pytest.mark.acceptance
class TestSecrets:
    @pytest.mark.parametrize("secret_name", EXPECTED_SECRETS)
    def test_secret_exists(self, k8s, secret_name):
        secrets = k8s.list_namespaced_secret(NAMESPACE).items
        secret = next(
            (s for s in secrets if s.metadata.name == secret_name), None
        )
        assert secret is not None, f"Secret '{secret_name}' missing in {NAMESPACE}"


@pytest.mark.compliance
class TestNetworkPolicies:
    @pytest.mark.parametrize("policy_name", EXPECTED_NETWORK_POLICIES)
    def test_policy_exists(self, k8s_networking, policy_name):
        policies = k8s_networking.list_namespaced_network_policy(NAMESPACE).items
        policy = next(
            (p for p in policies if p.metadata.name == policy_name), None
        )
        assert policy is not None, (
            f"NetworkPolicy '{policy_name}' missing in {NAMESPACE}"
        )

    def test_configmap_coredns_zones(self, k8s):
        cms = k8s.list_namespaced_config_map(NAMESPACE).items
        cm = next(
            (c for c in cms if c.metadata.name == "coredns-internal-zones"), None
        )
        assert cm is not None, "ConfigMap 'coredns-internal-zones' missing"
        assert "lab.infiniteroomlabs.cloud.db" in cm.data, (
            "Zone file missing from ConfigMap"
        )
