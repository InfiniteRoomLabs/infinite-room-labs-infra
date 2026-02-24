# Infinite Room Labs Infrastructure

Infrastructure as code for Infinite Room Labs. Uses Terraform + Terragrunt with Terraform Cloud (HCP Terraform) as the remote state backend.

## What It Does

Manages domain onboarding from Porkbun (our registrar) to Cloudflare (our DNS/CDN provider). For each domain you add to an environment's domain list:

1. A Cloudflare zone is created
2. Porkbun's nameservers are automatically updated to point to Cloudflare's assigned nameservers

Dev and prod environments are fully isolated -- separate domain lists, separate TFC workspaces, separate state.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- [Terragrunt](https://terragrunt.gruntwork.io/docs/getting-started/install/) >= 0.55
- [direnv](https://direnv.net/) (optional, for automatic env var loading)
- A [Terraform Cloud](https://app.terraform.io/) account with an organization named `infinite-room-labs`
- A Cloudflare account with an API token that has zone management permissions
- Porkbun API credentials (API key + secret)

## Setup

### 1. Clone and configure credentials

```bash
git clone <repo-url> && cd infinite-room-labs-infra
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

### 2. Bootstrap TFC workspaces

This creates the Terraform Cloud workspaces that store state for all other resource groups. It uses local state itself (chicken-and-egg problem).

```bash
cd environments/global/tfc/workspaces
terragrunt init
terragrunt apply
```

You only need to do this once, or when adding new resource groups that need their own workspaces.

### 3. Add your domains

Edit the domain list for your target environment:

```bash
# For dev domains
vim environments/dev/env.hcl

# For prod domains
vim environments/prod/env.hcl
```

Add domain names to the `domains` list:

```hcl
domains = [
  "example.com",
  "another-domain.dev",
]
```

### 4. Apply

From the environment directory, Terragrunt handles the apply order automatically (Cloudflare zones first, then Porkbun nameservers):

```bash
cd environments/dev
terragrunt run-all apply
```

After apply completes, verify nameserver delegation is working:

```bash
dig NS example.com
```

You should see Cloudflare nameservers (e.g., `anna.ns.cloudflare.com`, `bob.ns.cloudflare.com`). The Cloudflare zone will show as "Pending" until Cloudflare verifies the nameserver change has propagated, which can take a few minutes to 24 hours.

## Common Operations

### Add a new domain

1. Add the domain name to `environments/{env}/env.hcl`
2. Run `terragrunt run-all apply` from the environment directory

No other changes needed -- no new workspaces, no new config files.

### Remove a domain

1. Remove the domain from `environments/{env}/env.hcl`
2. Run `terragrunt run-all plan` to review the destruction plan
3. Run `terragrunt run-all apply` to execute (requires confirmation)

### Check for drift

```bash
cd environments/dev
terragrunt run-all plan
```

This detects if someone manually changed nameservers on Porkbun or modified zones in Cloudflare outside of Terraform.

### Apply a single resource group

If you only want to apply the Cloudflare zones without touching Porkbun nameservers:

```bash
cd environments/dev/cloudflare/zones
terragrunt apply
```

## Project Structure

```
root.hcl                                  # Global: TFC backend, provider versions
.envrc                                    # direnv auto-loader
.env.example                              # Credential template

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

### How the pieces connect

Each leaf `terragrunt.hcl` does three things:

1. **Includes `root.hcl`** -- gets the TFC backend config (workspace name derived from its directory path) and provider version constraints
2. **Reads `env.hcl`** -- gets the environment's domain list and Cloudflare account ID
3. **Sources a module** -- points to a reusable module in `modules/` and passes inputs

The Porkbun nameservers leaf additionally declares a `dependency` on the Cloudflare zones leaf in the same environment, reading the `nameservers_map` output to know which nameservers to set for each domain.

### TFC workspace naming

Workspace names are derived from the directory path: `environments/dev/cloudflare/zones` becomes workspace `dev-cloudflare-zones`. This is handled automatically in `root.hcl`.

Current workspaces:

| Workspace | Resource Group |
|-----------|---------------|
| `dev-cloudflare-zones` | `environments/dev/cloudflare/zones/` |
| `dev-porkbun-nameservers` | `environments/dev/porkbun/nameservers/` |
| `prod-cloudflare-zones` | `environments/prod/cloudflare/zones/` |
| `prod-porkbun-nameservers` | `environments/prod/porkbun/nameservers/` |

## Credential Management

All credentials are sourced from environment variables -- nothing is hardcoded. Both the Cloudflare and Porkbun Terraform providers read their credentials from env vars automatically with zero provider-block configuration.

The `.env` file is gitignored. The `.envrc` file (committed) loads it via direnv. The `.env.example` file (committed) documents which variables are needed.

## Troubleshooting

**`terragrunt init` fails with "Required token could not be found"**
Your `TF_TOKEN_app_terraform_io` environment variable isn't set. Check your `.env` file and make sure direnv is active (`direnv allow`).

**`terragrunt validate` fails with "could not read state version outputs: resource not found"**
The dependency workspace has no state yet. This happens when validating the Porkbun nameservers resource group before the Cloudflare zones have been applied. Apply the Cloudflare zones first, or use `terragrunt run-all` which handles ordering.

**Cloudflare zone stuck in "Pending" status**
This is normal. Cloudflare needs to verify that the nameservers at the registrar match. After `terragrunt apply` updates Porkbun, it can take minutes to hours for Cloudflare to confirm. Check back in the Cloudflare dashboard.

**`get_env` error for `CLOUDFLARE_ACCOUNT_ID`**
Your environment variables aren't loaded. Run `direnv allow` or source your `.env` manually.

**Rate limiting on bulk zone creation**
Reduce Terraform parallelism:

```bash
terragrunt run-all apply -- -parallelism=2
```
