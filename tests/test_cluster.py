"""Cluster-level smoke tests: nodes, namespace, pod health.

Single-node topology -- see
docs/plans/2026-08-27-k3s-to-vms-migration-design.md."""

import pytest
from conftest import NAMESPACE


@pytest.mark.smoke
class TestCluster:
    def test_homelab_node_ready(self, k8s):
        nodes = k8s.list_node().items
        homelab = next((n for n in nodes if n.metadata.name == "home"), None)
        assert homelab is not None, "Homelab node 'home' not found"
        ready = next(c for c in homelab.status.conditions if c.type == "Ready")
        assert ready.status == "True", f"Homelab node not Ready: {ready.message}"

    def test_no_unexpected_nodes(self, k8s):
        """The cluster is single-node. A second node showing up means either a
        VM agent joined (update this test and the label taxonomy) or something
        joined that should not have."""
        names = sorted(n.metadata.name for n in k8s.list_node().items)
        assert names == ["home"], f"expected a single node 'home', found {names}"

    def test_namespace_active(self, k8s):
        ns = k8s.read_namespace(NAMESPACE)
        assert ns.status.phase == "Active"

    def test_no_crashloops(self, k8s):
        pods = k8s.list_namespaced_pod(NAMESPACE).items
        crashloops = [
            p.metadata.name for p in pods
            if p.status.container_statuses
            for cs in (p.status.container_statuses or [])
            if cs.state.waiting and cs.state.waiting.reason == "CrashLoopBackOff"
        ]
        assert len(crashloops) == 0, f"Pods in CrashLoopBackOff: {crashloops}"

    def test_no_image_pull_errors(self, k8s):
        pods = k8s.list_namespaced_pod(NAMESPACE).items
        errors = [
            p.metadata.name for p in pods
            if p.status.container_statuses
            for cs in (p.status.container_statuses or [])
            if cs.state.waiting and cs.state.waiting.reason in ("ErrImagePull", "ImagePullBackOff")
        ]
        assert len(errors) == 0, f"Pods with image pull errors: {errors}"

    def test_cnpg_operator_running(self, k8s):
        pods = k8s.list_namespaced_pod("cnpg-system").items
        running = [p for p in pods if p.status.phase == "Running"]
        assert len(running) >= 1, "CNPG operator not running in cnpg-system"

    def test_storage_classes_exist(self, k8s_storage):
        scs = k8s_storage.list_storage_class().items
        names = [sc.metadata.name for sc in scs]
        assert "local-path" in names, "StorageClass 'local-path' missing"
        assert "zfs-local" in names, "StorageClass 'zfs-local' missing"
