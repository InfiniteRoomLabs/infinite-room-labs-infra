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
- SSH access to `homelab-ts` and `do-k3s` (via `~/.ssh/config`)
- Goss installed on remote nodes (`task goss:install`)

## Test Layers

### Layer 1: Node Validation (Goss)

Runs on each node via SSH. Validates OS-level config.

| Node | What's Checked |
|------|----------------|
| homelab | SSH hardening, kernel params, k3s server, ZFS pool, Caddy, flannel interface |
| do-k3s-agent-01 | SSH hardening, kernel params, k3s agent, Tailscale, flannel interface |

```bash
task goss:homelab       # Just homelab
task goss:digitalocean  # Just DO node
task goss               # Both
```

### Layer 2: Service Tests (pytest)

Runs from the laptop. 93 tests across 7 modules.

| Module | Marker | Tests |
|--------|--------|-------|
| `test_cluster.py` | `smoke` | Nodes ready, namespace active, no crashloops |
| `test_dns.py` | `smoke` | Split DNS resolution for all service domains |
| `test_caddy.py` | `acceptance` | HTTPS endpoints via Caddy reverse proxy |
| `test_k8s_resources.py` | `acceptance`, `compliance` | Helm releases, PVs, secrets, NetworkPolicies |
| `test_services.py` | `acceptance` | Per-service deep checks (PG databases, Vault, Ollama) |
| `test_networking.py` | `networking`, `integration` | Cross-node pod connectivity via flannel |
| `test_node_labels.py` | `compliance` | IRL label taxonomy, scheduling compliance |

```bash
uv run pytest -v -m smoke          # Just smoke
uv run pytest -v -m acceptance     # Acceptance tests
uv run pytest -v -m compliance     # Security/label compliance
uv run pytest -v -m networking     # Cross-node (slow)
uv run pytest -v                   # Everything
```

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

- **New service?** Add its health check to `conftest.py` SERVICES dict and `test_caddy.py` picks it up automatically.
- **New node?** Add a `goss/{node}.yml` and a task in `Taskfile.yml`.
- **New k8s resource?** Add to the expected lists in `test_k8s_resources.py`.
- **New label?** Add to the expected dicts in `test_node_labels.py`.

## CI Integration

pytest generates JUnit XML at `results/pytest.xml`. Goss generates JSON at `results/goss-*.json`. Both are CI-compatible formats.
