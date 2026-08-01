"""DNS resolution tests: Tailscale Split DNS + CoreDNS."""

import pytest
import dns.resolver
from conftest import HOMELAB_TAILSCALE_IP


EXPECTED_RECORDS = [
    "git.lab.infiniteroomlabs.cloud",
    "auth.lab.infiniteroomlabs.cloud",
    "grafana.lab.infiniteroomlabs.cloud",
    "vault.lab.infiniteroomlabs.cloud",
    "storage.internal.lab.infiniteroomlabs.cloud",
    "metrics.internal.lab.infiniteroomlabs.cloud",
    "alerts.internal.lab.infiniteroomlabs.cloud",
    "context.internal.lab.infiniteroomlabs.cloud",
    "home.lab.infiniteroomlabs.cloud",
    "bookmarks.lab.infiniteroomlabs.cloud",
    "satisfactory.internal.lab.infiniteroomlabs.cloud",
]


@pytest.mark.smoke
class TestDNS:
    @pytest.mark.parametrize("domain", EXPECTED_RECORDS)
    def test_resolves_to_homelab(self, dns_resolver, domain):
        """Each service domain resolves to the homelab Tailscale IP."""
        answers = dns_resolver.resolve(domain, "A")
        ips = [rdata.address for rdata in answers]
        assert HOMELAB_TAILSCALE_IP in ips, (
            f"{domain} resolved to {ips}, expected {HOMELAB_TAILSCALE_IP}"
        )

    def test_wildcard_resolves(self, dns_resolver):
        """Wildcard *.lab.infiniteroomlabs.cloud resolves."""
        answers = dns_resolver.resolve("anything-random.lab.infiniteroomlabs.cloud", "A")
        ips = [rdata.address for rdata in answers]
        assert HOMELAB_TAILSCALE_IP in ips

    def test_nonexistent_no_leakage(self, dns_resolver):
        """Queries for non-IRL domains are refused (not forwarded to public DNS)."""
        with pytest.raises((dns.resolver.NXDOMAIN, dns.resolver.NoNameservers)):
            dns_resolver.resolve("definitely-not-real.example.com", "A")
