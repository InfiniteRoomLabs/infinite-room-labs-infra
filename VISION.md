# Vision

An earlier version of this document sketched a much bigger destination. This version is deliberately smaller: it describes what this repo is for, how it's operated, and the design ideas I'm still exploring. The tools are the point.

## What this repo is

The working infrastructure of Infinite Room Labs: a k3s cluster spanning an on-prem HP Z600 and a cloud agent node, managed end to end with Terraform, Terragrunt, Ansible, and Helm, and operated day to day by AI agents working under enforced policy. It's a production homelab, a proving ground, and the place where infrastructure ideas find out whether they survive contact with reality.

## Operating thesis: agents under policy

The interesting part of this repo isn't the stack, it's the operating model. Running infrastructure agentically only works when the boundaries are code, so that's how they're built:

1. **Agents propose, policy disposes.** Changes flow through the same gate regardless of who or what authored them: conftest runs the OPA policies in `policy/`, kubeconform validates manifests, and Trivy scans for known vulnerabilities, all in CI.
2. **Ratchets only tighten.** `readonly-rootfs-ratchet.rego` is the pattern: once a workload runs with a read-only root filesystem, policy prevents it from ever quietly regressing. Security posture is a one-way door.
3. **The paved path is the only path.** Helm charts are deployed exclusively through the phase-tagged Ansible playbooks; nothing is installed by hand. If the paved path can't do something, the fix is to improve the path, not to route around it.
4. **If it isn't written down, it didn't happen.** Every operational scenario gets a runbook or SOP (`ansible/docs/`), so an agent or a tired human at 2 AM executes the same recovery the same way. Disaster recovery for the agentic workstation itself is a runbook like any other.
5. **Secrets never touch the repo or the shell.** Bitwarden is the single source of truth, injected per command via fnox, synced to Ansible Vault and Kubernetes Secrets by one script that also enforces rotation ages.

Everything else in the README (the split DNS, the tunnel-only ingress, the ZFS snapshot policy) is this thesis applied to a specific layer.

## Design explorations (held loosely)

The long-horizon itch: IaC tooling treats config files as opaque text blobs, resolves dependencies within a single repo, and leaves multi-repo composition as an exercise for the reader. I keep circling a different shape, where configs are structured ASTs, dependency graphs span repositories, and templates compose through semantic merges instead of git conflict resolution.

The ideas, in rough order of pull:

### Gradle as the infrastructure DAG

Gradle's multi-project build system maps almost one-to-one onto infrastructure dependency resolution:

| Infrastructure concept | Gradle equivalent |
|---|---|
| Resource group (e.g., `dev/cloudflare/zones`) | Subproject (`:dev:cloudflare:zones`) |
| Dependency between resource groups | `dependsOn` / `mustRunAfter` between tasks |
| Environment (dev, prod) | Project hierarchy level |
| Template | Convention plugin (applied via `plugins {}` block) |
| Cross-repo dependency | Composite builds (`includeBuild()`) or published plugin coordinates |
| Plan / apply / destroy | Gradle tasks (`:plan`, `:apply`, `:destroy`) |
| Parallel execution | `--parallel` with the worker API, respecting DAG edges |
| Drift detection | Input/output fingerprinting (Gradle's up-to-date checking) |
| Credential scoping | Property cascade: root, project, local, environment |

The appeal is that millions of developers already know Gradle, and IntelliJ-grade IDE support for a Kotlin DSL comes nearly free.

### Semantic merges via ASTs

Parse HCL, Terraform, JSON, and YAML into real ASTs (ANTLR4 grammars, Kotlin backends) instead of treating them as text. That unlocks three-way structural merges (template v1.3 plus tenant overrides, merged at the block level with no textual conflicts), static analysis before apply (type-checked variable references, circular-dependency detection, security lints), and generation of docs and pipelines from the same tree. There is still no good standalone HCL parser for the JVM ecosystem; building one would be useful far beyond this repo.

### Multi-repo template composition

Tenant-style repos consuming versioned templates as Gradle convention plugins, with composite builds for local development and version bumps as the template-update mechanism. This is the piece that only matters once the first two exist, so it stays a sketch.

The detailed design exploration lives in [PROMPT.md](./PROMPT.md). None of this is a roadmap. Each idea graduates only by being validated here first, against real infrastructure, the same way everything else in this repo earned its place.

## Progression

1. **Now**: Terraform + Terragrunt, agent-operated under policy, single repo
2. **Next**: a Gradle wrapper around Terragrunt; the task graph replaces `run-all`
3. **Then**: the AST engine parses and transforms HCL; a Gradle plugin provides the DSL
4. **Later**: multi-repo template composition

## What this is not

This is not a product plan. There's no company being built here and no platform on a roadmap: it's a workshop. Ideas earn their way in by working, and anything worth sharing ships as open source alongside the rest of the org's repos.

## Open questions

1. **Terraform wrapper vs. native providers**: shell out to `terraform apply`, or implement provider interactions directly? (Likely: wrap Terraform first; a native path is a distant maybe.)
2. **State storage**: Terraform Cloud works today; a Gradle layer should probably stay backend-agnostic.
3. **Grammar sourcing**: write the HCL grammar from scratch or adapt existing community grammars? (Research needed.)
