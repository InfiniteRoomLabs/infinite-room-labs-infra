# Feature Specification: Porkbun-to-Cloudflare Domain Onboarding

**Feature Branch**: `001-porkbun-cloudflare-domain-onboarding`
**Created**: 2026-02-12
**Status**: Draft
**Mission**: software-dev
**Input**: User description: "Let's get this party started and let's start by making it so that any of my domains on porkbun that we list in a variable somewhere are configured to have accounts in cloudflare and the nameservers are set up to match. Let's do this with terraform and terragrunt. You have access to scoop if you need to install either of those"

## User Scenarios & Testing

### User Story 1 - Onboard Domains to Cloudflare (Priority: P1)

An infrastructure operator defines a list of domains per environment (dev and prod) in a Terragrunt variable. When they run `terragrunt apply`, each domain gets a corresponding Cloudflare zone created in the team's single Cloudflare account.

**Why this priority**: Cloudflare zones are the prerequisite for all DNS management, CDN, security rules, and every other Cloudflare feature. This must work first.

**Independent Test**: Can be fully tested by adding a single domain to the dev environment variable, running apply, and confirming the zone appears in the Cloudflare dashboard.

**Acceptance Scenarios**:

1. **Given** a domain is listed in the dev environment's domain variable, **When** `terragrunt apply` is run for the Cloudflare resource group, **Then** a Cloudflare zone is created for that domain in the configured account.
2. **Given** a domain is listed in the prod environment's domain variable, **When** `terragrunt apply` is run, **Then** a Cloudflare zone is created for that domain in the same Cloudflare account.
3. **Given** a domain is removed from the variable list, **When** `terragrunt apply` is run, **Then** the corresponding Cloudflare zone is planned for removal (with operator review before apply).

---

### User Story 2 - Automatically Update Porkbun Nameservers (Priority: P1)

After Cloudflare zones are created, the system reads the Cloudflare-assigned nameservers for each zone and updates the corresponding domain's nameserver configuration on Porkbun to match. This completes the delegation loop so DNS resolution flows through Cloudflare.

**Why this priority**: Without nameserver delegation, the Cloudflare zones are inert. This is equally critical to zone creation — together they form the minimum viable feature.

**Independent Test**: Can be tested by checking that after apply, the Porkbun domain's nameservers match the Cloudflare-assigned nameservers (verifiable via Porkbun dashboard or API, and via `dig NS <domain>`).

**Acceptance Scenarios**:

1. **Given** a Cloudflare zone exists for a domain, **When** `terragrunt apply` is run for the Porkbun resource group, **Then** the domain's nameservers on Porkbun are updated to match Cloudflare's assigned nameservers.
2. **Given** the nameservers are already correctly set on Porkbun, **When** `terragrunt apply` is run, **Then** no changes are made (idempotent).

---

### User Story 3 - Terragrunt Project Bootstrap (Priority: P1)

The project needs a working Terragrunt structure following the constitution's `environment/provider/resource-group/` hierarchy, with Terraform Cloud as the remote state backend. This scaffolding must be in place before any domain operations can run.

**Why this priority**: This is the structural foundation. Without the Terragrunt layout, provider configuration, and remote state, nothing can be applied.

**Independent Test**: Can be tested by running `terragrunt init` in any resource group directory and confirming it initializes successfully with Terraform Cloud as the backend.

**Acceptance Scenarios**:

1. **Given** the repository is freshly cloned, **When** an operator runs `terragrunt init` in a resource group directory, **Then** Terraform initializes with the Terraform Cloud backend and required providers.
2. **Given** the Terragrunt hierarchy exists, **When** an operator navigates between `dev/cloudflare/zones/` and `prod/cloudflare/zones/`, **Then** each has its own isolated state in a separate Terraform Cloud workspace.
3. **Given** environment-level variables are defined (e.g., domain lists), **When** a child resource group is applied, **Then** it inherits those variables without duplication.

---

### Edge Cases

- What happens when a domain in the variable list doesn't actually exist on Porkbun? The Porkbun provider should surface an error during plan/apply.
- What happens when Cloudflare assigns different nameservers on zone recreation (e.g., after a zone is destroyed and re-created)? The Porkbun nameserver update should pick up the new values on the next apply.
- What happens if the Cloudflare API rate-limits requests during a large batch of zone creations? Terraform's built-in retry logic and parallelism settings should handle this; the operator can reduce parallelism if needed.
- What happens if someone manually changes nameservers on Porkbun outside of Terraform? The next plan should detect drift and propose correcting them.

## Requirements

### Functional Requirements

- **FR-001**: System MUST create a Cloudflare zone for each domain listed in the environment's domain variable.
- **FR-002**: System MUST update each domain's nameservers on Porkbun to match the Cloudflare-assigned nameservers for the corresponding zone.
- **FR-003**: System MUST support separate domain lists for dev and prod environments.
- **FR-004**: System MUST use Terraform Cloud as the remote state backend with one workspace per resource group.
- **FR-005**: System MUST follow the `environment/provider/resource-group/` directory hierarchy defined in the project constitution.
- **FR-006**: System MUST use reusable Terraform modules (in `modules/`) for Cloudflare zone creation and Porkbun nameserver configuration.
- **FR-007**: System MUST use Terragrunt for DRY configuration with variable inheritance from parent scopes (root, environment, provider levels).
- **FR-008**: System MUST detect and report drift when nameservers or zones are modified outside of Terraform.
- **FR-009**: Domain removal from the variable list MUST result in a planned destruction that requires explicit operator approval.

### Key Entities

- **Domain**: A registered domain name on Porkbun. Key attributes: domain name, current nameservers, environment assignment (dev or prod).
- **Cloudflare Zone**: A DNS zone in Cloudflare representing a domain. Key attributes: zone ID, domain name, assigned nameservers, account ID.
- **Environment**: A logical grouping (dev or prod) that determines which domains are managed and provides state isolation.

## Success Criteria

### Measurable Outcomes

- **SC-001**: All domains listed in the environment variable have active Cloudflare zones after a single apply.
- **SC-002**: All onboarded domains resolve DNS through Cloudflare nameservers (verifiable via `dig NS <domain>`).
- **SC-003**: Adding a new domain requires only adding its name to a variable list — no other configuration changes needed.
- **SC-004**: Dev and prod environments are fully isolated — applying in one environment has zero effect on the other.
- **SC-005**: The entire infrastructure can be reproduced from code on a fresh clone (no manual setup beyond providing API credentials and Terraform Cloud token).

## Assumptions

- The user already has (or will create) a Cloudflare account and can provide an API token with zone management permissions.
- The user has Porkbun API credentials (API key and secret) for managing domain nameservers.
- The user will create a Terraform Cloud organization and provide an API token before the first apply.
- All domains to be managed are already registered on Porkbun.
- The Cloudflare free plan is sufficient (zone creation is free).

## Dependencies

- Terraform provider: `jianyuan/porkbun` v0.2.1 (as noted in PROVIDERS file).
- Terraform provider: `cloudflare/cloudflare` v5.17.0 (as noted in PROVIDERS file).
- Terraform Cloud account and organization.
- Porkbun API credentials.
- Cloudflare API token with zone read/write permissions.