"""Node label taxonomy and scheduling compliance tests."""

import pytest
from conftest import NAMESPACE

HOMELAB_EXPECTED_LABELS = {
    "topology.kubernetes.io/region": "us-east",
    "topology.kubernetes.io/zone": "homelab",
    "irl.dev/provider": "homelab",
    "irl.dev/tier": "data",
    "irl.dev/instance-type": "hp-z600",
    "irl.dev/storage": "zfs",
    "irl.dev/network": "lan",
    "irl.dev/cost": "owned",
    "irl.dev/persistence": "permanent",
    "irl.dev/gpu": "none",
    "irl.dev/memory-class": "high",
}

DO_EXPECTED_LABELS = {
    "topology.kubernetes.io/region": "us-east",
    "topology.kubernetes.io/zone": "do-nyc3",
    "irl.dev/provider": "digitalocean",
    "irl.dev/tier": "compute",
    "irl.dev/instance-type": "s-4vcpu-8gb",
    "irl.dev/storage": "nvme",
    "irl.dev/network": "tailscale",
    "irl.dev/cost": "paid",
    "irl.dev/persistence": "ephemeral",
    "irl.dev/gpu": "none",
    "irl.dev/memory-class": "standard",
}

HOMELAB_SERVICES = ["postgresql", "valkey", "vault", "garage", "openviking", "ollama"]


@pytest.mark.compliance
class TestHomelabLabels:
    @pytest.mark.parametrize("key,value", list(HOMELAB_EXPECTED_LABELS.items()))
    def test_label(self, k8s, key, value):
        node = k8s.read_node("home")
        actual = node.metadata.labels.get(key)
        assert actual == value, f"home: {key}={actual}, expected {value}"


@pytest.mark.compliance
class TestDOLabels:
    @pytest.mark.parametrize("key,value", list(DO_EXPECTED_LABELS.items()))
    def test_label(self, k8s, key, value):
        node = k8s.read_node("do-k3s-agent-01")
        actual = node.metadata.labels.get(key)
        assert actual == value, f"do-k3s-agent-01: {key}={actual}, expected {value}"

    def test_taint(self, k8s):
        node = k8s.read_node("do-k3s-agent-01")
        taints = node.spec.taints or []
        cloud_taint = next(
            (t for t in taints if t.key == "irl.dev/cloud"), None
        )
        assert cloud_taint is not None, "Missing taint irl.dev/cloud"
        assert cloud_taint.value == "digitalocean"
        assert cloud_taint.effect == "NoSchedule"


@pytest.mark.compliance
class TestSchedulingCompliance:
    def test_data_tier_on_homelab(self, k8s):
        """Data-tier services stay on the homelab node."""
        for svc_label in HOMELAB_SERVICES:
            pods = k8s.list_namespaced_pod(
                NAMESPACE, label_selector=f"app.kubernetes.io/name={svc_label}"
            ).items
            for pod in pods:
                if pod.status.phase == "Running":
                    assert pod.spec.node_name == "home", (
                        f"{svc_label} pod {pod.metadata.name} on {pod.spec.node_name}, expected home"
                    )
