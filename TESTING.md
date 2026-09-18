# Infrastructure Testing

Acceptance tests validate the full IRL homelab k8s cluster from the laptop.

## Quick Start

```bash
cd tests/

# Quick smoke test (is everything up?)
task smoke

# Full validation (Goss nodes + pytest services + report)
task validate
```

## Prerequisites

- `task` CLI (`~/.local/bin/task`)
- `uv` for Python test runner
- `kubectl` configured for homelab cluster
- SSH access to `homelab-ts` (via `~/.ssh/config`)
- Goss installed on remote nodes (`task goss:install`)

## Test Layers

### Layer 1: Node Validation (Goss)

Runs on each node via SSH. Validates OS-level config.

| Node | What's Checked |
|------|----------------|
| homelab | SSH hardening, kernel params, k3s server, ZFS pool, flannel interface |

The cluster is single-node, so this is the only Goss target today.

```bash
task goss:homelab       # Just homelab
task goss               # All nodes (currently just homelab)
```

### Layer 2: Service Tests (pytest)

Runs from the laptop. 136 tests across 8 service modules plus the `hygiene/` contract suite.

| Module | Marker | Tests |
|--------|--------|-------|
| `test_cluster.py` | `smoke` | Nodes ready, namespace active, no crashloops |
| `test_dns.py` | `smoke` | Split DNS resolution for all service domains |
| `test_ingress.py` | `acceptance` | HTTPS endpoints through Traefik IngressRoutes |
| `test_k8s_resources.py` | `acceptance`, `compliance` | Helm releases, PVs, secrets, NetworkPolicies |
| `test_services.py` | `acceptance` | Per-service deep checks (PG databases, Vault, Ollama) |
| `test_networking.py` | `networking`, `integration` | Flannel overlay bound to the tailnet (cross-node cases return when a second node joins) |
| `test_node_labels.py` | `compliance` | IRL label taxonomy, scheduling compliance |
| `test_gunio_mcp.py` | `acceptance` | gunio-mcp endpoint + Cloudflare tunnel path |
| `hygiene/` | `hygiene` | Repo contracts, no cluster needed: every registry service has a homepage tile, a `<svc>-down.md` runbook and a DNS record; every `existingSecret` is mapped in bw-sync; docs carry no retired references. The GAP allowlists in these files are shrink-only ratchets. |

```bash
uv run pytest -v -m smoke          # Just smoke
uv run pytest -v -m hygiene        # Repo contracts (no cluster)
uv run pytest -v -m acceptance     # Acceptance tests
uv run pytest -v -m compliance     # Security/label compliance
uv run pytest -v -m networking     # Overlay networking (slow)
uv run pytest -v                   # Everything
```


### A note on `tests/uv.lock`

The lockfile records the repo's supply-chain gate as an `[options]` block
(`exclude-newer`, `exclude-newer-span = "P7D"`), which uv writes from the
operator's `~/.config/uv/uv.toml`. Running the suite on a machine WITHOUT that
uv config silently rewrites the lock and drops the block -- the diff looks like
a harmless 4-line deletion and it removes the record of the gate. If
`git status` shows `tests/uv.lock` modified after a test run you did not intend
to change dependencies, `git checkout -- tests/uv.lock`.
### Layer 3: Report

Combines Goss JSON + pytest JUnit XML into a Markdown checklist.

```bash
task report   # After pytest + goss have run
cat results/report.md
```

## Task Commands

| Command | What it Does |
|---------|-------------|
| `task validate` | Full pipeline: Goss -> pytest -> report |
| `task smoke` | Quick pytest smoke tests only |
| `task goss` | Run Goss on both nodes |
| `task goss:install` | Install Goss binary on remote nodes |
| `task goss:upload` | Upload test YAML to remote nodes |
| `task clean` | Remove test results |

## Adding Tests

- **New service?** The service list is DERIVED from `irl_services`; only add a `HEALTH_OVERRIDES` entry in `conftest.py` if it does not answer 200 on `/`. `pytest -m hygiene` then tells you which fan-out targets (homepage tile, runbook, DNS record) are still missing.
- **New node?** Add a `goss/{node}.yml` and a task in `Taskfile.yml`.
- **New k8s resource?** Add to the expected lists in `test_k8s_resources.py`.
- **New label?** Add to the expected dicts in `test_node_labels.py`.

## CI Integration

pytest generates JUnit XML at `results/pytest.xml`. Goss generates JSON at `results/goss-*.json`. Both are CI-compatible formats.
