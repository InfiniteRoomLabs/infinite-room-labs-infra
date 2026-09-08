"""Contract tests for packer/scripts/publish-image.sh name parsing.

`packer validate` proves template syntax and never executes this script, so
its family derivation -- the thing that decides which `<family>-latest.qcow2`
symlink gets repointed -- has no other coverage.

Runs the real script under `bash` with fake `scp`/`ssh` on PATH in a temp dir,
so nothing leaves the machine. Invoking with `bash` rather than executing it
bypasses the `#!/usr/bin/env -S usage bash` shebang: `usage` is not a test
dependency, and the script reads its arguments from `$usage_*` env vars, which
the harness sets directly.
"""

import os
import subprocess
from pathlib import Path

import pytest

pytestmark = pytest.mark.hygiene

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "packer/scripts/publish-image.sh"

# Fakes that record their argv instead of touching the network.
FAKE = """#!/usr/bin/env bash
printf '%s %s\\n' "$(basename "$0")" "$*" >> "$FAKE_LOG"
"""


@pytest.fixture
def publish(tmp_path):
    """Returns run(artifact_name, *flags) -> (CompletedProcess, [fake calls])."""
    bindir = tmp_path / "bin"
    bindir.mkdir()
    for tool in ("scp", "ssh"):
        p = bindir / tool
        p.write_text(FAKE)
        p.chmod(0o755)
    log = tmp_path / "calls.log"

    def run(artifact_name, no_latest=False, exists=True, dest="/images"):
        artifact = tmp_path / artifact_name
        if exists:
            artifact.write_bytes(b"not really a qcow2")
        env = {
            **os.environ,
            "PATH": f"{bindir}:{os.environ['PATH']}",
            "FAKE_LOG": str(log),
            "usage_qcow2": str(artifact),
            "usage_host": "test-host",
            "usage_dest": dest,
        }
        if no_latest:
            env["usage_no_latest"] = "1"
        proc = subprocess.run(
            ["bash", str(SCRIPT)], capture_output=True, text=True, env=env, timeout=30
        )
        calls = log.read_text().splitlines() if log.exists() else []
        return proc, calls

    return run


# ── Accepted names, and the family each one derives ──────────────────
@pytest.mark.parametrize(
    "artifact,family",
    [
        # The pre-existing base family: backward compatibility.
        ("ubuntu-24.04-golden-v1.0.0.qcow2", "ubuntu-24.04-golden"),
        ("ubuntu-24.04-golden-v12.3.45.qcow2", "ubuntu-24.04-golden"),
        # The new k8s-node family, which must NOT collide with the base one.
        ("ubuntu-24.04-k8s-golden-v1.0.0.qcow2", "ubuntu-24.04-k8s-golden"),
        # Packer's default image_version.
        ("ubuntu-24.04-k8s-golden-v0.0.0-dev.qcow2", "ubuntu-24.04-k8s-golden"),
        ("ubuntu-24.04-golden-v0.0.0-dev.qcow2", "ubuntu-24.04-golden"),
        # Prerelease and build metadata.
        ("debian-13-golden-v2.0.0-rc.1.qcow2", "debian-13-golden"),
        ("debian-13-golden-v2.0.0+build.7.qcow2", "debian-13-golden"),
    ],
)
def test_derives_family_and_repoints_that_symlink(publish, artifact, family):
    proc, calls = publish(artifact)
    assert proc.returncode == 0, proc.stderr
    assert f"family:  {family}" in proc.stdout

    ln = [c for c in calls if "ln -sfn" in c]
    assert len(ln) == 1, f"expected exactly one symlink update, got {calls}"
    assert f"'{artifact}' '/images/{family}-latest.qcow2'" in ln[0]

    # The artifact lands via a .tmp staging name, then is moved into place.
    assert any("scp " in c and f"/images/{artifact}.tmp" in c for c in calls)
    assert any(f"mv '/images/{artifact}.tmp' '/images/{artifact}'" in c for c in calls)


def test_k8s_family_does_not_repoint_the_base_family_symlink(publish):
    """The failure this grammar exists to prevent: a k8s-node image taking
    over the symlink that plain VMs boot from."""
    _, calls = publish("ubuntu-24.04-k8s-golden-v1.0.0.qcow2")
    assert not any("ubuntu-24.04-golden-latest.qcow2" in c for c in calls)


# ── Rejected names ───────────────────────────────────────────────────
@pytest.mark.parametrize(
    "artifact",
    [
        "arbitrary.qcow2",                       # no family/version structure
        "ubuntu-24.04-golden.qcow2",             # no version
        "ubuntu-24.04-golden-latest.qcow2",      # the symlink name itself
        "ubuntu-24.04-golden-v1.0.qcow2",        # not MAJOR.MINOR.PATCH
        "ubuntu-24.04-golden-v1.qcow2",
        "ubuntu-24.04-golden-vx.y.z.qcow2",      # non-numeric version
        "v1.0.0.qcow2",                          # empty family
        "-v1.0.0.qcow2",
        "ubuntu-24.04-golden-v1.0.0.img",        # wrong extension
        "ubuntu-24.04-golden-v1.0.0.qcow2.bak",
    ],
)
def test_rejects_malformed_names_without_touching_the_remote(publish, artifact):
    proc, calls = publish(artifact)
    assert proc.returncode != 0, f"{artifact} should be rejected"
    assert "does not match the image-family grammar" in proc.stderr
    assert calls == [], f"rejected artifact still ran remote commands: {calls}"


def test_missing_file_is_rejected(publish):
    proc, calls = publish("ubuntu-24.04-golden-v1.0.0.qcow2", exists=False)
    assert proc.returncode == 1
    assert "no such file" in proc.stderr
    assert calls == []


# ── --no-latest ──────────────────────────────────────────────────────
def test_no_latest_uploads_but_leaves_the_symlink_alone(publish):
    proc, calls = publish("ubuntu-24.04-golden-v1.0.0.qcow2", no_latest=True)
    assert proc.returncode == 0, proc.stderr
    assert not any("ln -sfn" in c for c in calls), calls
    assert any("scp " in c for c in calls), "artifact should still be uploaded"
