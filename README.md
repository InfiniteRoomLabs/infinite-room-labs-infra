# Infinite Room Labs Infrastructure

Infrastructure as code for Infinite Room Labs. This monorepo contains all IaC tooling, organized by tool.

## Repository Layout

```
terraform/          Terraform + Terragrunt (domain onboarding, cloud resources)
.envrc              direnv auto-loader (loads .env)
.env.example        Credential template
```

Additional IaC directories (e.g., `ansible/`) will be added as needed. Each has its own internal structure documented below.

## Setup

### 1. Configure credentials

```bash
cp .env.example .env
```

Fill in `.env` with your credentials:

| Variable | Where to get it |
|----------|----------------|
| `CLOUDFLARE_API_TOKEN` | Cloudflare dashboard > My Profile > API Tokens > Create Token > "Edit zone DNS" template |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare dashboard > any domain > Overview > right sidebar under "API" |
| `PORKBUN_API_KEY` | Porkbun > Account > API Access |
| `PORKBUN_SECRET_KEY` | Porkbun > Account > API Access (generated with the API key) |
| `TF_TOKEN_app_terraform_io` | Terraform Cloud > User Settings > Tokens > Create an API token |

If you use direnv, run `direnv allow` to auto-load the `.env` file. Otherwise, source it manually:

```bash
export $(grep -v '^#' .env | xargs)
```

---

## Terraform

All Terraform and Terragrunt configuration lives under `terraform/`. Uses Terraform Cloud (HCP Terraform) as the remote state backend.

### Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- [Terragrunt](https://terragrunt.gruntwork.io/docs/getting-started/install/) >= 0.55
- A [Terraform Cloud](https://app.terraform.io/) account with org `infinite-room-labs`

### What it manages

**Domain onboarding** (Porkbun to Cloudflare): For each domain in an environment's domain list, the system creates a Cloudflare zone and updates Porkbun nameservers to match. Dev and prod environments are fully isolated.

### Structure

```
terraform/
  root.hcl                                  # Global: TFC backend, provider versions
  modules/
    cloudflare-zone/                        # Creates Cloudflare zones for a list of domains
    porkbun-nameservers/                    # Updates Porkbun NS to match Cloudflare
    tfc-workspace/                          # Creates a single TFC workspace
  environments/
    global/tfc/workspaces/                  # Bootstrap: creates all TFC workspaces (local state)
    dev/
      env.hcl                               # Dev domain list + account config
      cloudflare/
        provider.hcl                        # Cloudflare provider (credentials from env vars)
        zones/terragrunt.hcl               # Leaf: creates zones for dev domains
      porkbun/
        provider.hcl                        # Porkbun provider (credentials from env vars)
        nameservers/terragrunt.hcl          # Leaf: updates NS for dev domains
    prod/                                   # Same structure as dev, different domain list
      ...
```

### First-time setup

#### 1. Bootstrap TFC workspaces

Creates the Terraform Cloud workspaces that store state for all other resource groups. Uses local state itself (chicken-and-egg problem). Only needed once.

```bash
cd terraform/environments/global/tfc/workspaces
terragrunt init
terragrunt apply
```

#### 2. Apply an environment

Terragrunt handles ordering automatically (Cloudflare zones first, then Porkbun nameservers):

```bash
cd terraform/environments/dev
terragrunt run-all apply
```

Verify nameserver delegation:

```bash
dig NS example.com
```

The Cloudflare zone will show as "Pending" until Cloudflare verifies nameserver propagation (minutes to 24 hours).

### Common operations

**Add a domain**: Add the domain name to `terraform/environments/{env}/env.hcl`, then run `terragrunt run-all apply` from the environment directory.

**Remove a domain**: Remove it from `env.hcl`, run `terragrunt run-all plan` to review the destruction plan, then `terragrunt run-all apply`.

**Check for drift**: Run `terragrunt run-all plan` from the environment directory.

**Apply a single resource group**:

```bash
cd terraform/environments/dev/cloudflare/zones
terragrunt apply
```

### How the pieces connect

Each leaf `terragrunt.hcl` does three things:

1. **Includes `root.hcl`** -- gets the TFC backend config (workspace name derived from its directory path) and provider version constraints
2. **Reads `env.hcl`** -- gets the environment's domain list and Cloudflare account ID
3. **Sources a module** -- points to a reusable module in `terraform/modules/` and passes inputs

The Porkbun nameservers leaf additionally declares a `dependency` on the Cloudflare zones leaf in the same environment, reading the `nameservers_map` output to know which nameservers to set for each domain.

### TFC workspace naming

Workspace names are derived from the directory path relative to `root.hcl`: `environments/dev/cloudflare/zones` becomes `dev-cloudflare-zones`.

| Workspace | Resource Group |
|-----------|---------------|
| `dev-cloudflare-zones` | `terraform/environments/dev/cloudflare/zones/` |
| `dev-porkbun-nameservers` | `terraform/environments/dev/porkbun/nameservers/` |
| `prod-cloudflare-zones` | `terraform/environments/prod/cloudflare/zones/` |
| `prod-porkbun-nameservers` | `terraform/environments/prod/porkbun/nameservers/` |

### Credential management

All credentials are sourced from environment variables -- nothing is hardcoded. Both providers read their credentials from env vars automatically with zero provider-block configuration.

The `.env` file is gitignored. The `.envrc` file (committed) loads it via direnv. The `.env.example` file (committed) documents which variables are needed.

### Troubleshooting

**`terragrunt init` fails with "Required token could not be found"**
Your `TF_TOKEN_app_terraform_io` environment variable isn't set. Check your `.env` file and make sure direnv is active (`direnv allow`).

**`terragrunt validate` fails with "could not read state version outputs: resource not found"**
The dependency workspace has no state yet. This happens when validating Porkbun nameservers before Cloudflare zones have been applied. Apply zones first, or use `terragrunt run-all` which handles ordering.

**Cloudflare zone stuck in "Pending" status**
Normal. Cloudflare needs to verify nameservers at the registrar match. Can take minutes to hours.

**`get_env` error for `CLOUDFLARE_ACCOUNT_ID`**
Environment variables aren't loaded. Run `direnv allow` or source your `.env` manually.

**Rate limiting on bulk zone creation**
Reduce Terraform parallelism:

```bash
terragrunt run-all apply -- -parallelism=2
```
