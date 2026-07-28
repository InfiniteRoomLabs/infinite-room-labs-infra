"""Contract tests for scripts/includes/bw-session.sh (shared BW_SESSION resolver).

Runs the include in real bash with a stubbed `bw` on PATH and a temp $HOME.
The stub treats BW_SESSION == "goodkey" as unlocked, anything else as locked.
"""

import os
import subprocess
from pathlib import Path

import pytest

pytestmark = pytest.mark.hygiene

REPO_ROOT = Path(__file__).resolve().parents[2]
INCLUDE = REPO_ROOT / "scripts" / "includes" / "bw-session.sh"

BW_STUB = """#!/usr/bin/env bash
if [ "${BW_SESSION:-}" = "goodkey" ]; then
  echo '{"status":"unlocked"}'
else
  echo '{"status":"locked"}'
fi
"""

CALLER = """#!/usr/bin/env bash
set -euo pipefail
source "$1"
resolve_bw_session || exit 1
echo "RESOLVED=$BW_SESSION"
"""


def run_resolver(tmp_path, env_session=None, cache=None, cache_mode=0o600):
    """Run a set -euo pipefail caller that sources the include. Returns CompletedProcess."""
    stub_dir = tmp_path / "bin"
    stub_dir.mkdir(exist_ok=True)
    bw = stub_dir / "bw"
    bw.write_text(BW_STUB)
    bw.chmod(0o755)

    caller = tmp_path / "fake-consumer.sh"
    caller.write_text(CALLER)
    caller.chmod(0o755)

    home = tmp_path / "home"
    home.mkdir(exist_ok=True)
    if cache is not None:
        cache_file = home / ".bw_session"
        cache_file.write_text(cache)
        cache_file.chmod(cache_mode)

    env = {
        "PATH": f"{stub_dir}:{os.environ['PATH']}",
        "HOME": str(home),
    }
    if env_session is not None:
        env["BW_SESSION"] = env_session

    return subprocess.run(
        [str(caller), str(INCLUDE)],
        env=env, capture_output=True, text=True, timeout=30,
    )


def test_valid_env_key_used(tmp_path):
    r = run_resolver(tmp_path, env_session="goodkey")
    assert r.returncode == 0, r.stderr
    assert "RESOLVED=goodkey" in r.stdout


def test_stale_env_falls_back_to_file(tmp_path):
    r = run_resolver(tmp_path, env_session="stalekey", cache="goodkey\n")
    assert r.returncode == 0, r.stderr
    assert "RESOLVED=goodkey" in r.stdout


def test_empty_whitespace_file_fails(tmp_path):
    r = run_resolver(tmp_path, cache="  \n\n")
    assert r.returncode == 1
    assert "no valid BW_SESSION" in r.stderr


def test_locked_vault_fails(tmp_path):
    r = run_resolver(tmp_path, env_session="stalekey", cache="alsostale\n")
    assert r.returncode == 1
    assert "no valid BW_SESSION" in r.stderr


def test_wrong_perms_file_skipped(tmp_path):
    r = run_resolver(tmp_path, cache="goodkey\n", cache_mode=0o644)
    assert r.returncode == 1
    assert "mode 600" in r.stderr
    assert "no valid BW_SESSION" in r.stderr


def test_no_candidates_fails_naming_caller(tmp_path):
    r = run_resolver(tmp_path)
    assert r.returncode == 1
    assert "fake-consumer.sh" in r.stderr
    assert "bw-unlock-prompt.sh" in r.stderr
