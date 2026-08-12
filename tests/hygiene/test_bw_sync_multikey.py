"""Contract tests for scripts/bw-sync.sh multi-key + per-namespace mappings.

Runs the real script in bash with a stubbed `bw` on PATH (test_bw_session_resolver
pattern), a temp $HOME, and a minimal BW_SYNC_CONFIG. --dry-run keeps kubectl
untouched (a failing stub proves it). Covers the k8s_keys map shape added for
vault-eso-approle (one Login item -> role-id + secret-id keys in one Secret,
namespace external-secrets) and the single-key k8s_namespace fallback.

Requires mikefarah yq v4 (what bw-sync.sh uses); skipped when absent so the
suite stays dependency-light elsewhere. CI's ubuntu runner ships it.
"""

import shutil
import subprocess
from pathlib import Path

import pytest

pytestmark = pytest.mark.hygiene

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "bw-sync.sh"


def _mikefarah_yq() -> bool:
    yq = shutil.which("yq")
    if not yq:
        return False
    out = subprocess.run([yq, "--version"], capture_output=True, text=True)
    return "mikefarah" in (out.stdout + out.stderr)


requires_yq = pytest.mark.skipif(
    not _mikefarah_yq(), reason="needs mikefarah yq v4 (the yq bw-sync.sh uses)"
)

# Stub bw: unlocked session, one IRL folder, two Login items. The
# vault-eso-approle item carries role-id in username and secret-id in
# password -- the multi-key shape. Values are obvious fakes.
BW_STUB = """#!/usr/bin/env bash
case "$1" in
  status) echo '{"status": "unlocked"}' ;;
  unlock) exit 0 ;;
  sync) exit 0 ;;
  list)
    case "$2" in
      folders) echo '[{"id": "f1", "name": "IRL"}]' ;;
      items) cat <<'EOF'
[
  {"name": "vault-eso-approle",
   "revisionDate": "2026-08-12T00:00:00.000Z",
   "login": {"username": "fake-role-id", "password": "fake-secret-id"}},
  {"name": "plain-item",
   "revisionDate": "2026-08-12T00:00:00.000Z",
   "login": {"password": "fake-plain-value"}}
]
EOF
      ;;
    esac ;;
esac
"""

# kubectl stub that always fails: --dry-run must never invoke it.
KUBECTL_STUB = """#!/usr/bin/env bash
echo "kubectl must not be called in --dry-run" >&2
exit 97
"""

CONFIG = """\
bitwarden_folder: "IRL"

targets:
  ansible_vault:
    output_file: "ansible/inventory/group_vars/all/vault.yml"
    encryption_password_item: "ansible-vault-password"
  kubernetes:
    namespace: "irl"
    kubeconfig: "~/.kube/homelab.yaml"

secrets:
  - bw_item: "vault-eso-approle"
    k8s_secret: "vault-eso-approle"
    k8s_namespace: "external-secrets"
    k8s_keys:
      role-id: "username"
      secret-id: "password"

  - bw_item: "plain-item"
    k8s_secret: "plain-secret"
    k8s_key: "value"
"""


@pytest.fixture()
def sync_env(tmp_path):
    stub_dir = tmp_path / "stubs"
    stub_dir.mkdir()
    for name, body in (("bw", BW_STUB), ("kubectl", KUBECTL_STUB)):
        stub = stub_dir / name
        stub.write_text(body)
        stub.chmod(0o755)

    home = tmp_path / "home"
    home.mkdir()

    config = tmp_path / "bw-sync-config.yaml"
    config.write_text(CONFIG)

    import os

    env = dict(os.environ)
    env.update(
        {
            "PATH": f"{stub_dir}:{env['PATH']}",
            "HOME": str(home),
            "BW_SESSION": "stub-session",
            "BW_SYNC_CONFIG": str(config),
            # usage-parsed flags, preset directly (the harness runs bash, not
            # the `usage` shebang): --target k8s --dry-run
            "usage_target": "k8s",
            "usage_dry_run": "1",
        }
    )
    return env


@requires_yq
def test_multikey_and_namespace_dry_run(sync_env):
    """One k8s_keys mapping yields ONE Secret with BOTH keys in its own
    namespace; the plain mapping falls back to the default namespace; no
    secret value ever reaches stdout/stderr."""
    result = subprocess.run(
        ["bash", str(SCRIPT)],
        env=sync_env,
        capture_output=True,
        text=True,
        timeout=60,
    )
    out = result.stdout + result.stderr
    assert result.returncode == 0, f"bw-sync --dry-run failed:\n{out}"

    # Multi-key entry: both keys, one apply, per-entry namespace honored.
    assert "external-secrets/vault-eso-approle (2 key(s))" in out
    # Single-key entry: default namespace fallback still works.
    assert "irl/plain-secret (1 key(s))" in out
    # kubectl was never invoked (the stub would have exploded with code 97).
    assert "must not be called" not in out
    # No secret material leaks into the log.
    for needle in ("fake-role-id", "fake-secret-id", "fake-plain-value"):
        assert needle not in out, f"secret value leaked to output: {needle}"
