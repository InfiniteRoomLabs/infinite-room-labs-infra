"""Overlay networking tests: flannel binds to the tailnet.

The cluster is single-node: the cloud agent node was retired and the
KVM/libvirt VM nodes have not joined yet
(docs/plans/2026-08-27-k3s-to-vms-migration-design.md). Cross-node cases --
pod-to-pod across the overlay, DNS from a remote node, flannel on the far
side -- belong here again once a second node exists; until then there is no
second side to assert against.
"""

import subprocess

import pytest

from conftest import HOMELAB_TAILSCALE_IP


@pytest.mark.networking
@pytest.mark.integration
class TestOverlayNetworking:
    def test_flannel_homelab_uses_tailscale(self):
        """Flannel on homelab binds to the tailscale0 interface."""
        result = subprocess.run(
            ["ssh", "homelab-ts", "ip", "-d", "link", "show", "flannel.1"],
            capture_output=True, text=True, timeout=10,
        )
        assert f"local {HOMELAB_TAILSCALE_IP}" in result.stdout, (
            f"Flannel not using Tailscale IP. Output: {result.stdout}"
        )
        assert "dev tailscale0" in result.stdout
