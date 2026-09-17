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
own identity and an egress denylist firewall (default allow; see the Egress decision).

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
| Egress | iptables DENYLIST from `denylist.txt` (default allow), on by default, `AGENT_BOX_FIREWALL=0` to disable. Changed from an allowlist on 2026-09-17: the allowlist blocked the agent from reading docs and registries during ordinary work; the box is interactive, not an unattended `--dangerously-skip-permissions` runner, which is the case Anthropic's allowlist targets. The denylist keeps the mechanism (and the caps) so specific destinations can still be cut off. | Same iptables/ipset plumbing as the reference `init-firewall.sh`, inverted: one REJECT rule for the set, `OUTPUT ACCEPT` otherwise. Ships with cloud metadata endpoints and an `example.com` canary; self-tests on start (Anthropic host reachable, canary not). |
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
    init-firewall.sh    egress denylist, default allow (sudo, the only sudoers entry)
    denylist.txt        blocked destinations: hostnames, IPs, CIDRs
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

## Addendum 2026-09-15: compose owns the run definition

Second pass, same day, after using the first build. `lib/mounts.sh` (the
bash-assembled `docker run` argument list) is replaced by `compose.yaml`:
one `x-box-common` anchor, services `box` / `claude` / `doctor` (the latter
two `extends: box`), the two mounts, caps and env declared once. Overlays
`compose.open.yaml` (firewall off, `cap_add: !reset []`) and
`compose.ci.yaml` (no workspace bind, no TTY, throwaway home) replace the
`AGENT_BOX_FIREWALL=0` flag path with named stacks; a git-ignored
`compose.override.yaml` is the private-knobs mechanism compose users
already expect. `agent-box.sh` keeps only what compose cannot do: derive
`AGENT_BOX_SSH_USER`/`_HOST`/`_REPO_DIR` from the repo, the `identity` and
`kubeconfig` workflows, Git Bash path/TTY handling, and a `compose`
passthrough that applies all of that. `Taskfile.yml` adds short names on
hosts that have `task`.

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Where run config lives | `compose.yaml` + overlays | Declarative, diffable, `compose config` renders the truth; one file to read instead of a bash array. |
| Variants | Overlay files and `extends`, not flags | Compose has stacking, extends, anchors, `${VAR:-default}`; no conditionals. A variant is a file. |
| Private knobs | `compose.override.yaml` (git-ignored) and/or `~/.config/agent-box/env` | Override file is the compose-native way; the env file keeps working for the wrapper. Same names either way. |
| Wrapper kept | Yes, thinner | Derivation from repo files, host-credential workflows, and Windows quirks have no compose equivalent. |
| Task | Optional sugar over the wrapper | The wrapper stays the complete, dependency-free interface; `task` is not on a fresh Windows host. |

## Acceptance

`agent-box.sh doctor` exits 0 with no FAIL lines. WARN lines name the
one-time logins still to do on a fresh volume.

## Out of scope (for now)

`devcontainer.json`, GPU passthrough, a Docker socket inside the box, MCP
servers from `.mcp.json` (the `fnox` and `ccsm` entries assume laptop paths),
replacing `ansible/run-ansible.sh`, per-project volumes.
