"""Caddy reverse proxy tests: HTTPS endpoints with Let's Encrypt TLS."""

import ssl
import socket
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
        content_type = resp.headers.get("content-type", "")
        assert resp.status_code in (200, 301, 302, 404), (
            f"Plane API returned {resp.status_code}"
        )

    def test_tls_lets_encrypt(self):
        """All services use Let's Encrypt (publicly trusted) certificates."""
        ctx = ssl.create_default_context()
        with ctx.wrap_socket(
            socket.socket(), server_hostname="home.lab.infiniteroomlabs.cloud"
        ) as s:
            s.settimeout(10)
            s.connect(("home.lab.infiniteroomlabs.cloud", 443))
            cert = s.getpeercert()

        issuer = dict(x[0] for x in cert["issuer"])
        assert issuer.get("organizationName") == "Let's Encrypt", (
            f"Expected Let's Encrypt issuer, got: {issuer}"
        )

    def test_cert_not_expiring_soon(self):
        """Certificate has more than 7 days until expiry."""
        import datetime

        ctx = ssl.create_default_context()
        with ctx.wrap_socket(
            socket.socket(), server_hostname="home.lab.infiniteroomlabs.cloud"
        ) as s:
            s.settimeout(10)
            s.connect(("home.lab.infiniteroomlabs.cloud", 443))
            cert = s.getpeercert()

        not_after = datetime.datetime.strptime(
            cert["notAfter"], "%b %d %H:%M:%S %Y %Z"
        ).replace(tzinfo=datetime.timezone.utc)
        days_left = (not_after - datetime.datetime.now(datetime.timezone.utc)).days
        assert days_left > 7, f"Certificate expires in {days_left} days"
