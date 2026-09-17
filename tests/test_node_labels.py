"""Node label taxonomy and scheduling compliance tests.

Single-node topology: the cloud agent node was retired, so only the homelab
node's labels are asserted here. The agent-side taxonomy (provider, tier,
cost, persistence, and the scheduling taint that goes with it) returns when
the KVM/libvirt VM nodes join -- see
docs/plans/2026-08-27-k3s-to-vms-migration-design.md.
"""

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

HOMELAB_SERVICES = ["postgresql", "valkey", "vault", "garage", "openviking", "ollama"]


@pytest.mark.compliance
class TestHomelabLabels:
    @pytest.mark.parametrize("key,value", list(HOMELAB_EXPECTED_LABELS.items()))
    def test_label(self, k8s, key, value):
        node = k8s.read_node("home")
        actual = node.metadata.labels.get(key)
        assert actual == value, f"home: {key}={actual}, expected {value}"


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
