"""Loaders for repo-hygiene tests: pure repo introspection, no cluster access.

Everything here reads files relative to the repo root so the suite runs
identically on a laptop, in CI, and on a fresh clone with KUBECONFIG unset.
"""

from pathlib import Path

import pytest
import yaml

REPO = Path(__file__).resolve().parents[2]


def walk_collect(node, key):
    """Recursively collect all non-empty values of `key` in a YAML tree."""
    found = []
    if isinstance(node, dict):
        for k, v in node.items():
            if k == key and v not in (None, ""):
                if isinstance(v, list):
                    found.extend(v)
                else:
                    found.append(v)
            else:
                found.extend(walk_collect(v, key))
    elif isinstance(node, list):
        for v in node:
            found.extend(walk_collect(v, key))
    return found


@pytest.fixture(scope="session")
def repo_root():
    return REPO


@pytest.fixture(scope="session")
def group_vars():
    path = REPO / "ansible/inventory/group_vars/all/main.yml"
    return yaml.safe_load(path.read_text())


@pytest.fixture(scope="session")
def registry(group_vars):
    """The irl_services dict -- the canonical service registry."""
    return group_vars["irl_services"]


@pytest.fixture(scope="session")
def bw_sync_k8s_secrets():
    """All k8s_secret names bw-sync.sh manages (from bw-sync-config.yaml)."""
    doc = yaml.safe_load((REPO / "scripts/bw-sync-config.yaml").read_text())
    return set(walk_collect(doc, "k8s_secret"))


@pytest.fixture(scope="session")
def deploy_tags():
    """Every tag used anywhere in helm-deploy.yml (play or task level)."""
    doc = yaml.safe_load((REPO / "ansible/playbooks/helm-deploy.yml").read_text())
    return set(walk_collect(doc, "tags"))


@pytest.fixture(scope="session")
def helm_values_dirs():
    """{dir name: values.yaml path} for every ansible/helm/<dir>/values.yaml."""
    return {p.parent.name: p for p in (REPO / "ansible/helm").glob("*/values.yaml")}


@pytest.fixture(scope="session")
def existing_secrets_by_dir(helm_values_dirs):
    """existingSecret names referenced by each ansible/helm/<dir>/values.yaml."""
    return {
        name: set(walk_collect(yaml.safe_load(path.read_text()), "existingSecret"))
        for name, path in helm_values_dirs.items()
    }


@pytest.fixture(scope="session")
def homepage_text():
    """Raw homepage values -- checked by substring since tiles may live in
    either structured YAML or an embedded config string."""
    return (REPO / "ansible/helm/homepage/values.yaml").read_text()
