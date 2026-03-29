# Infinite Room Labs Infrastructure

Infrastructure as code for Infinite Room Labs. This monorepo contains all IaC tooling, organized by tool.

## Repository Layout

```
terraform/          Terraform + Terragrunt (cloud resources, domains, DNS, compute)
ansible/            Ansible (homelab server config, Helm deployments, secrets)
helm-charts/        Helm charts (git submodule -> InfiniteRoomLabs/helm-charts)
docker/             Custom container image builds (Dockerfiles)
scripts/            Bootstrap, secrets sync, and shared helpers
docs/               Architecture plans, access guides, research
tests/              Acceptance test suite (smoke, validate)
.envrc              direnv auto-loader (loads .env)
.env.example        Credential template
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full contributor guide. See [TESTING.md](TESTING.md) for the acceptance test suite.

## Setup

### 1. Configure credentials

```bash
cp .env.example .env
```

Fill in `.env` with your credentials:

| Variable                         | Where to get it                                                                                                             |
|----------------------------------|-----------------------------------------------------------------------------------------------------------------------------|
| `CLOUDFLARE_BOOTSTRAP_API_TOKEN` | Cloudflare dashboard > My Profile > API Tokens > Create Token > custom token with "API Tokens: Edit" under User permissions |
| `CLOUDFLARE_ACCOUNT_ID`          | Cloudflare dashboard > any domain > Overview > right sidebar under "API"                                                    |
| `PORKBUN_API_KEY`                | Porkbun > Account > API Access                                                                                              |
| `PORKBUN_SECRET_KEY`             | Porkbun > Account > API Access (generated with the API key)                                                                 |
| `TF_TOKEN_app_terraform_io`      | Terraform Cloud > User Settings > Tokens > Create an API token                                                              |
| `DOCKER_USERNAME`                | Docker Hub username                                                                                                         |
| `DOCKER_PASSWORD`                | Docker Hub > Account Settings > Security > New Access Token                                                                 |
| `DIGITAL_OCEAN_TOKEN`            | DigitalOcean > API > Generate New Token                                                                                     |
| `TAILSCALE_API_KEY`              | Tailscale admin console > Settings > Keys > Generate auth key                                                               |
| `TAILSCALE_TAILNET`              | Tailscale admin console > Settings > General > Organization                                                                 |
| `HOMELAB_TAILSCALE_IP`           | Tailscale admin console > Machines > homelab node IP                                                                        |
| `SENDGRID_API_KEY`               | SendGrid > Settings > API Keys > Create API Key                                                                             |

> **Note:** `CLOUDFLARE_API_TOKEN` is no longer required for setup -- the bootstrap creates it. It can still be set as a fallback.

If you use direnv, run `direnv allow` to autoload the `.env` file. Otherwise, source it manually:

```bash
export $(grep -v '^#' .env | xargs)
```

### 2. Initialize submodules

```bash
git submodule update --init
```

This populates `helm-charts/` with the IRL Helm charts.

---

## Terraform

All Terraform and Terragrunt configuration lives under `terraform/`. Uses Terraform Cloud (HCP Terraform) as the remote state backend.

### Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- [Terragrunt](https://terragrunt.gruntwork.io/docs/getting-started/install/) >= 0.55
- A [Terraform Cloud](https://app.terraform.io/) account with org `infinite-room-labs`

### What it manages

- **Domain onboarding** (Porkbun to Cloudflare): Creates Cloudflare zones and updates Porkbun nameservers to match
- **DNS records**: Manages Cloudflare DNS records for homelab and production services
- **Compute**: DigitalOcean droplets (k3s agent nodes)
- **Networking**: Tailscale ACLs and split DNS configuration
- **Container registry**: Docker Hub repository management
- **Email**: SendGrid sender authentication and configuration
- **Bootstrap resources**: TFC workspaces and scoped Cloudflare API tokens

### Structure

```
terraform/
  root.hcl                                  # Global: TFC backend, provider versions
  modules/
    cloudflare-zone/                        # Creates Cloudflare zones for a list of domains
    cloudflare-dns-records/                 # Manages Cloudflare DNS records
    cloudflare-pages/                       # Cloudflare Pages deployments
    porkbun-nameservers/                    # Updates Porkbun NS to match Cloudflare
    tfc-workspace/                          # Creates a single TFC workspace
    dockerhub-repo/                         # Manages Docker Hub repositories
    do-droplet/                             # Creates DigitalOcean droplets
    sendgrid-config/                        # SendGrid sender authentication
    tailscale-acl/                          # Tailscale ACL policies
  environments/
    global/
      tfc/workspaces/                       # Bootstrap: creates all TFC workspaces (local state)
      cloudflare/tokens/                    # Bootstrap: creates scoped Cloudflare API token (local state)
      dockerhub/repos/                      # Manages Docker Hub repositories
    dev/
      env.hcl                               # Dev domain list + account config
      cloudflare/zones/                     # Cloudflare zones for dev domains
      porkbun/nameservers/                  # Porkbun NS for dev domains
    prod/
      env.hcl                               # Prod domain list + account config
      cloudflare/zones/                     # Cloudflare zones for prod domains
      cloudflare/dns-records/               # DNS records for prod services
      porkbun/nameservers/                  # Porkbun NS for prod domains
      sendgrid/config/                      # SendGrid email config
    homelab/
      env.hcl                               # Homelab config (Tailscale IP, etc.)
      cloudflare/dns-records/               # DNS records for homelab services
      digitalocean/k3s-agent/               # DO droplet for k3s agent node
      tailscale/acl/                        # Tailscale ACL policies
      tailscale/split-dns/                  # Tailscale split DNS for *.lab domains
