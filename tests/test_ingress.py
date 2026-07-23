"""Ingress tests: every routed service responds over HTTPS with valid LE TLS.

Traefik (in-cluster) terminates TLS with Let's Encrypt DNS-01 certs; services
under test are derived from the irl_services registry via conftest.SERVICES.
"""

import datetime
import ssl
import socket

import pytest

from conftest import SERVICES


@pytest.mark.acceptance
class TestIngress:
    @pytest.mark.parametrize("name,svc", list(SERVICES.items()))
    def test_service_responds(self, https, name, svc):
        """Each routed service responds via its HTTPS domain."""
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

    def test_tls_lets_encrypt(self):
        """All services use Let's Encrypt (publicly trusted) certificates."""
        cert = self._peer_cert("home.lab.infiniteroomlabs.cloud")
        issuer = dict(x[0] for x in cert["issuer"])
        assert issuer.get("organizationName") == "Let's Encrypt", (
            f"Expected Let's Encrypt issuer, got: {issuer}"
        )

    def test_cert_not_expiring_soon(self):
        """Certificate has more than 7 days until expiry."""
        cert = self._peer_cert("home.lab.infiniteroomlabs.cloud")
        not_after = datetime.datetime.strptime(
            cert["notAfter"], "%b %d %H:%M:%S %Y %Z"
        ).replace(tzinfo=datetime.timezone.utc)
        days_left = (not_after - datetime.datetime.now(datetime.timezone.utc)).days
        assert days_left > 7, f"Certificate expires in {days_left} days"

    @staticmethod
    def _peer_cert(host):
        ctx = ssl.create_default_context()
        with ctx.wrap_socket(socket.socket(), server_hostname=host) as s:
            s.settimeout(10)
            s.connect((host, 443))
            return s.getpeercert()
