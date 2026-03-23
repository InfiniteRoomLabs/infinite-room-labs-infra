"""Cross-node networking tests: flannel overlay via Tailscale."""

import subprocess
import json
import pytest
from conftest import NAMESPACE, HOMELAB_TAILSCALE_IP, DO_TAILSCALE_IP


@pytest.mark.networking
@pytest.mark.integration
class TestCrossNodeNetworking:
    def test_do_pod_can_resolve_dns(self):
        """A pod on the DO node can resolve services via CoreDNS on homelab."""
        result = subprocess.run(
            ["kubectl", "run", "test-dns-net", "--restart=Never",
             "--image=busybox", "-n", NAMESPACE,
             "--overrides", json.dumps({
                 "spec": {
                     "nodeSelector": {"irl.dev/provider": "digitalocean"},
                     "tolerations": [{"key": "irl.dev/cloud", "operator": "Equal",
                                      "value": "digitalocean", "effect": "NoSchedule"}],
                 }
             }),
             "--", "sh", "-c", "nslookup postgresql-rw 2>&1; echo EXIT=$?"],
            capture_output=True, text=True, timeout=30,
        )
        # Wait for pod to complete
        subprocess.run(
            ["kubectl", "wait", "--for=condition=Ready", "pod/test-dns-net",
             "-n", NAMESPACE, "--timeout=30s"],
            capture_output=True, timeout=35,
        )
        import time; time.sleep(10)
        logs = subprocess.run(
            ["kubectl", "logs", "test-dns-net", "-n", NAMESPACE],
            capture_output=True, text=True, timeout=10,
        )
        # Cleanup
        subprocess.run(
            ["kubectl", "delete", "pod", "test-dns-net", "-n", NAMESPACE,
             "--ignore-not-found"],
            capture_output=True, timeout=10,
        )
        assert "EXIT=0" in logs.stdout or "10.43" in logs.stdout, (
            f"DNS resolution failed from DO node: {logs.stdout}"
        )

    def test_flannel_homelab_uses_tailscale(self):
        """Flannel on homelab binds to tailscale0 interface."""
        result = subprocess.run(
            ["ssh", "homelab-ts", "ip", "-d", "link", "show", "flannel.1"],
            capture_output=True, text=True, timeout=10,
        )
        assert f"local {HOMELAB_TAILSCALE_IP}" in result.stdout, (
            f"Flannel not using Tailscale IP. Output: {result.stdout}"
        )
        assert "dev tailscale0" in result.stdout

    def test_flannel_do_uses_tailscale(self):
        """Flannel on DO binds to tailscale0 interface."""
        result = subprocess.run(
            ["ssh", "do-k3s", "ip", "-d", "link", "show", "flannel.1"],
            capture_output=True, text=True, timeout=10,
        )
        assert f"local {DO_TAILSCALE_IP}" in result.stdout, (
            f"Flannel not using Tailscale IP. Output: {result.stdout}"
        )
        assert "dev tailscale0" in result.stdout
