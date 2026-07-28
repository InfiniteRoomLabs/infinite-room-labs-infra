# Public-Showcase Repo Conventions -- Prior-Art Research

> Salvaged 2026-07-28 from the 2026-07-23 research-agent session (report was delivered in-session to the team lead and never landed on disk). Read-only prior-art survey; no IRL-specific recommendations yet. Supports the public-readiness effort (see RESEARCH.md R16 and the agent-ops `public-readiness` skill).


Read-only web research, structured by your four threads. Named patterns + URLs throughout. No recommendations tailored to us yet -- just what the field does.

---

## Thread 1 -- Showcase homelab / GitOps repos the community admires

The canonical "admired" tier is the **Flux GitOps homelab** lineage: onedr0p -> bjw-s -> the cluster-template ecosystem -> k8s-at-home/kubesearch. They share a remarkably consistent playbook.

**onedr0p/home-ops** -- https://github.com/onedr0p/home-ops (docs site: https://onedr0p.github.io/home-ops/)
- *Comprehensibility*: strict directory convention -- `kubernetes/apps/` (apps), `kubernetes/components/` (reusable kustomize components), `kubernetes/flux/` (flux system config). Talos + Flux, semi-hyperconverged. README leads with a hardware table, a tech-stack table (each tool + one-line "why"), and a networking/DNS section.
- *One place to declare a service*: a per-app kustomization directory; Flux reconciles it. Adding a service = add a folder + HelmRelease, nothing imperative.
- *Proving claims*: **Renovate** watches the whole repo and opens dependency-bump PRs; on merge **Flux** applies. GitHub Actions run validation. This "Renovate proposes -> Flux applies" loop is the signature move.

**bjw-s-labs/home-ops** -- https://github.com/bjw-s-labs/home-ops (GitHub mirror of self-hosted https://git.bjw-s.dev/bjw-s/home-ops)
- Same Flux + Renovate + GitHub Actions spine. Notable extra signal: mirrors a *self-hosted git* to GitHub (dogfoods own infra, but keeps public visibility). Heavy use of shared/templated HelmRelease values to keep per-app declarations tiny.

**onedr0p/cluster-template** -- https://github.com/onedr0p/cluster-template
- The productized version of the above: a template repo that scaffolds a Talos + Flux cluster. **Front door is `task` (go-task)** -- `task init`, `task configure`, `task bootstrap`. Uses a single `config.yaml` / SOPS-encrypted values as the "one place to declare intent," then renders manifests. This is the clearest example of "task-runner-as-CLI-front-door" in the space.

