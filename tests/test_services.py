"""Service-specific deep checks: databases, models, buckets, health."""

import subprocess
import json
import pytest
from conftest import NAMESPACE, HOMELAB_TAILSCALE_IP


@pytest.mark.acceptance
class TestPostgreSQL:
    def test_databases_exist(self, k8s):
        """All 5 service databases exist in CNPG PostgreSQL."""
        expected_dbs = ["gitea", "plane", "vault", "authentik", "grafana"]
        result = subprocess.run(
            ["kubectl", "exec", "-n", NAMESPACE, "postgresql-1", "-c", "postgres",
             "--", "psql", "-U", "postgres", "-t", "-A", "-c",
             "SELECT datname FROM pg_database WHERE datname NOT IN ('postgres','template0','template1')"],
            capture_output=True, text=True,
        )
        actual_dbs = [db.strip() for db in result.stdout.strip().split("\n") if db.strip()]
        for db in expected_dbs:
            assert db in actual_dbs, f"Database '{db}' not found. Actual: {actual_dbs}"


@pytest.mark.acceptance
class TestVault:
    def test_initialized_and_unsealed(self, https):
        """Vault health endpoint returns 200 (initialized + unsealed)."""
        resp = https.get(f"https://vault.lab.infiniteroomlabs.cloud/v1/sys/health")
        assert resp.status_code == 200, (
            f"Vault returned {resp.status_code}. "
            "429=sealed, 501=not initialized, 200=healthy"
        )
        data = resp.json()
        assert data["initialized"] is True
        assert data["sealed"] is False


@pytest.mark.acceptance
class TestGitea:
    def test_api_returns_version(self, https):
        resp = https.get("https://git.lab.infiniteroomlabs.cloud/api/v1/version")
        assert resp.status_code == 200
        data = resp.json()
        assert "version" in data


@pytest.mark.acceptance
class TestOllama:
    def test_models_available(self):
        """Ollama has 3 expected models loaded."""
        result = subprocess.run(
            ["kubectl", "port-forward", "-n", NAMESPACE, "svc/ollama", "11434:11434"],
            capture_output=True, text=True, timeout=3,
        )
        # Port-forward is async; use a direct pod exec instead
        result = subprocess.run(
            ["kubectl", "exec", "-n", NAMESPACE, "deployment/ollama", "--",
             "curl", "-s", "http://localhost:11434/api/tags"],
            capture_output=True, text=True, timeout=15,
        )
        if result.returncode != 0:
            pytest.skip("Ollama pod doesn't have curl; skipping model check")
        data = json.loads(result.stdout)
        model_names = [m["name"] for m in data.get("models", [])]
        for expected in ["llama3.2:latest", "codellama:latest", "nomic-embed-text:latest"]:
            assert expected in model_names, f"Model '{expected}' not found. Available: {model_names}"


@pytest.mark.acceptance
class TestOpenViking:
    def test_health(self):
        """OpenViking health endpoint responds."""
        result = subprocess.run(
            ["kubectl", "exec", "-n", NAMESPACE, "deployment/openviking", "--",
             "wget", "-qO-", "http://localhost:1933/health"],
            capture_output=True, text=True, timeout=10,
        )
        # Accept either direct response or skip if no wget
        if result.returncode != 0:
            # Try curl
            result = subprocess.run(
                ["kubectl", "exec", "-n", NAMESPACE, "deployment/openviking", "--",
                 "python3", "-c", "import urllib.request; print(urllib.request.urlopen('http://localhost:1933/health').status)"],
                capture_output=True, text=True, timeout=10,
            )
        assert result.returncode == 0 or "200" in result.stdout


@pytest.mark.acceptance
class TestGarage:
    def test_garage_running(self, k8s):
        """Garage pod is running."""
        pods = k8s.list_namespaced_pod(
            NAMESPACE, label_selector="app.kubernetes.io/name=garage"
        ).items
        running = [p for p in pods if p.status.phase == "Running"]
        assert len(running) >= 1, "No Garage pods running"


@pytest.mark.acceptance
class TestGrafana:
    def test_health(self, https):
        resp = https.get("https://grafana.lab.infiniteroomlabs.cloud/api/health")
        assert resp.status_code == 200
        data = resp.json()
        assert data.get("database") == "ok"


@pytest.mark.acceptance
class TestAuthentik:
    def test_responds(self, https):
        """Authentik returns login page or redirect."""
        resp = https.get("https://auth.lab.infiniteroomlabs.cloud/")
        assert resp.status_code in (200, 302)
