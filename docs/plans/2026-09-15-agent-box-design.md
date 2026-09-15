# Agent Box Design

**Date**: 2026-09-15
**Status**: Approved, built (core scope)
**Author**: Wes Gilleland + Claude Fable 5.1
**Relates to**: `docker/agent-box/README.md`, `ansible/run-ansible.sh` (legacy runner this supersedes in practice), Anthropic's [dev container guide](https://code.claude.com/docs/en/devcontainer) and [sandbox environments](https://code.claude.com/docs/en/sandbox-environments)

## Overview

A containerized workstation for running Claude Code against this repo and the
homelab from any host that has Docker and bash, including the Windows desktop
where none of the laptop's toolchain (mise, fnox, Bitwarden CLI, the bash
wrapper scripts, Ansible) runs natively. Claude Code runs inside the container
as a non-root user with the full pinned toolchain; the container carries its
own identity and a default-deny egress firewall.

Scope is deliberately the core: build, run, identity, kubeconfig, doctor.
Expansion ideas are parked until it has been used for real.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| What runs inside | Claude Code + full toolchain | Anthropic's recommended shape for a native-Windows host; every host-container boundary is a wrapper to maintain, so have one boundary (the workspace bind) instead of many. |
| Where it lives | `docker/agent-box/` in this repo | The box exists to drive this repo; it rides the repo's CI (hygiene) and CHANGELOG discipline. |
| Base image | `debian:trixie-slim` | Matches the homelab OS; `gh`, `shellcheck`, `bubblewrap` are in-distro, no third-party apt repos in the image. |
| Tool versions | Repo `mise.toml` is the source of truth; everything else an `ARG` | One place to bump the IaC toolchain; the image cannot drift from what the laptop runs. |
| User | `agent`, uid 1000, non-root | Claude Code refuses `--dangerously-skip-permissions` as root; uid 1000 matches the homelab's `anonuid` convention so NFS-side files look the same. |
| State | One named volume at `/home/agent`, `CLAUDE_CONFIG_DIR` inside it | Anthropic's note: `.claude.json` (the OAuth account) lives outside `~/.claude` unless `CLAUDE_CONFIG_DIR` points at the volume. Invariant: the image installs nothing under `/home/agent`. |
| Credentials | Box-owned, never mounted from the host | Anthropic's explicit warning against mounting `~/.ssh`/cloud creds. SSH key generated on first start; kubeconfig from a dedicated ServiceAccount; gh/tea/bw/Claude logins done inside. Each revocable independently. |
| Egress | iptables default-deny from `allowlist.txt`, on by default, `AGENT_BOX_FIREWALL=0` to disable | Adapted from the reference `init-firewall.sh`. It is what makes unattended runs defensible. Self-tests on start (Anthropic host reachable, `example.com` not). |
| Claude Code install | npm, pinned, `DISABLE_AUTOUPDATER=1` | Reproducible image; the pin is the version. |
| Bash sandbox inside | Packages present (`bubblewrap`, `socat`), not enabled | Anthropic documents layering it inside a container; left to the operator via `/sandbox`. |
| Host wrapper deps | bash + docker only | Must work on a fresh Windows host before mise/usage/fnox exist there, so no `usage` spec (unlike `run-ansible.sh`). |
| Config precedence | env > `~/.config/agent-box/env` > default | 12-factor, matches the operator's stated preference; knobs declared once in `lib/config.sh`. |
| Ansible path | `ansible-core` via `uv tool` in the image + collections in `/opt/ansible` | Same pin as `ansible/pyproject.toml`; avoids creating a `.venv` on the Windows-backed bind mount. `uv run ansible-playbook` still works if preferred. |

## Layout

```
docker/agent-box/
  agent-box.sh          host entry point (build|shell|claude|run|doctor|identity|kubeconfig|config)
  lib/                  sourced host libs, one concern each: log, paths, config, docker, mounts
  image/
    Dockerfile          pins as ARGs; COPY --from=repo mise.toml + ansible/requirements.yml
    entrypoint.sh       firewall -> home skeleton -> ssh identity -> exec
    init-firewall.sh    default-deny egress (sudo, the only sudoers entry)
    allowlist.txt       destinations: hostnames, CIDRs, @github
    doctor.sh           PASS/WARN/FAIL acceptance report
    bashrc.sh           prompt, mise activate, history on the volume
  README.md             operator docs: quick start, boundary, config, maintaining, troubleshooting
```

The image build uses two contexts: `image/` (the files above) and
`--build-context repo=<repo root>` for `mise.toml` and
`ansible/requirements.yml`, so the Dockerfile reads the pins without copying
the whole repo in.

## Data flow

```
host bash ── agent-box.sh ── docker run --rm --init
                              -v irl-agent-box-home:/home/agent
                              -v ~/Projects:/work
                              --cap-add NET_ADMIN,NET_RAW  (firewall on)
                              -e AGENT_BOX_FIREWALL, TZ, AGENT_BOX_REPO_DIR
                              ┌─ entrypoint: firewall, keys, ssh-agent ─┐
                              │  claude | bash | doctor | <cmd>          │
                              └──────────────────────────────────────────┘
```

`identity` and `kubeconfig` are the only subcommands that use host
credentials, each exactly once, to install something the box then owns.

## Acceptance

`agent-box.sh doctor` exits 0 with no FAIL lines. WARN lines name the
one-time logins still to do on a fresh volume.

## Out of scope (for now)

`devcontainer.json`, GPU passthrough, a Docker socket inside the box, MCP
servers from `.mcp.json` (the `fnox` and `ccsm` entries assume laptop paths),
replacing `ansible/run-ansible.sh`, per-project volumes.
