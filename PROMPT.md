# Design Prompt: DAG-Based Multi-Tenant IaC Framework

## Context

Infinite Room Labs has a working IaC monorepo (`infinite-room-labs-infra`) that manages global infrastructure using Terraform + Terragrunt. It currently handles:

- **Bootstrap layer** (local state): TFC workspace provisioning, scoped Cloudflare API tokens
- **Environment layers** (TFC remote state): Cloudflare zone creation, Porkbun nameserver delegation
- **Dependency chain**: bootstrap tokens -> zones -> nameservers (resolved via Terragrunt `dependency` blocks)
- **Pattern**: `terraform/environments/{env}/{provider}/{resource-group}/` with reusable modules in `terraform/modules/`

This works for the company's own domains. Now we need to scale this pattern to support every type of infrastructure the company touches.

## Vision

Design a **directed acyclic graph (DAG) dependency framework** for infrastructure-as-code that:

1. **Decomposes infrastructure into composable, version-controlled templates** -- cookiecutter-style project scaffolds that can be assembled into complete infrastructure stacks
2. **Supports multiple tenant types**, each getting their own git repository with tenant-specific configuration that depends on shared global infrastructure
3. **Composes templates via git multi-remote merges** using `GitHubOrg/RepoName[@ref]` references, so templates can be pulled, merged, and updated across tenant repos
4. **Models dependencies as a DAG** where any node (template instance) can declare dependencies on other nodes, and the framework resolves apply order automatically
5. **Tracks every IaC change** across all tenants, projects, and infrastructure types through version control

## Tenant Types to Support

Think broadly about the kinds of infrastructure a consultancy/product company manages:

- **Client engagements** -- per-client infrastructure (domains, hosting, CI/CD, monitoring) that may be handed off
- **SaaS products** -- long-lived product infrastructure (databases, compute, CDN, auth)
- **Internal tooling** -- company infrastructure (dev environments, shared services, agent infrastructure)
- **Open source projects** -- public-facing infra (docs sites, package registries, CI)
- **Ephemeral/sandbox** -- short-lived environments for demos, experiments, spikes
- **Vendor integrations** -- third-party service configurations (Stripe, Twilio, etc.)

What other types exist? What dimensions matter for categorization (lifecycle, ownership, handoff, billing, isolation level)?

## Template Composition Model

The rough idea is:

- **Global repo** (`infinite-room-labs-infra`): shared modules, bootstrap resources, company-wide config
- **Template repos**: cookiecutter-style scaffolds for each infrastructure pattern (e.g., `tpl-cloudflare-site`, `tpl-saas-backend`, `tpl-client-baseline`)
- **Tenant repos**: per-tenant repositories created from templates, with local overrides and tenant-specific config
- **Composition**: tenant repos pull in templates via git multi-remote merge (not submodules), using `InfiniteRoomLabs/tpl-whatever@v1.2` syntax. Updates are merged in, not force-replaced.

## Open Design Questions

These need to be explored and decided:

1. **DAG resolution**: How does the framework discover and resolve the dependency graph across repos? Terragrunt's `dependency` blocks work within a repo -- what's the cross-repo equivalent?
2. **State boundaries**: Each tenant repo has its own TFC workspaces, but how do they reference outputs from the global repo? Remote state data sources? A shared output registry?
3. **Template versioning**: When a template is updated, how do tenants adopt changes? Git merge (with conflict resolution)? Automated PRs? Pinned versions with manual bumps?
4. **Credential scoping**: How are credentials isolated per tenant? Per-tenant API tokens from bootstrap? Vault namespaces? TFC variable sets?
5. **Lifecycle management**: How do you handle tenant offboarding (client handoff), environment promotion (dev -> prod), and teardown (ephemeral sandboxes)?
6. **Orchestration**: What drives the cross-repo apply order? A central CI/CD pipeline? A lightweight CLI tool? Terragrunt's `run-all` extended to multi-repo?
7. **Drift detection**: How do you know when a tenant's infrastructure has drifted from its template baseline?

## What Exists Today (Starting Point)

```
infinite-room-labs-infra/
  terraform/
    root.hcl                              # Terragrunt global config (TFC backend, provider versions)
    modules/
      cloudflare-zone/                    # Reusable: creates Cloudflare zones
      porkbun-nameservers/                # Reusable: updates Porkbun NS delegation
      tfc-workspace/                      # Reusable: creates a single TFC workspace
    environments/
      global/
        tfc/workspaces/                   # Bootstrap: provisions TFC workspaces (local state)
        cloudflare/tokens/                # Bootstrap: creates scoped Cloudflare API token (local state)
      dev/
        env.hcl                           # Domain list, account IDs
        cloudflare/zones/                 # Creates zones (depends on bootstrap token)
        porkbun/nameservers/              # Updates NS (depends on zones output)
      prod/
        env.hcl
        cloudflare/zones/
        porkbun/nameservers/
```

Key patterns already established:
- `for_each` over domain lists (add/remove by editing a list)
- Terragrunt dependency blocks with mock outputs for planning
- Bootstrap layer with local state to avoid chicken-and-egg
- Provider credential fallback (bootstrap token -> env var)
- Workspace names derived from directory paths

## Success Criteria

- A new tenant (any type) can be onboarded by creating a repo from a template and running a single command
- Dependencies between tenant infra and global infra are explicit, versioned, and automatically resolved
- Template updates can be adopted by tenants without blowing away their customizations
- The entire infrastructure graph is auditable through git history across all repos
- No manual steps between "commit config" and "infrastructure converged" (for approved changes)

## Deliverable

Use the brainstorming skill to explore this design space. Ask clarifying questions, propose approaches, and produce a design document covering architecture, component design, data flow, and trade-offs. Focus on the framework's core abstractions -- the DAG model, template composition, and cross-repo dependency resolution -- before getting into specific tenant type implementations.
