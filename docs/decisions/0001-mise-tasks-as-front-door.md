# 0001. mise tasks as the repo CLI front door (no bespoke binary)

Date: 2026-05-29

## Status

Accepted

## Context

This is a multi-tool IaC monorepo (Terraform/Terragrunt, Ansible, Helm submodule, Packer, Docker) operated by a very small team. Every operational entry point is a shell script or a third-party CLI with its own invocation quirks, and most of them need secrets.

Before 2026-05-29 the repo had no single command surface: secrets loaded ambiently via `.envrc` files and `~/.secrets/` reads, and operators had to know which script to call with which environment. Commit `55c5c5d` (2026-05-29, "feat(secrets): migrate env-var secrets to fnox + add mise/usage tooling") replaced that with three cooperating layers, recorded in `CHANGELOG.md`:

- **fnox** injects env-var secrets per-command via `scripts/with-secrets.sh`; both `.envrc` files were deleted and nothing loads secrets ambiently.
- **mise** (`mise.toml`) pins the IaC toolchain (today: terraform, packer, terragrunt, helm, kubectl, task, fnox, usage) to explicit versions -- one aqua-backend helper (`mcp-grafana`) floats on `latest`, the lone exception to the header comment's no-`latest` policy -- and defines a `[tasks]` runner: `bootstrap`, `secrets:sync`, `secrets:check`, `secrets:verify-k8s`, `ansible`, `test:smoke`, `test:validate` (later `test:hygiene`, added with the 2026-08 repo-hygiene suite).
- **usage** gives the argument-bearing scripts (`bootstrap.sh`, `bw-sync.sh`, `run-ansible.sh`) a declarative arg spec (`#!/usr/bin/env -S usage bash`, `#USAGE` directives), covering the "real argument parsing" need without a compiled binary.

The question this ADR pins down: should the front door stay a task runner, or should the repo grow a bespoke CLI binary?

Prior-art research (docs/plans/resources/2026-07-23-public-showcase-conventions.md, Thread 2, salvaged 2026-07-28) surveyed admired homelab/GitOps repos and CLI doctrine (clig.dev, taskfile.dev):

- Its cross-repo pattern list opens with "Task runner as the front door (go-task / Taskfile / mise) -- almost never a bespoke compiled CLI"; the surveyed Terraform+Ansible peers (chrisleekr/homelab-infrastructure, omdv/homelab-server) and the Talos+Flux onedr0p/cluster-template all use task/Taskfile as the primary command interface.
- It records when a bespoke CLI is justified: real argument parsing/validation, subcommand trees, stateful multi-step flows, rich/interactive output, single-binary distribution, or config-hierarchy resolution beyond YAML recipes -- and concludes that "if a task runner already meets it, the binary is unjustified overhead".
- It notes mise tasks specifically "fold tool-version pinning + task running into one file".

The repo's tasks are thin one-line delegations to scripts (secret-needing ones through `with-secrets.sh`); none exhibit the stateful-flow or rich-output traits that would justify a binary.

## Decision

`mise run <task>` is the canonical CLI front door for this repository. We will not build a bespoke CLI binary.

Concretely:

- Operational entry points are declared in `mise.toml [tasks]`, each a thin wrapper over a script; secret-needing tasks go through `scripts/with-secrets.sh` (fnox per-command injection), never ambient env.
- Non-secret identifiers live in `mise.toml [env]`; anything sensitive lives in fnox (`mise.toml` header and inline comments state this invariant).
- Argument-heavy scripts use `usage` arg specs rather than hand-rolled parsing, so the "real argument parsing" trigger for a bespoke binary stays unmet.
- go-task is retained but scope-limited: `tests/Taskfile.yml` drives the acceptance suite (`task smoke`, `task validate`, per TESTING.md), and the mise tasks `test:smoke`/`test:validate` delegate into it (`dir = "tests"`). go-task itself is version-pinned by mise (`task = "3.49.1"`), so mise remains the single top-level entry.
- The README is written mise-first: Quick Start is `mise install`, discovery is `mise tasks`, and the operating rules say "Use a mise task when one exists" and to run Ansible via `mise run ansible -- ...` (CHANGELOG 2026-07-28 entry: "README restructured around a 'Start Here' task table ... setup section rewritten as a mise-first Quick Start").

The date above is when the front door landed (`55c5c5d`, 2026-05-29). The 2026-07-23 prior-art research reaffirmed the choice against the bespoke-binary alternative rather than prompting it.

## Consequences

Positive:

- One file (`mise.toml`) answers both "what versions do we run" and "what can I do here" -- `mise tasks` is the discovery surface, and version drift between operators disappears behind the pins.
- The secrets invariant is structurally enforced at the front door: every secret-needing task routes through `with-secrets.sh`, so following the documented path cannot leak ambient credentials.
- Zero build/release/distribution pipeline for the command surface; adding an entry point is a TOML stanza plus a script, reviewable in a normal diff.
- The layout matches the dominant convention in comparable public repos (per the 2026-07-23 research), which lowers reading cost for outside reviewers if the repo is showcased.

Negative / accepted costs:

- Contributors must have mise installed and activated before anything works; `mise install` is a hard prerequisite (README Quick Start), and running scripts directly bypasses both the version pins and the secrets wrapper.
- Task recipes are one-liners with no argument validation of their own; anything needing flags leans on `usage` specs in the underlying scripts, and pass-through invocations (`mise run ansible -- playbook ...`) are less discoverable than a subcommand tree would be.
- Two task runners coexist (mise at the root, go-task under `tests/`). The seam is contained by delegation, but it is a real inconsistency a contributor can trip over.
- If a genuinely stateful, interactive, or distributable workflow appears later, the research's own criteria say a bespoke layer becomes justifiable; this ADR should then be revisited rather than silently outgrown.
