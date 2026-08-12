"""gunio-mcp exposure tests: public DNS, Access gating, and cluster state.

Covers the Cloudflare-fronted gunio-mcp deployment (chart/release
`irl-gunio-mcp`, namespace `gunio`, hostname gunio-mcp.infiniteroomlabs.com).
Unlike the other suites this targets PUBLIC infrastructure: DNS resolves via a
public resolver (the record is a proxied Cloudflare CNAME, not CoreDNS), and
the hostname must always answer with an Access gate, never an MCP response.

Every test SKIPS (not fails) while gunio is not yet rolled out, mirroring how
test_k8s_resources skips uninstalled releases: no public DNS record means the
tunnel-gunio terraform leaf has not been applied; a missing `gunio` namespace
means the chart has not been installed.
"""

import ipaddress

import dns.exception
import dns.resolver
import pytest
import requests
from kubernetes import client, config

GUNIO_HOSTNAME = "gunio-mcp.infiniteroomlabs.com"
GUNIO_NAMESPACE = "gunio"
GUNIO_DEPLOYMENT = "irl-gunio-mcp"
GUNIO_ESO_SECRETS = ["gunio-mcp-secrets", "gunio-cloudflared-token"]

# Cloudflare's published IPv4 edge ranges (https://www.cloudflare.com/ips-v4/).
# A proxied (orange-cloud) record answers from these -- resolving anywhere else
# means the record is grey-clouded or hijacked.
CLOUDFLARE_V4_RANGES = [
    "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22",
    "141.101.64.0/18", "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20",
    "197.234.240.0/22", "198.41.128.0/17", "162.158.0.0/15", "104.16.0.0/13",
    "172.64.0.0/13", "131.0.72.0/22",
]


def _public_ips():
    """A records for the gunio hostname from a public resolver, or None while
    the record does not exist yet (pre-rollout)."""
    resolver = dns.resolver.Resolver(configure=False)
    resolver.nameservers = ["1.1.1.1", "8.8.8.8"]
    resolver.lifetime = 10
    try:
        return [r.address for r in resolver.resolve(GUNIO_HOSTNAME, "A")]
    except (dns.resolver.NXDOMAIN, dns.resolver.NoAnswer):
        return None
    except (dns.resolver.NoNameservers, dns.exception.Timeout):
        # Egress-restricted/offline runner: public resolvers unreachable.
        # Treat like pre-rollout so the suite skips instead of erroring.
        return None


@pytest.mark.smoke
class TestGunioDNS:
    def test_resolves_to_proxied_cloudflare_record(self):
        """The hostname resolves publicly and only to Cloudflare edge IPs."""
        ips = _public_ips()
        if ips is None:
            pytest.skip(f"{GUNIO_HOSTNAME} has no public record yet (pre-rollout)")
        assert ips, f"{GUNIO_HOSTNAME} resolved to an empty answer"
        nets = [ipaddress.ip_network(n) for n in CLOUDFLARE_V4_RANGES]
        outside = [
            ip for ip in ips
            if not any(ipaddress.ip_address(ip) in net for net in nets)
        ]
        assert not outside, (
            f"{GUNIO_HOSTNAME} resolved outside Cloudflare's edge ranges: {outside} "
            "-- the record must be proxied (orange-cloud), never the origin"
        )


@pytest.mark.acceptance
class TestGunioAccessGate:
    def test_unauthenticated_request_is_access_gated(self):
        """A bare HTTPS request never reaches the MCP server: Cloudflare
        Access must answer with a login redirect or a deny, and the body must
        not be an MCP (JSON-RPC / SSE) response."""
        if _public_ips() is None:
            pytest.skip(f"{GUNIO_HOSTNAME} has no public record yet (pre-rollout)")
        try:
            resp = requests.get(
                f"https://{GUNIO_HOSTNAME}/mcp", timeout=15, allow_redirects=False
            )
        except (requests.exceptions.SSLError, requests.exceptions.ConnectionError) as e:
            pytest.skip(f"{GUNIO_HOSTNAME} not serving yet (mid-rollout): {e}")

        assert resp.status_code in (301, 302, 303, 307, 308, 401, 403), (
            f"expected an Access gate (redirect/deny), got {resp.status_code}"
        )
        if resp.status_code in (301, 302, 303, 307, 308):
            assert "cloudflareaccess.com" in resp.headers.get("Location", ""), (
                f"redirect target is not the Access login: {resp.headers.get('Location')}"
            )
        assert "jsonrpc" not in resp.text[:2048], "MCP response leaked past Access"
        assert "text/event-stream" not in resp.headers.get("Content-Type", ""), (
            "MCP SSE stream leaked past Access"
        )


@pytest.mark.acceptance
class TestGunioK8s:
    @pytest.fixture(scope="class")
    def k8s_or_skip(self):
        config.load_kube_config()
        core = client.CoreV1Api()
        namespaces = [ns.metadata.name for ns in core.list_namespace().items]
        if GUNIO_NAMESPACE not in namespaces:
            pytest.skip(f"namespace '{GUNIO_NAMESPACE}' not created yet (pre-rollout)")
        return core

    def test_deployment_two_containers_ready(self, k8s_or_skip):
        """The gunio pod runs BOTH containers (app + cloudflared sidecar)."""
        apps = client.AppsV1Api()
        deployments = apps.list_namespaced_deployment(GUNIO_NAMESPACE).items
        deploy = next(
            (d for d in deployments if d.metadata.name == GUNIO_DEPLOYMENT), None
        )
        assert deploy is not None, f"Deployment '{GUNIO_DEPLOYMENT}' missing"
        containers = [c.name for c in deploy.spec.template.spec.containers]
        assert sorted(containers) == ["cloudflared", "gunio-mcp"], (
            f"expected app + sidecar, got containers: {containers}"
        )
        assert (deploy.status.ready_replicas or 0) >= 1, (
            f"{GUNIO_DEPLOYMENT}: 0 ready replicas "
            f"(status: {deploy.status.conditions})"
        )

    @pytest.mark.parametrize("secret_name", GUNIO_ESO_SECRETS)
    def test_secret_exists_and_is_eso_owned(self, k8s_or_skip, secret_name):
        """Both Secrets exist and are owned by an ExternalSecret -- proof they
        came from Vault via ESO, not from a hand-applied kubectl secret."""
        secrets = k8s_or_skip.list_namespaced_secret(GUNIO_NAMESPACE).items
        secret = next((s for s in secrets if s.metadata.name == secret_name), None)
        assert secret is not None, f"Secret '{secret_name}' missing in {GUNIO_NAMESPACE}"
        owners = [o.kind for o in (secret.metadata.owner_references or [])]
        assert "ExternalSecret" in owners, (
            f"Secret '{secret_name}' is not owned by an ExternalSecret "
            f"(owners: {owners or 'none'}) -- was it applied by hand?"
        )
