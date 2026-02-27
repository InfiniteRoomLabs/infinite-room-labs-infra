# Gradle-Based IaC Platform Design

**Date:** 2026-02-26
**Status:** Approved
**Author:** Deep-think brainstorming session (5-idea debate with 3 orchestrated agent teams)

## Context

Infinite Room Labs needs an infrastructure orchestration framework that:
- Uses ANTLR4 to parse HCL/Terraform configs into ASTs on the JVM (Kotlin)
- Provides a Gradle plugin as the core standalone product
- Supports a Kotlin DSL and raw template files, both compiling to a shared IR
- Enables semantic AST-level merging of template updates with tenant overrides
- Resolves infrastructure dependencies as a DAG (within and across repos)
- Supports extension via custom JARs/Kotlin scripts that define DSLs
- Is wrapped by a thin platform layer (web API + CLI + UI) running ephemeral containers
- Self-hosts: the platform manages its own infrastructure as a tenant

The proving ground is the existing `infinite-room-labs-infra` Terraform + Terragrunt monorepo.

## Key Decisions

| Decision | Answer |
|----------|--------|
| Product name | TBD -- `irl-*` as working names |
| First user | Solo dogfooding |
| Phase 1 scope | Full scope including bootstrap layer |
| Repo strategy | Separate repos from day one |
| Sequencing | Plugin -> Parser -> IR/Merge -> Platform |
| Approach | Shell-first, compiler-later (Approach B) |

## Architectural Synthesis

Two structured debates (Compiler Pipeline vs Package Manager, Reactive Dataflow Graph vs Layer Cake) each ran 3 rounds with dedicated advocates and produced independent syntheses that converged on the same insight: **the user-facing abstraction should differ from the execution primitive.**

### Converged Pipeline

```
Version Resolution (SAT/lockfile) -> Parse to AST -> Lower to IR -> Merge Pass (origin-tagged) -> Validation Passes -> Config Emission
```

### Architecture Layers

| Layer | What Users See | What the Engine Does |
|-------|---------------|---------------------|
| Distribution | Packages, manifests, lockfiles, registries | SAT-based version resolution |
| Organization | Layers (bootstrap -> global -> env -> tenant -> resource group) | @ConventionLayer annotations on graph nodes |
| Execution | `./gradlew :dev:cloudflare:zones:apply` | Reactive DAG with input/output fingerprinting |
| Synthesis | "Template updated, your overrides preserved" | Compiler pipeline: ANTLR4 -> origin-tagged ASTs -> IR -> merge -> validate -> emit |
| Security | "This field is sealed / overridable" | Default-deny (SEALED unless explicitly TENANT_CAN_OVERRIDE) |
| Extension | "Add a custom JAR/Kotlin script" | Compiler passes on IR + Gradle plugins for distribution |

### Key Insights from Debates

**Batch 1 (Compiler Pipeline vs Package Manager):**
- Origin tracking is architecturally decisive -- the IR MUST be constructed from separately-parsed template and tenant ASTs, not from already-merged content
- Resolution failures are loud (version conflicts surface immediately); IR failures are silent (wrong merges deploy successfully). For infrastructure, optimizing for silent failure prevention means the IR must be the foundation
- Every successful IaC system (CDK, Pulumi, Nix) organized distribution first, added synthesis downstream
- **Verdict:** Package-organized externally, compiler-implemented internally

**Batch 2 (Reactive Dataflow Graph vs Layer Cake):**
- The bootstrap layer's upward references (workspace names derived from downstream paths) fatally crack the pure layer model
- Lateral dependencies (zones -> nameservers) are common, not exceptional -- forcing them into layers creates friction
- Layer Cake's strongest contribution is multi-tenant merge security (structural sealing) and blast radius communication
- **Verdict:** Reactive graph for execution, layer conventions for security and UX

## Repo Layout

