"""Shared fixtures for IRL infrastructure acceptance tests."""

import pytest
import requests
import dns.resolver
from kubernetes import client, config
from urllib3.exceptions import InsecureRequestWarning

# Suppress TLS warnings for Caddy internal CA
requests.packages.urllib3.disable_warnings(InsecureRequestWarning)

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
    """Requests session with TLS verification disabled (Caddy internal CA)."""
    session = requests.Session()
    session.verify = False
    session.timeout = 10
    return session


# Service definitions -- mirrors irl_services from group_vars/all/main.yml
SERVICES = {
    "gitea": {
        "subdomain": "git",
        "domain": "git.lab.infiniteroomlabs.cloud",
        "port": 30300,
        "internal": False,
        "health_path": "/api/v1/version",
        "health_status": 200,
    },
    "authentik": {
        "subdomain": "auth",
        "domain": "auth.lab.infiniteroomlabs.cloud",
        "port": 30080,
        "internal": False,
        "health_path": "/",
        "health_status": [200, 302],
    },
    "grafana": {
        "subdomain": "grafana",
        "domain": "grafana.lab.infiniteroomlabs.cloud",
        "port": 30001,
        "internal": False,
        "health_path": "/api/health",
        "health_status": 200,
    },
    "vault": {
        "subdomain": "vault",
        "domain": "vault.lab.infiniteroomlabs.cloud",
        "port": 30200,
        "internal": False,
        "health_path": "/v1/sys/health",
        "health_status": 200,
    },
    "prometheus": {
        "subdomain": "metrics",
        "domain": "metrics.internal.lab.infiniteroomlabs.cloud",
        "port": 30090,
        "internal": True,
        "health_path": "/-/healthy",
        "health_status": 200,
    },
    "alertmanager": {
        "subdomain": "alerts",
        "domain": "alerts.internal.lab.infiniteroomlabs.cloud",
        "port": 30093,
        "internal": True,
        "health_path": "/-/healthy",
        "health_status": 200,
    },
    "garage": {
        "subdomain": "storage",
        "domain": "storage.internal.lab.infiniteroomlabs.cloud",
        "port": 30039,
        "internal": True,
        "health_path": "/",
        "health_status": 200,
    },
}


@pytest.fixture(scope="session")
def services():
    """Service definitions dict."""
    return SERVICES
