# Vision: Gradle-Based Infrastructure Orchestration Platform

## The Thesis

Infrastructure-as-code tooling treats config files as opaque text blobs, resolves dependencies within a single repo, and leaves multi-tenant orchestration as an exercise for the reader. We're building a framework that treats IaC configs as structured ASTs, resolves dependency graphs across repositories, and composes infrastructure from versioned templates using semantic merges -- not git conflict resolution.

The framework is the product. We use it internally, we use it for client work, and we sell it as a managed platform.

## Three-Layer Business Model (PostHog-Style Open Core)

### Layer 1: The Engine (Open Source / Source-Available)

A Gradle-based infrastructure orchestration framework distributed as a set of repositories:

| Repository | Purpose | License | Why This License |
|---|---|---|---|
| `irl-hcl-parser` | ANTLR4 grammars + Kotlin AST for HCL, TF, JSON, YAML, Markdown | Apache 2.0 | Bait: maximum adoption, community contributions, no friction |
| `irl-gradle-plugin` | Core Gradle plugin: DSL, task graph, template engine, dependency resolution | BSL or FSL | Moat: visible, self-hostable, but competitors can't resell it |
| `irl-templates` | Community template library (cookiecutter-style scaffolds) | Apache 2.0 | Ecosystem: more templates = more users = more SaaS conversions |
| `irl-cli` | Thin wrapper / Gradle task aliases for ergonomic CLI usage | BSL or FSL | Pairs with plugin, same protection |

**The open source version must be genuinely useful standalone.** Not crippled. A single developer or small team should be able to run the full local workflow without paying us anything. The SaaS sells convenience and scale, not capability.

### Layer 2: The Platform (SaaS, Proprietary)

A managed service that operates the framework at scale:

- **Cross-repo DAG visualization**: see the full infrastructure graph across all tenants, templates, and environments
- **Managed applies**: push config, platform resolves dependencies and applies in order
- **Drift detection**: continuous monitoring of actual state vs. declared state across all tenants
- **Credential vault**: per-tenant credential scoping, rotation, and injection
- **Tenant lifecycle**: onboarding wizards, environment promotion, offboarding/handoff workflows
- **Audit trail**: every IaC change across every tenant, searchable and exportable
- **Template marketplace**: publish, discover, and adopt templates with semantic versioning

**Pricing tiers:**

| Tier | Target | What They Get |
|---|---|---|
| Free / OSS | Individual devs, small teams | Local Gradle plugin, CLI, parsers, templates |
| Team | Small agencies, startups | Hosted applies, drift detection, 5 tenants |
| Business | Mid-market consultancies | Unlimited tenants, credential vault, SSO |
| Enterprise | Large orgs | RBAC, compliance reporting, dedicated support, SLAs |

### Layer 3: The Consultancy (Services)

We use the framework for every client engagement. The client experiences their infrastructure managed through the platform. When the engagement ends:

- **Handoff option**: client gets their tenant repo, self-hosts the OSS engine
- **Retention option**: client stays on the SaaS tier (most will choose this)
- **Upgrade option**: client buys enterprise tier for their own multi-tenant needs

The tool sells itself because clients have been living inside it. Zero cold outreach needed for SaaS conversion.

## Technical Architecture

### Core Abstraction: Gradle as Infrastructure DAG

Gradle's multi-project build system maps directly to infrastructure dependency resolution:

| Infrastructure Concept | Gradle Equivalent |
|---|---|
| Resource group (e.g., `dev/cloudflare/zones`) | Subproject (`:dev:cloudflare:zones`) |
| Dependency between resource groups | `dependsOn` / `mustRunAfter` between tasks |
| Environment (dev, prod) | Project hierarchy level |
| Template | Convention plugin (applied via `plugins {}` block) |
| Tenant repository | Standalone Gradle project with composite build includes |
| Cross-repo dependency | Composite builds (`includeBuild()`) or published plugin coordinates |
| Plan / Apply / Destroy | Gradle tasks (`:plan`, `:apply`, `:destroy`) |
| Parallel execution | `--parallel` with worker API, respects DAG edges |
| Drift detection | Input/output fingerprinting (Gradle's up-to-date checking) |
| Credential scoping | Gradle property cascade: root -> project -> local -> env |
| CLI commands | Gradle task paths: `./gradlew :prod:cloudflare:zones:apply` |

### Dual-Mode Infrastructure Definition

The framework supports both declarative templates and programmatic generation:

**Mode 1: Template files** -- raw `.tf`, `.hcl`, `.json`, `.yaml` files in a directory structure. The framework parses them into ASTs, applies transforms (variable substitution, merge with overrides), and emits final config files for Terraform/Terragrunt to consume.

**Mode 2: Kotlin DSL** -- type-safe infrastructure definition directly in `build.gradle.kts`:

```kotlin
infiniteRoom {
    tenant {
        type = TenantType.CLIENT
        name = "acme-corp"
        lifecycle = Lifecycle.MANAGED  // vs EPHEMERAL, HANDOFF
    }

    cloudflare {
        zones("acme.com", "acme.dev")
        // bootstrap token auto-injected from global dependency
    }

    porkbun {
        // nameserver delegation auto-wired from zones output
    }
}
```

Both modes produce the same intermediate representation (IR). The DSL compiles to IR directly; template files are parsed to AST then lowered to IR. This means you can mix and match -- DSL for orchestration logic, template files for provider-specific resources.

### The AST Engine (Technical Differentiator)

Most IaC tools treat config files as opaque text. We parse them into structured ASTs using ANTLR4 grammars with Kotlin backends. This enables:

**Semantic merging**: when a template is updated (v1.2 -> v1.3), tenant overrides are merged at the AST level, not the text level. The framework understands HCL block structure, so it can merge a new `resource` block from the template alongside a tenant's custom `resource` block without conflicts.

```
Template AST (v1.2)  +  Tenant Override AST  =  Merged AST  ->  emit .tf files
        |                                             |
   update template                          three-way AST merge
        |                                    (structural, not textual)
Template AST (v1.3)  +  Tenant Override AST  =  Merged AST  ->  emit .tf files
```

**Static analysis**: validate configurations before apply. Type-check variable references, detect circular dependencies, flag security issues (public S3 buckets, overly permissive IAM).

**Code generation**: emit not just Terraform configs but also documentation, CI/CD pipelines, monitoring dashboards, runbooks -- all from the same AST.

**Grammars needed** (ANTLR4, Kotlin target):

| Grammar | Priority | Why |
|---|---|---|
| HCL2 | P0 | Terraform and Terragrunt configs |
| Terraform (HCL2 superset) | P0 | `.tf` files with Terraform-specific constructs |
| JSON | P1 | State files, API responses, tfvars |
| YAML | P1 | CI/CD configs, Kubernetes manifests, Ansible |
| Markdown | P2 | Documentation generation, template READMEs |
| TOML | P3 | Cargo configs, misc tooling |

### Repository Ecosystem

All repos live under `~/projects/infinite-room-labs/` and are GitHub-hosted under the `InfiniteRoomLabs` org:

```
~/projects/infinite-room-labs/
  infinite-room-labs-infra/      # PRIVATE - company IaC (current repo, the proving ground)
  irl-hcl-parser/                # PUBLIC  - ANTLR4 grammars + Kotlin AST library
  irl-gradle-plugin/             # SOURCE-AVAILABLE - core Gradle plugin
  irl-templates/                 # PUBLIC  - community template library
  irl-cli/                       # SOURCE-AVAILABLE - CLI wrapper
  irl-platform/                  # PRIVATE - SaaS platform (API, dashboard, workers)
  agent-ops/                     # PRIVATE - Claude Code plugin marketplace (existing)
```

**Dependency flow between repos:**

```
irl-hcl-parser (library)
    |
    v
irl-gradle-plugin (depends on parser)
    |
    v
irl-templates (uses plugin)      irl-cli (wraps plugin)
    |                                |
    v                                v
infinite-room-labs-infra (uses plugin + templates, proving ground)
    |
    v
irl-platform (hosts and orchestrates everything above)
```

### Template Composition via Gradle

Tenant repos consume templates as Gradle convention plugins:

```kotlin
// settings.gradle.kts (tenant repo)
pluginManagement {
    repositories {
        maven("https://maven.pkg.github.com/InfiniteRoomLabs/*")
        gradlePluginPortal()
    }
}

// build.gradle.kts (tenant repo)
plugins {
    id("com.infiniteroomlabs.tenant-baseline") version "1.2.0"
    id("com.infiniteroomlabs.cloudflare-site") version "2.0.1"
    id("com.infiniteroomlabs.monitoring-stack") version "1.0.0"
}
```

For local development or pre-release testing, composite builds:

```kotlin
// settings.gradle.kts
includeBuild("../irl-gradle-plugin")   // use local checkout
includeBuild("../irl-templates")       // use local templates
```

Template updates are adopted by bumping the version in `plugins {}`. The AST engine handles merging template changes with tenant-specific overrides at apply time.

### Gradle as CLI Framework

The task tree IS the CLI:

```bash
# Planning
./gradlew :plan                              # plan everything
./gradlew :dev:plan                          # plan dev environment
./gradlew :dev:cloudflare:zones:plan         # plan specific resource group

# Applying
./gradlew :apply                             # apply everything (DAG-resolved order)
./gradlew :prod:apply                        # apply prod environment
./gradlew :bootstrap:apply                   # run bootstrap layer only

# Lifecycle
./gradlew :onboard --tenant=acme --type=client
./gradlew :teardown --tenant=sandbox-42
./gradlew :handoff --tenant=acme --target-org=AcmeCorp

# Observability
./gradlew :drift                             # check all tenants for drift
./gradlew :graph                             # print dependency graph
./gradlew :audit --since=2026-01-01          # show all changes since date

# Templates
./gradlew :template:list                     # list available templates
./gradlew :template:update                   # check for template version bumps
./gradlew :template:diff --from=1.2 --to=1.3 # show AST diff between versions
```

## Tenant Type Taxonomy

| Type | Lifecycle | Ownership | Isolation | Billing | Example |
|---|---|---|---|---|---|
| Client | Engagement-scoped, handoff possible | Shared during engagement, transferred at end | Full (own TFC org or workspace set) | Per-client, pass-through or bundled | Agency client website/infra |
| SaaS Product | Long-lived, evolving | Internal team | Environment-level (dev/staging/prod) | Product cost center | Our own products |
| Internal Tooling | Long-lived, stable | Engineering team | Shared namespace | Overhead | CI/CD, dev environments, agent infra |
| Open Source | Long-lived, community-driven | Community + us | Public resources only | Marketing cost center | Docs sites, package registries |
| Ephemeral/Sandbox | Hours to weeks, auto-teardown | Individual or team | Fully isolated, disposable | Time-boxed budget | Demos, experiments, spikes |
| Vendor Integration | Long-lived, config-heavy | Internal + vendor | Per-vendor credentials | Per-vendor billing | Stripe, Twilio, SendGrid configs |
| Partner/Reseller | Medium-lived, co-managed | Shared with partner | Partial isolation | Revenue-share | White-label deployments |

## Strategic Advantages

**The ANTLR4 parser play**: there is no good standalone HCL parser for the JVM ecosystem. Building one and releasing it as Apache 2.0 makes every Kotlin/Java/Scala shop working with Terraform a potential user, contributor, and customer. Same strategy JetBrains uses with language grammars feeding IDE plugin adoption.

**Gradle ecosystem leverage**: millions of developers already know Gradle. The learning curve for our framework is "learn our DSL", not "learn a whole new build system". IDE support (IntelliJ) comes nearly free -- autocompletion, refactoring, navigation all work on Kotlin DSL out of the box.

**Consultancy-to-SaaS pipeline**: every client engagement is a live demo of the platform. Client retention after handoff is the SaaS conversion event. No cold outreach, no sales team needed at early stage.

**Template marketplace network effects**: more templates attract more users, more users contribute more templates, more templates attract more users. The marketplace becomes a moat that compounds over time.

## Open Questions for Design Phase

1. **Terraform wrapper vs. native providers**: do we shell out to `terraform apply` or implement provider interactions directly in Kotlin? (Likely: wrap Terraform initially, build native provider SDK as a future differentiator)
2. **State storage**: TFC for now, but should the platform have its own state backend? (Likely: support multiple backends, TFC as default)
3. **ANTLR4 grammar sourcing**: write HCL grammar from scratch or adapt existing community grammars? (Research needed)
4. **Plugin distribution**: GitHub Packages Maven registry, Gradle Plugin Portal, or both?
5. **Licensing specifics**: BSL (MariaDB/Sentry model) vs FSL (HashiCorp model) vs AGPL (PostHog model) for source-available components
6. **Naming**: `irl-*` prefix works for now, but the product/platform needs a real name

## Proving Ground

The current `infinite-room-labs-infra` repo is the proving ground. Every pattern we build into the framework should first be validated here against real infrastructure (Cloudflare zones, Porkbun nameservers, TFC workspaces). The progression:

1. **Now**: Terraform + Terragrunt, manual applies, single repo
2. **Next**: Gradle wrapper around Terragrunt, task graph replaces `run-all`
3. **Then**: AST engine parses and transforms HCL, Gradle plugin provides DSL
4. **Later**: Multi-repo template composition, tenant onboarding automation
5. **Platform**: Hosted orchestration, drift detection, audit dashboard
