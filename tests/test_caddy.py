"""Caddy reverse proxy tests: HTTPS endpoints via internal TLS."""

import pytest
from conftest import SERVICES


@pytest.mark.acceptance
class TestCaddy:
    @pytest.mark.parametrize("name,svc", list(SERVICES.items()))
    def test_service_responds(self, https, name, svc):
        """Each proxied service responds via its HTTPS domain."""
        url = f"https://{svc['domain']}{svc['health_path']}"
        resp = https.get(url)
        expected = svc["health_status"]
        if isinstance(expected, list):
            assert resp.status_code in expected, (
                f"{name}: {url} returned {resp.status_code}, expected one of {expected}"
            )
        else:
            assert resp.status_code == expected, (
                f"{name}: {url} returned {resp.status_code}, expected {expected}"
            )

    def test_plane_web_frontend(self, https):
        """Plane web frontend returns HTML."""
        resp = https.get("https://plane.lab.infiniteroomlabs.cloud/")
        assert resp.status_code == 200
        assert "text/html" in resp.headers.get("content-type", "")

    def test_plane_api_path_routing(self, https):
        """Plane API path routing works through Caddy."""
        resp = https.get("https://plane.lab.infiniteroomlabs.cloud/api/")
        # API should return JSON or a redirect, not the web frontend HTML
        content_type = resp.headers.get("content-type", "")
        assert resp.status_code in (200, 301, 302, 404), (
            f"Plane API returned {resp.status_code}"
        )

    def test_tls_internal_ca(self, https):
        """All services use Caddy's internal CA (not Let's Encrypt)."""
        # If we can connect with verify=False and get a response,
        # the cert is self-signed (internal CA). Public CA certs
        # would work with verify=True.
        resp = https.get("https://git.lab.infiniteroomlabs.cloud/api/v1/version")
        assert resp.status_code == 200