```
infinite-room-labs/
  irl-hcl-parser/          # Apache 2.0 -- ANTLR4 grammars + Kotlin AST library
    grammar/               # .g4 files (lexer + parser)
    ast/                   # Kotlin AST node types
    ir/                    # IR lowering (Phase 3)
    merge/                 # Semantic merge engine (Phase 3)

  irl-gradle-plugin/       # BSL/FSL -- The core product
    plugin/                # Gradle plugin implementation
      src/main/kotlin/
        dsl/               # Kotlin DSL for build.gradle.kts
        tasks/             # Gradle task types (plan, apply, destroy, etc.)
        engine/            # Execution engine (Phase 1: shell-out, Phase 3: compiler)
        extensions/        # Extension loading (custom JARs/scripts)
    conventions/           # Convention plugins (opinionated defaults)

  irl-templates/           # Apache 2.0 -- Community template library

  infinite-room-labs-infra/ # First consumer
    build.gradle.kts        # Applies irl-gradle-plugin
    settings.gradle.kts     # Defines subprojects from environments
    terraform/              # Existing Terragrunt configs (unchanged initially)
```

## Gradle Plugin Architecture (Phase 1)

### Terragrunt-to-Gradle Mapping

| Terragrunt Concept | Gradle Concept |
|---|---|
| Leaf `terragrunt.hcl` | Gradle subproject |
| `dependency` block | `dependsOn` between subprojects |
| `root.hcl` includes | Convention plugin (shared config) |
| `env.hcl` locals | Gradle extension properties |
| `terraform plan/apply` | Gradle tasks (`:dev:cloudflare:zones:plan`) |
| Bootstrap (local state) | Subprojects with `localState = true` |
| `mock_outputs` | Task output declarations (Gradle's up-to-date checking) |

### DSL Surface

**settings.gradle.kts:**

```kotlin
plugins {
    id("com.infiniteroomlabs.irl-infrastructure")
}

infrastructure {
    environment("global") {
        provider("tfc") { resourceGroup("workspaces") }
        provider("cloudflare") { resourceGroup("tokens") }
    }
    environment("dev") {
        provider("cloudflare") { resourceGroup("zones") }
        provider("porkbun") { resourceGroup("nameservers") }
    }
    environment("prod") {
        provider("cloudflare") { resourceGroup("zones") }
        provider("porkbun") { resourceGroup("nameservers") }
    }
}
```

**Root build.gradle.kts:**

```kotlin
plugins {
    id("com.infiniteroomlabs.irl-infrastructure")
}

infrastructure {
    stateBackend {
        terraformCloud {
            organization = "infinite-room-labs"
        }
    }
    providers {
        cloudflare { version = "~> 5.17" }
        porkbun { version = "~> 0.2" }
    }
}
```

**Subproject build (e.g., dev/cloudflare/zones/build.gradle.kts):**

```kotlin
infrastructure {
    module = "cloudflare-zone"
    dependsOn(project(":global:cloudflare:tokens"))
    inputs {
        from(envConfig)
        from(dependency(":global:cloudflare:tokens").output("api_token"))
    }
}
```

### Tasks Per Subproject

- `:dev:cloudflare:zones:init` -- `terragrunt init`
- `:dev:cloudflare:zones:validate` -- `terragrunt validate`
- `:dev:cloudflare:zones:plan` -- `terragrunt plan`
- `:dev:cloudflare:zones:apply` -- `terragrunt apply -auto-approve`
- `:dev:cloudflare:zones:destroy` -- `terragrunt destroy` (requires confirmation)
- `:dev:cloudflare:zones:output` -- `terragrunt output -json` (cached, feeds downstream)

### DAG Execution

Running `./gradlew :dev:porkbun:nameservers:apply` automatically triggers:
1. `:global:cloudflare:tokens:apply` (bootstrap dep)
2. `:dev:cloudflare:zones:apply` (zones dep)
3. `:dev:porkbun:nameservers:apply` (requested target)

`--parallel` runs independent subprojects concurrently.

### Phase 1 Engine

Every task shells out to `terragrunt` in the subproject's directory. Existing `.hcl` files remain unchanged. The plugin reads them, it doesn't replace them.

## ANTLR4 HCL Parser (Phase 2)

### Grammar Strategy

- Derived from the [HCL2 specification](https://github.com/hashicorp/hcl/blob/main/hclsyntax/spec.md)
- Split `HCLLexer.g4` and `HCLParser.g4` (ANTLR4 best practice)
- Hard parts: heredocs, template interpolation, for expressions with filtering, dynamic blocks

### Kotlin AST

```kotlin
sealed interface HclNode {
    val span: SourceSpan
    val origin: Origin?
}

data class HclFile(val blocks: List<HclBlock>, val attributes: List<HclAttribute>) : HclNode
data class HclBlock(val type: String, val labels: List<String>, val body: HclBody) : HclNode
data class HclBody(val attributes: List<HclAttribute>, val blocks: List<HclBlock>) : HclNode
data class HclAttribute(val name: String, val expr: HclExpression) : HclNode

sealed interface HclExpression : HclNode
data class HclLiteral(val value: Any?) : HclExpression
data class HclTemplateExpr(val parts: List<HclExpression>) : HclExpression
data class HclFunctionCall(val name: String, val args: List<HclExpression>) : HclExpression
data class HclReference(val parts: List<String>) : HclExpression
data class HclForExpr(...) : HclExpression
data class HclBinaryOp(val op: String, val left: HclExpression, val right: HclExpression) : HclExpression
data class HclConditional(val cond: HclExpression, val trueVal: HclExpression, val falseVal: HclExpression) : HclExpression
// ... etc
```

Every node carries `SourceSpan` (file, line, column) and optional `Origin` (TEMPLATE, TENANT_OVERRIDE, GENERATED) for merge tracking.

### Scope

- Parses any valid HCL2 (Terraform, Packer, Nomad, Terragrunt)
- Syntax parser only -- no type checking, no expression evaluation, no Terraform-specific semantics
- Published as `com.infiniteroomlabs:irl-hcl-parser` on Maven Central (Apache 2.0)
- Zero transitive dependencies beyond ANTLR4 runtime

### Testing

- Parse every `.hcl` file in the proving ground repo
- Parse Terraform/Terragrunt source repos' test fixtures
- Round-trip: parse -> pretty-print -> parse -> ASTs match
- Property-based testing for expression edge cases

## IR and Semantic Merge Engine (Phase 3)

### IR Node Types

```kotlin
data class IRGraph(val nodes: List<IRNode>, val edges: List<IREdge>)

sealed interface IRNode {
    val id: NodeId
    val origin: Origin              // TEMPLATE | TENANT_OVERRIDE | MERGED
    val layer: ConventionLayer?     // BOOTSTRAP | GLOBAL | ENVIRONMENT | TENANT | RESOURCE_GROUP
    val sourceSpan: SourceSpan?
}

data class IRResource(
    val provider: String,
    val type: String,
    val name: String,
    val attributes: Map<String, IRValue>,
    val iteratorExpr: IRExpression?,
    // ... IRNode fields
) : IRNode

data class IRVariable(
    val name: String,
    val type: IRType,
    val default: IRValue?,
    val sensitive: Boolean,
    val overridePolicy: OverridePolicy,  // SEALED | TENANT_CAN_OVERRIDE
    // ... IRNode fields
) : IRNode

data class IROutput(
    val name: String,
    val value: IRExpression,
    val sensitive: Boolean,
    // ... IRNode fields
) : IRNode

data class IREdge(val from: NodeId, val to: NodeId, val type: EdgeType)

enum class OverridePolicy { SEALED, TENANT_CAN_OVERRIDE }
```

### Three-Way Merge Algorithm

Inputs:
- `base`: template at version tenant originally adopted (v1.0)
- `theirs`: template at updated version (v1.3)
- `ours`: tenant's current config (overrides on top of v1.0)

Algorithm:
1. Diff `base -> theirs` for template changes
2. Diff `base -> ours` for tenant overrides
3. Per node:
   - Only template changed -> accept template change
   - Only tenant changed -> keep tenant override
   - Both changed same attribute -> CONFLICT (never auto-resolve)
   - Template added new node -> add (origin: TEMPLATE)
   - Template removed node tenant didn't touch -> remove
   - Template removed node tenant modified -> CONFLICT
4. Enforce override policy as a post-merge validation pass

Conflicts are always explicit, never auto-resolved. For infrastructure, a false positive (unnecessary conflict) costs minutes. A false negative (silent wrong merge) costs an outage.

### Validation Pass Framework

```kotlin
interface IRValidationPass {
    val name: String
    val phase: ValidationPhase  // PRE_MERGE | POST_MERGE | PRE_EMIT
    fun validate(graph: IRGraph): List<IRDiagnostic>
}
```

Built-in passes: OverridePolicyPass, LayerConstraintPass, CycleDetectionPass, TypeCheckPass, SecurityPass.

Extension passes registered via custom JARs.

### Transform Pass Framework

```kotlin
interface IRTransformPass {
    val name: String
    val phase: TransformPhase  // POST_MERGE
    fun transform(graph: IRGraph, context: TransformContext): IRGraph
}
```

Transforms can modify IR. Validations cannot. This separation prevents validation side effects.

## Extension Mechanism

Three tiers of increasing power:

### 1. Kotlin Scripts (lightest)

Drop `.irl.kts` files in `extensions/`. No compilation, no publishing. Project-local policies.

```kotlin
validation("require-zone-settings") {
    onResource("cloudflare_zone") { resource ->
        if (resource.attributes["settings"]?.get("ssl")?.get("mode")?.asString() != "strict") {
            error("Zone ${resource.name} SSL mode must be 'strict'")
        }
    }
}
```

### 2. Convention Plugins (standard Gradle extension)

Published JARs on Maven. Shared conventions across projects/tenants. Versioned and resolved by Gradle's dependency resolution.

### 3. IR Transform/Validation Passes (deepest)

Custom compiler passes registered by plugins. Operate on the full typed IR with origin metadata. Transforms for cross-cutting concerns (auto-tagging, compliance rewrites). Validations for policy enforcement.

### Loading Order

1. Kotlin scripts (`extensions/*.irl.kts`) -- project-local
2. Convention plugins (`build.gradle.kts`) -- resolved from registry
3. IR transform passes -- ordered by phase annotation
4. IR validation passes -- run after all transforms, read-only

## Platform Layer (Phase 4)

### Architecture

```
Web UI / CLI Client
        |
   API Gateway (auth, routing)
        |
   Orchestrator (job queue, DAG scheduling)
        |
   Ephemeral Containers (each runs Gradle plugin)
```

### Components

- **API Service:** Kotlin (Ktor or Spring Boot -- TBD). REST + gRPC. Multi-tenant.
- **Orchestrator:** Receives run requests, resolves DAG, schedules containers, streams logs.
- **Ephemeral Containers:** Fresh container per run. Tenant repo + plugin + extensions + credentials (env vars). Destroyed after completion.
- **CLI Client (`irl-cli`):** Authenticates, calls API, streams output. Offline mode falls back to local `./gradlew`.

### Multi-Tenancy

Each tenant gets:
- Isolated credential storage
- Own extension JARs/scripts
- Own run history and audit log
- Own template version lockfiles
- Configurable override policies

### Self-Hosting Bootstrap

1. Deploy platform manually (Docker Compose, single node)
2. Create `platform` tenant within the platform
3. Import platform infrastructure configs as a project
4. Apply platform infra through itself
5. Platform manages itself from this point forward

Escape hatch: Gradle plugin always works locally without the platform.

### Deployment

Single Linux box with Docker Compose: API + Orchestrator + PostgreSQL + container runtime. No Kubernetes until scale demands it.

## Phased Implementation

### Phase 1: Gradle Plugin (Shell-out to Terragrunt)

- **Repos:** `irl-gradle-plugin`
- **Delivers:** Plugin, DSL, tasks, DAG execution, bootstrap support, script extensions
- **Done when:** `./gradlew :dev:cloudflare:zones:apply` works end-to-end including bootstrap deps

### Phase 2: ANTLR4 HCL Parser

- **Repos:** `irl-hcl-parser`
- **Delivers:** ANTLR4 grammars, Kotlin AST, pretty-printer, Maven Central artifact
- **Done when:** All HCL2 syntax handled, round-trip tests pass on Terraform's test fixtures

### Phase 3: IR and Merge Engine

- **Added to:** `irl-hcl-parser`
- **Delivers:** IR types, AST->IR lowering, three-way merge, override policy, validation/transform frameworks
- **Done when:** Merge works on proving ground modules, validation catches real policy violations

### Phase 4: Platform Layer

- **Repos:** `irl-cli`, `irl-platform`
- **Delivers:** API, orchestrator, containers, CLI, web UI, self-hosting
- **Done when:** Platform hosts itself as own tenant on single-node Docker Compose

## Out of Scope (YAGNI)

- Cross-repo dependency resolution
- Template marketplace/registry
- HCL JSON support
- Kubernetes deployment
- Cost estimation passes
- Web UI design details