scripts/
  bootstrap.sh                              # Orchestrates full bootstrap sequence
  includes/
    env.sh                                  # Shared env loading and validation helpers
```

### First-time setup

#### 1. Bootstrap (TFC workspaces + Cloudflare API token)

The bootstrap script creates Terraform Cloud workspaces and a scoped Cloudflare API token. It uses local state (chicken-and-egg problem with TFC). Only needed once.

```bash
scripts/bootstrap.sh
```

Preview what the bootstrap will do without applying:

```bash
scripts/bootstrap.sh --plan
```

Re-run only the Cloudflare token step (e.g., after changing token permissions):

```bash
scripts/bootstrap.sh --skip-tfc
```

Run `scripts/bootstrap.sh --help` for all options.

#### 2. Apply an environment

Terragrunt handles ordering automatically (Cloudflare zones first, then Porkbun nameservers). The zones layer reads the API token from the bootstrap state automatically.

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

| Workspace                        | Resource Group                                           |
|----------------------------------|----------------------------------------------------------|
| `dev-cloudflare-zones`           | `terraform/environments/dev/cloudflare/zones/`           |
| `dev-porkbun-nameservers`        | `terraform/environments/dev/porkbun/nameservers/`        |
| `prod-cloudflare-zones`          | `terraform/environments/prod/cloudflare/zones/`          |
| `prod-cloudflare-dns-records`    | `terraform/environments/prod/cloudflare/dns-records/`    |
| `prod-porkbun-nameservers`       | `terraform/environments/prod/porkbun/nameservers/`       |
| `prod-sendgrid-config`           | `terraform/environments/prod/sendgrid/config/`           |
| `homelab-cloudflare-dns-records` | `terraform/environments/homelab/cloudflare/dns-records/` |
| `homelab-digitalocean-k3s-agent` | `terraform/environments/homelab/digitalocean/k3s-agent/` |
| `homelab-tailscale-acl`          | `terraform/environments/homelab/tailscale/acl/`          |

### Credential management

All credentials are sourced from environment variables -- nothing is hardcoded. Both providers read their credentials from env vars automatically with zero provider-block configuration.

The `.env` file is gitignored. The `.envrc` file (committed) loads it via direnv. The `.env.example` file (committed) documents which variables are needed.

---

## Ansible

Ansible manages the homelab k3s cluster -- deploying Helm charts, configuring services, and managing secrets. All configuration lives under `ansible/`.

See `ansible/CLAUDE.md` for full documentation (layout, running, secrets, SSH access).

### Quick commands

```bash
# Deploy a specific service
./ansible/run-ansible.sh playbook playbooks/helm-deploy.yml --tags <service>

# Deploy all services
./ansible/run-ansible.sh playbook playbooks/helm-deploy.yml
```

---

## Helm Charts

`helm-charts/` is a git submodule pointing to `InfiniteRoomLabs/helm-charts`. Available charts:

| Chart             | Purpose                               |
|-------------------|---------------------------------------|
| `irl-caddy`       | Reverse proxy with ACME DNS-01        |
| `irl-garage`      | S3-compatible object storage          |
| `irl-gitea`       | Self-hosted Git                       |
| `irl-monitoring`  | Prometheus + Grafana + Loki stack     |
| `irl-openviking`  | Agent memory / RAG service            |
| `irl-postgres`    | PostgreSQL via CNPG                   |
| `irl-valkey`      | Redis-compatible key-value store      |
| `irl-vaultwarden` | Bitwarden-compatible password manager |

Charts are deployed via Ansible (`ansible/playbooks/helm-deploy.yml`), never manually. Values overrides live in `ansible/helm/{name}/values.yaml`.

---

## Docker

Custom container image Dockerfiles live under `docker/`. It currently contains:

- `docker/caddy/` -- Custom Caddy build with the Cloudflare DNS plugin

---

## Secrets Sync

`scripts/bw-sync.sh` syncs secrets from Bitwarden to Ansible Vault and Kubernetes. See the parent org [CLAUDE.md](../CLAUDE.md) for the full secrets management workflow.

```bash
./scripts/bw-sync.sh --target both            # Sync to Ansible Vault + Kubernetes
./scripts/bw-sync.sh --dry-run --target both  # Preview without writing
./scripts/bw-sync.sh --check-rotation         # Check rotation policy compliance
./scripts/bw-sync.sh --verify-k8s             # Verify K8s secrets match Bitwarden
```

---

## Testing

See [TESTING.md](TESTING.md) for the full acceptance test suite. Quick: `cd tests/ && task smoke`.

---

## Troubleshooting

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
