"""Shared fixtures for IRL infrastructure acceptance tests."""

from pathlib import Path

import pytest
import requests
import dns.resolver
import yaml
from kubernetes import client, config

# Constants
HOMELAB_TAILSCALE_IP = "100.86.213.22"
DO_TAILSCALE_IP = "100.102.210.70"
COREDNS_IP = HOMELAB_TAILSCALE_IP
NAMESPACE = "irl"


@pytest.fixture(scope="session")
def k8s():
    """Kubernetes API client using default kubeconfig."""
    config.load_kube_config()
    return client.CoreV1Api()


@pytest.fixture(scope="session")
def k8s_apps():
    """Kubernetes Apps API client."""
    config.load_kube_config()
    return client.AppsV1Api()


@pytest.fixture(scope="session")
def k8s_custom():
    """Kubernetes Custom Objects API client."""
    config.load_kube_config()
    return client.CustomObjectsApi()


@pytest.fixture(scope="session")
def k8s_networking():
    """Kubernetes Networking API client."""
    config.load_kube_config()
    return client.NetworkingV1Api()


@pytest.fixture(scope="session")
def k8s_storage():
    """Kubernetes Storage API client."""
    config.load_kube_config()
    return client.StorageV1Api()


@pytest.fixture(scope="session")
def dns_resolver():
    """DNS resolver pointing at internal CoreDNS (port 53 on homelab)."""
    resolver = dns.resolver.Resolver()
    resolver.nameservers = [COREDNS_IP]
    resolver.port = 53
    resolver.lifetime = 5
    return resolver


@pytest.fixture(scope="session")
def https():
    """Requests session with TLS verification enabled (Let's Encrypt certs)."""
    session = requests.Session()
    session.verify = True
    session.timeout = 10
    return session


# Service definitions are DERIVED from irl_services (group_vars/all/main.yml)
# -- the registry is the single source of truth for service identity. Only
# test-side expectations (health endpoints, accepted HTTP statuses) live here.
REPO_ROOT = Path(__file__).resolve().parents[1]
BASE_DOMAIN = "lab.infiniteroomlabs.cloud"

HEALTH_OVERRIDES = {
    "gitea": {"health_path": "/api/v1/version"},
    "authentik": {"health_status": [200, 302]},
    "grafana": {"health_path": "/api/health"},
    "vault": {"health_path": "/v1/sys/health"},
    "prometheus": {"health_path": "/-/healthy"},
    "alertmanager": {"health_path": "/-/healthy"},
    "openviking": {"health_path": "/health"},
    "vaultwarden": {"health_status": [200, 302]},
    "nextcloud": {"health_status": [200, 302]},
    "paperless": {"health_status": [200, 302]},
    "firefly": {"health_status": [200, 302]},
    "ghostfolio": {"health_status": [200, 302]},
    "firefly-importer": {"health_status": [200, 302]},
}


def _load_services():
    gv = yaml.safe_load(
        (REPO_ROOT / "ansible/inventory/group_vars/all/main.yml").read_text()
    )
    services = {}
    for name, entry in gv["irl_services"].items():
        if entry.get("cluster_only"):
            continue  # no external route to test
        sub = entry["subdomain"]
        domain = (
            f"{sub}.internal.{BASE_DOMAIN}" if entry["internal"] else f"{sub}.{BASE_DOMAIN}"
        )
        svc = {
            "subdomain": sub,
            "domain": domain,
            "internal": entry["internal"],
            "health_path": entry.get("health_path", "/"),
            "health_status": 200,
        }
        svc.update(HEALTH_OVERRIDES.get(name, {}))
        services[name] = svc
    return services


SERVICES = _load_services()


@pytest.fixture(scope="session")
def services():
    """Service definitions dict."""
    return SERVICES
