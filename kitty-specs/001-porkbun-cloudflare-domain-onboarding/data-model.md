# Data Model (Discovery Draft)

## Entities

### Entity: Cloudflare Zone
- **Description**: A DNS zone in Cloudflare representing a single domain. Created per domain listed in the environment's domain variable.
- **Attributes**:
  - `account_id` (string) – Cloudflare account to create the zone in
  - `name` (string) – domain name (e.g., "example.com")
  - `type` (string) – zone type; always "full" for authoritative DNS hosting
  - `name_servers` (list of string, read-only) – Cloudflare-assigned nameservers; passed to Porkbun
  - `status` (string, read-only) – "initializing", "pending", "active", "moved"
  - `id` (string, read-only) – zone identifier used by other Cloudflare resources
- **Identifiers**: `id` (Cloudflare zone ID), `name` (domain name, unique per account)
- **Lifecycle Notes**: Created on first apply. Stays "pending" until NS delegation verified. Becomes "active" once Cloudflare confirms nameserver propagation. Destroyed if removed from domain variable (requires operator approval).

### Entity: Porkbun Domain Nameservers
- **Description**: The nameserver delegation configuration for a domain registered on Porkbun. Updated to point to Cloudflare's assigned nameservers.
- **Attributes**:
  - `domain` (string) – the registered domain name
  - `nameservers` (set of string) – the nameservers to set (sourced from Cloudflare zone output)
- **Identifiers**: `domain` (domain name, unique)
- **Lifecycle Notes**: Updated whenever the Cloudflare zone's assigned nameservers change (rare). Set is unordered — Terraform won't detect drift from reordering.

### Entity: Environment
- **Description**: A logical boundary (dev or prod) providing state isolation and separate domain lists.
- **Attributes**:
  - `environment` (string) – "dev" or "prod"
  - `domains` (list of string) – domains assigned to this environment
- **Identifiers**: `environment` name (directory-level, not a Terraform resource)
- **Lifecycle Notes**: Defined in Terragrunt `env.hcl` files. Adding/removing domains triggers zone creation/destruction in the corresponding environment only.

### Entity: Terraform Cloud Workspace
- **Description**: Remote state container in TFC. One workspace per resource group, named by convention.
- **Attributes**:
  - `name` (string) – derived as `{environment}-{provider}-{resource-group}`
  - `organization` (string) – TFC organization name
  - `execution_mode` (string) – "local" (state in TFC, execution on operator machine)
- **Identifiers**: `name` (unique within organization)
- **Lifecycle Notes**: Must be created in TFC before first `terragrunt init`. Not managed by Terraform in this feature (manual or bootstrapped separately).

## Relationships

| Source | Relation | Target | Cardinality | Notes |
|--------|----------|--------|-------------|-------|
| Environment | contains | Cloudflare Zone | 1:N | Each environment has its own list of domains/zones |
| Cloudflare Zone | provides nameservers to | Porkbun Domain Nameservers | 1:1 | `name_servers` output feeds into `nameservers` input |
| Environment | contains | Porkbun Domain Nameservers | 1:N | One NS config per domain per environment |
| Terraform Cloud Workspace | stores state for | Resource Group | 1:1 | One workspace per resource group directory |

## Validation & Governance

- **Data quality requirements**: Domain names must be valid FQDNs registered on Porkbun. Cloudflare account ID must be a valid existing account.
- **Compliance considerations**: No PII involved. API credentials (Cloudflare token, Porkbun keys) must never appear in state or code — environment variables only.
- **Source of truth**: Porkbun is the registrar of record. Cloudflare is authoritative for DNS resolution once delegation is active. Terraform state (in TFC) is the source of truth for infrastructure configuration.