**khuedoan/homelab** (referenced in your brief) and peers -- the Terraform+Ansible+k3s tier: e.g. **chrisleekr/homelab-infrastructure** (https://github.com/chrisleekr/homelab-infrastructure) uses a **Taskfile.yml as the primary command interface** across a two-stage Ansible-bootstrap -> Terraform-app-stack flow; **omdv/homelab-server** (https://github.com/omdv/homelab-server) is a go-task + Ansible + Terraform monorepo with ArgoCD/Vault. Task runners (go-task or Taskfile) are near-universal as the orchestration front door in this tier.

**k8s-at-home / kubesearch.dev ecosystem** -- https://kubesearch.dev/ (indexer: https://github.com/whazor/k8s-at-home-search)
- *This is a verifiability pattern in its own right*: it indexes Flux `HelmRelease` configs across all public repos tagged `k8s-at-home`/`kubesearch`. Tagging your repo opts you into a public, cross-repo, real-world-config search engine -- the community's shared "prove it in public" surface. Being *in* kubesearch is a soft credibility badge.

**What makes them comprehensible (recurring):** README opens with hardware table + tech-stack table (tool + one-line rationale) + a Mermaid/network diagram; strict `apps/ components/ flux/` (or `terraform/ ansible/`) directory split; SOPS/sealed-secrets so secrets are *visible-but-encrypted* in-repo; badges for CI + Renovate + Discord.

---

## Thread 2 -- CLI + automation ergonomics doctrine

**clig.dev (Command Line Interface Guidelines)** -- https://clig.dev/ (repo: https://github.com/cli-guidelines/cli-guidelines)
Top principles relevant to wrapping a repo in a CLI:
1. **Human-first design** -- if humans are the primary users, design for them first; machine output is secondary.
2. **Composability** -- machine data to stdout, messaging to stderr, honor exit codes so commands chain.
3. **Discoverability** -- help text, examples, contextual "next command" suggestions; usage should be a conversation, not memorization.
4. **Consistency** -- reuse hardwired conventions: `-h/--help`, `-f/--force`, `--json`, `--dry-run`, `--plain`.
5. **Appropriate information density** -- progress for long ops, confirm dangerous actions, no log-spam.
- Concrete guidelines: help by default when run with no args; lead help with examples; detect TTY and default human-readable, `--json` for scripts, `--plain` for grep/awk; **error messages as teaching** ("Can't write X. Try `chmod +w X`"); prefer named flags over positional; **never take secrets via flags** (files/stdin); correct exit codes; idempotent/crash-only ops; config hierarchy flags -> env -> project config -> user config -> defaults (respect XDG).

**The case FOR just using a task runner (no bespoke binary):**
- **Task/Taskfile** (https://taskfile.dev/) -- YAML, cross-platform, "a runner not just a builder," familiar to anyone who's touched CI YAML; fixes Make's tab/variable pain. **just** -- terse recipe syntax (a 3-line just recipe balloons to ~8 in Taskfile). **mise tasks** -- folds tool-version pinning + task running into one file. Comparison writeups: https://botmonster.com/self-hosting/just-vs-make-vs-task-modern-command-runner/ , https://marmelab.com/blog/2026/03/12/taskfile-alternative-makefile.html
- Consensus in the writing: task runners cover the overwhelming majority of "wrap my repo's operations" needs. The homelab showcase repos (Thread 1) validate this empirically -- nearly all use task/Taskfile/mise, **not** a compiled CLI.

**When a bespoke CLI is justified (from the doctrine):** when you need real argument parsing/validation, subcommand trees, stateful multi-step flows, rich/interactive output, distribution as a single binary, or config-hierarchy resolution beyond what YAML recipes express. The clig.dev guidance is essentially "the checklist you must satisfy" once you cross that line -- if a task runner already meets it, the binary is unjustified overhead.

**Terminal UX polish if a bespoke layer is warranted -- charm.sh** (https://charm.land/):
- **gum** -- drop interactive UI (menus, input prompts, confirms, file pickers, spinners) into plain bash/zsh with zero Go; the low-effort way to make shell scripts feel polished (https://github.com/charmbracelet/gum).
- **bubbletea** -- full Elm-architecture TUI framework in Go for when you're building an actual binary (https://github.com/charmbracelet/bubbletea). Pairs with Lip Gloss (styling) + Bubbles (components).
- Reasonable ladder: task runner -> task runner + gum for interactive bits -> bubbletea binary only if you truly need a TUI.

---

## Thread 3 -- Comprehension / docs & scaffolding frameworks

**Diátaxis** -- https://diataxis.fr/ (start: https://diataxis.fr/start-here/)
- Four modes on a 2×2 (acquisition↔application, action↔cognition): **Tutorials** (learning-oriented, hand-held), **How-to guides** (task-oriented, user already knows the domain), **Reference** (information-oriented, dry facts), **Explanation** (understanding-oriented, the "knowledgeable friend"). Created by Daniele Procida; adopted org-wide by Canonical/Ubuntu (https://ubuntu.com/blog/diataxis-a-new-foundation-for-canonical-documentation). This is the dominant docs taxonomy well-regarded infra projects reach for.

**ADRs / MADR** -- https://adr.github.io/madr/ (tooling index: https://adr.github.io/adr-tooling/ , examples: https://github.com/joelparkerhenderson/architecture-decision-record)
- **Nygard format** = lowest-friction; **adr-tools** = bash scripts to manage Nygard ADRs. **MADR** (Markdown Any Decision Records) adds explicit *decision drivers* + *considered options* -- helpful for teams that struggle to articulate consequences, "overhead" for teams already writing good ADRs.
- **log4brains** -- https://github.com/thomvaill/log4brains -- renders an ADR directory into a searchable static site ("docs-as-code" published knowledge base). The publish-your-decisions pattern.

**C4 model** -- https://c4model.com/ -- hierarchical architecture diagrams: Context -> Container -> Component -> Code, plus system-landscape/dynamic/deployment supporting diagrams. Developer-friendly, tool-agnostic; pairs naturally with Mermaid (which has native C4 support).

**arc42** -- https://docs.arc42.org/ -- a full architecture-doc template (goals, constraints, context, building blocks, runtime, deployment, quality, risks, and §9 "Architecture Decisions" which folds ADRs in). "arc42-lite"/"architecture haiku" = deliberately trimmed one-page versions for small projects.

**What infra repos actually adopt vs skip:** they adopt Diátaxis-*flavored* structure (a `docs/` split into how-to/reference/explanation) + ADRs (often just a `docs/adr/` or `docs/decisions/` folder of markdown, frequently Nygard/MADR) + Mermaid diagrams inline in READMEs. They mostly *skip* heavyweight arc42 full templates, log4brains static-site publishing, and formal C4 tooling (they draw C4-ish diagrams in Mermaid instead of adopting the toolchain).

**Scaffolding -- "add a new service" generators:**
- **copier vs cookiecutter** (https://dev.to/cloudnative_eng/copier-vs-cookiecutter-1jno): the decisive difference is **update propagation**. Copier tracks template origin via `.copier-answers.yml` and does a 3-way merge on `copier update`, so already-generated services can pull later template improvements. Cookiecutter is one-shot (cleaner initial output, no update path). For a monorepo where every service should stay in sync with an evolving template, **Copier is the standout**; Cookiecutter fits fire-and-forget.
- **Backstage software templates / scaffolder** -- https://backstage.io/docs/features/software-templates/ -- golden-path repo scaffolding via a self-service portal. Explicitly built for org-scale platform teams: "requires platform team involvement for every new use case," central template repo, catalog, portal UI. For one person it's enormous operational overhead (runs a whole Backstage app + catalog) to replace what a Copier template + a task recipe do in a few files. Cite as *inspiration for the golden-path idea*, not as something to run solo.

---

## Thread 4 -- Verifiability / zero-trust-as-exhibit

Patterns that let a stranger verify claims without trusting the author, ranked by high-signal-per-effort for a solo operator.

**High-signal, low-effort (config-scan / policy-as-code -- lives in-repo, runs in CI):**
- **kubeconform** -- schema-validate every manifest in CI (fast, catches broken YAML/CRDs). Cheap, high trust.
- **conftest / OPA (Rego)** -- policy-as-code assertions over manifests/Terraform plans ("no `:latest` tags", "resources have limits", "no privileged pods"). Visible policy files = zero-trust made legible.
- **checkov** and **trivy config** -- IaC/misconfig scanners for Terraform + k8s + Dockerfiles; both emit SARIF that renders in the GitHub Security tab. Trivy also does image CVE scanning. Practical guide: https://www.youngju.dev/blog/devops/2026-03-13-container-image-security-trivy-cosign-sbom-supply-chain.en
- **CI badges tied to real acceptance tests** -- a green badge is only a zero-trust exhibit if it runs *actual* validation (kubeconform + conftest + smoke tests), not a no-op. This is the cheapest credibility lever and the homelab showcase repos lean on it hard.

**High-signal, moderate-effort (drift + supply chain):**
- **Scheduled drift detection with published results** -- a cron GitHub Action runs `terraform plan` / flux diff and **opens a GitHub Issue on drift**. Pattern refs: Cloud Posse's atmos drift-detection action (https://github.com/cloudposse/github-action-atmos-terraform-drift-detection), Azure sample tf-drift workflow (https://github.com/Azure-Samples/terraform-github-actions/actions/workflows/tf-drift.yml). The *published* drift result (issue/badge) is the exhibit -- it proves the repo actually matches reality on a schedule.
- **Flux diff / Renovate PRs** (from Thread 1) double as verifiability: every change arrives as a reviewable PR with a diff; nothing lands imperatively. The PR history *is* the audit log.
- **Signed commits** -- GPG/SSH-signed commits + "Verified" badges on GitHub; low effort, direct authorship provenance.

**Higher-effort (image provenance / SLSA -- strongest but heaviest):**
- **SBOM + SLSA provenance + keyless cosign signing**, verified at admission by **Kyverno/Sigstore policy-controller**. The modern chain: build -> Syft SBOM -> SLSA provenance attestation -> keyless cosign sign (Fulcio cert + Rekor transparency log) -> push -> Kyverno verifies signature+provenance+SBOM before a pod runs. Refs: Kyverno verify-image-slsa policy (https://kyverno.io/policies/other/verify-image-slsa/verify-image-slsa/), practical walk-through https://medium.com/@Juan_Makau/securing-the-software-supply-chain-signing-attesting-and-enforcing-container-images-in-e6f5d459b00d
- *Solo-operator caveat*: only high-signal **if you actually build images**. For a repo that mostly consumes upstream charts/images, full SLSA is closer to performative -- the verify-effort/payoff is poor vs. policy scans + drift detection.

**Public-dashboard patterns:** Grafana **snapshots** (shareable read-only dashboard states), status pages, public uptime badges. Genuinely high-signal *if* the underlying checks are real; risk of being performative if the dashboard is decorative.

**Performative vs high-signal (the honest split):** high-signal = CI that runs real validation + published drift results + visible policy files + PR-only changes + signed commits. Performative-risk = badges with no teeth, decorative dashboards, and full SLSA/SBOM chains on a repo that doesn't build anything.

---

## Patterns that repeatedly appear across admired repos (≤10)

1. **Task runner as the front door** (go-task / Taskfile / mise) -- almost never a bespoke compiled CLI.
2. **Strict, conventional directory split** -- `apps/ components/ flux/` or `terraform/ ansible/ helm/`; one folder = one declared service.
3. **"One place to declare a service"** -- add a folder + a HelmRelease/module; a reconciler (Flux/Argo) applies it. No imperative steps.
4. **Renovate + GitOps reconcile loop** -- bot proposes dependency PRs, Flux/Argo applies on merge; PR history is the audit log.
5. **README = hardware table + tech-stack table (tool + one-line "why") + a diagram** (Mermaid, C4-flavored), plus CI/Renovate/Discord badges.
6. **Secrets visible-but-encrypted in-repo** (SOPS / sealed-secrets) -- provable handling without exposing values.
7. **ADRs in a `docs/adr|decisions/` folder** (Nygard/MADR markdown) + Diátaxis-flavored docs split; heavyweight arc42/log4brains usually skipped.
8. **CI that actually validates** -- kubeconform + conftest/OPA + smoke tests behind the green badge; SARIF to the Security tab.
9. **Scheduled drift detection with published output** (issue/badge) proving repo matches live reality.
10. **Public discoverability as credibility** -- opting into kubesearch.dev / k8s-at-home, mirroring self-hosted git to GitHub, sharing Grafana snapshots.

