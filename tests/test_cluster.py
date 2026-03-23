"""Cluster-level smoke tests: nodes, namespace, pod health."""

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

    def test_do_node_ready(self, k8s):
        nodes = k8s.list_node().items
        do_node = next((n for n in nodes if n.metadata.name == "do-k3s-agent-01"), None)
        assert do_node is not None, "DO node 'do-k3s-agent-01' not found"
        ready = next(c for c in do_node.status.conditions if c.type == "Ready")
        assert ready.status == "True", f"DO node not Ready: {ready.message}"

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
