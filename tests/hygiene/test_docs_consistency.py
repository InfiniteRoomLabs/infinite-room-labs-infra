"""Docs must be honest: clean encoding, no references to retired systems.

Replaces the soft pre-commit encoding gate (which silently no-ops when
spec-kitty is absent) with a hard, dependency-free check that also runs in CI.
"""

import re
import subprocess
from pathlib import Path

import pytest

pytestmark = pytest.mark.hygiene

# Self-contained on purpose: `import conftest` is ambiguous with two
# conftest.py files on sys.path (tests/ and tests/hygiene/).
REPO = Path(__file__).resolve().parents[2]


def tracked_markdown():
    out = subprocess.run(
        ["git", "ls-files", "*.md"],
        cwd=REPO,
        capture_output=True,
        text=True,
        check=True,
    )
    return out.stdout.splitlines()

# Vendor, generated, or frozen trees exempt from the authored-docs rules.
EXEMPT_PREFIXES = (".kittify/", ".claude/commands/", "kitty-specs/")

# Windows-1252 imports the repo bans: curly quotes, en/em dash, arrows.
BANNED = re.compile("[‘’“”–—→←]")

# Phrases naming retired systems that may not appear in LIVE docs.
# Historical trees legitimately describe the past and are exempt.
DEAD_REFS = ("caddy_proxy",)
HISTORICAL_PREFIXES = (
    "docs/plans/",
    "docs/decisions/",  # ADRs document retirements; naming the retired system is their job
    "docs/superpowers/",
    "kitty-specs/",
    ".kittify/",
    ".claude/",
    "CHANGELOG.md",
)
# Live docs still carrying dead refs -- fixed in WS3. Shrink-only ratchet.
DEAD_REF_GAPS = {"CONTRIBUTING.md"}


def test_markdown_encoding():
    bad = {}
    for rel in tracked_markdown():
        if rel.startswith(EXEMPT_PREFIXES):
            continue
        text = (REPO / rel).read_bytes().decode("utf-8")  # raises on invalid UTF-8
        hits = BANNED.findall(text)
        if hits:
            bad[rel] = sorted({f"U+{ord(c):04X}" for c in hits})
    assert not bad, (
        f"smart quotes/dashes/arrows in authored markdown: {bad} "
        "-- use ASCII equivalents (see repo conventions)"
    )


def test_no_dead_references():
    bad = {}
    for rel in tracked_markdown():
        if rel.startswith(HISTORICAL_PREFIXES) or rel in DEAD_REF_GAPS:
            continue
        hits = [p for p in DEAD_REFS if p in (REPO / rel).read_text()]
        if hits:
            bad[rel] = hits
    assert not bad, f"live docs referencing retired systems: {bad}"


def test_dead_ref_gaps_only_shrink():
    stale = [
        rel
        for rel in DEAD_REF_GAPS
        if not any(p in (REPO / rel).read_text() for p in DEAD_REFS)
    ]
    assert not stale, f"clean now -- remove from DEAD_REF_GAPS: {stale}"
