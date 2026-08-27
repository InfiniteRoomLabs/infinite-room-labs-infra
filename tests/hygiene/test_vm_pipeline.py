"""Static tripwires for the VM provisioning pipeline.

Repo introspection only -- no libvirt, no host access. These assert the
*shape* of playbooks/vms.yml, not its runtime behavior: they catch a
regression that reintroduces a known defect, they do not prove the playbook
provisions anything.
"""

from pathlib import Path

import pytest
import yaml

pytestmark = pytest.mark.hygiene

REPO = Path(__file__).resolve().parents[2]
VMS_PLAYBOOK = REPO / "ansible/playbooks/vms.yml"


def iter_tasks(node):
    """Yield every task-like mapping in a playbook, descending into blocks."""
    if isinstance(node, dict):
        for key in ("tasks", "pre_tasks", "post_tasks", "handlers", "block", "rescue", "always"):
            for child in node.get(key) or []:
                yield from iter_tasks(child)
        if any(k in node for k in ("ansible.builtin.command", "ansible.builtin.shell", "command", "shell")):
            yield node
    elif isinstance(node, list):
        for child in node:
            yield from iter_tasks(child)


def command_words(task):
    """Every string token a command/shell task would run."""
    words = []
    for key in ("ansible.builtin.command", "ansible.builtin.shell", "command", "shell"):
        spec = task.get(key)
        if spec is None:
            continue
        if isinstance(spec, str):
            words.append(spec)
        elif isinstance(spec, dict):
            if isinstance(spec.get("argv"), list):
                words.extend(str(a) for a in spec["argv"])
            for k in ("cmd", "_raw_params"):
                if spec.get(k):
                    words.append(str(spec[k]))
    return words


@pytest.fixture(scope="module")
def vms_playbook():
    return yaml.safe_load(VMS_PLAYBOOK.read_text())


def qemu_img_create_tasks(playbook):
    return [
        t
        for t in iter_tasks(playbook)
        if "qemu-img" in command_words(t) and "create" in command_words(t)
    ]


def test_qemu_img_create_is_present(vms_playbook):
    """Guards the tests below: they are vacuous if the task is renamed away."""
    assert qemu_img_create_tasks(vms_playbook), (
        "no qemu-img create task found in vms.yml -- if disk creation moved, "
        "move these tripwires with it"
    )


def test_qemu_img_create_never_backs_onto_a_mutable_symlink(vms_playbook):
    """A qcow2 header recording `<family>-latest.qcow2` follows the symlink
    wherever a later publish points it. The backing file must be a path
    resolved on the host before qemu-img sees it."""
    offenders = {}
    for task in qemu_img_create_tasks(vms_playbook):
        bad = [
            w
            for w in command_words(task)
            if "-latest" in w or "irl_vm_default_image" in w or ".image" in w
        ]
        if bad:
            offenders[task.get("name", "<unnamed>")] = bad
    assert not offenders, (
        "qemu-img create is passing an unresolved image selector as its "
        f"backing file: {offenders} -- pass the readlink-resolved path instead"
    )


def test_qemu_img_create_uses_argv_not_a_shell_string(vms_playbook):
    """argv form: no shell, so a path with a space or a quote cannot split
    into extra arguments."""
    for task in qemu_img_create_tasks(vms_playbook):
        spec = task.get("ansible.builtin.command") or task.get("command")
        assert isinstance(spec, dict) and isinstance(spec.get("argv"), list), (
            f"{task.get('name', '<unnamed>')}: use the command module's argv "
            "form for qemu-img create, not a shell string"
        )


def test_seed_iso_build_has_no_creates_guard(vms_playbook):
    """Minted Tailscale authkeys are single-use with a 1h expiry, so a seed
    ISO left from an earlier attempt carries a dead key. The ISO must be
    rebuilt unconditionally, never skipped because the file already exists."""
    for task in iter_tasks(vms_playbook):
        if "cloud-localds" not in command_words(task):
            continue
        spec = task.get("ansible.builtin.command") or task.get("command")
        assert "creates" not in spec, (
            f"{task.get('name', '<unnamed>')}: `creates:` would keep a stale "
            "seed ISO (and its expired authkey) in place"
        )
