# cloudflare-pages

Terraform module for managing Cloudflare Pages project shells, custom domain
bindings, and CNAME DNS records.

## Important: Manual GitHub Connection Required

This module creates the Pages project, but does NOT configure the GitHub source
connection. After the first `terraform apply`, you must manually connect the
GitHub repository via the Cloudflare dashboard:

1. Go to Cloudflare Dashboard > Workers & Pages
2. Select the project created by this module
3. Go to Settings > Builds & Deployments > Source
4. Connect to GitHub and select the repository
5. Configure the production branch to match the `production_branch` variable

This is required because the Cloudflare Terraform provider treats the `source`
block as read-only (see [cloudflare/terraform-provider-cloudflare#5093](https://github.com/cloudflare/terraform-provider-cloudflare/issues/5093)).

## Usage

```hcl
module "pages" {
  source = "git::https://github.com/InfiniteRoomLabs/infinite-room-labs-infra.git//terraform/modules/cloudflare-pages?ref=v0.1.0"

  account_id       = var.cloudflare_account_id
  project_name     = "my-app"
  production_branch = "main"
  build_command    = "bun run build"
  build_output_dir = "dist"
  custom_domains   = ["my-app.infiniteroomlabs.dev"]
  zone_id          = var.cloudflare_zone_id
}
```

## Inputs

| Name | Type | Default | Required | Description |
|------|------|---------|----------|-------------|
| account_id | string | - | yes | Cloudflare account ID |
| project_name | string | - | yes | Name of the Cloudflare Pages project |
| production_branch | string | "main" | no | Git branch that triggers production deployments |
| build_command | string | - | yes | Command to build the project |
| build_output_dir | string | - | yes | Output directory of the build |
| root_dir | string | "/" | no | Directory within the repo to use as build root |
| custom_domains | list(string) | [] | no | Custom domains to bind |
| zone_id | string | "" | no | Cloudflare zone ID for DNS record creation |
| build_caching | bool | true | no | Enable build caching |

## Outputs

| Name | Sensitive | Description |
|------|-----------|-------------|
| project_url | no | Default pages.dev URL |
| subdomain | yes | The pages.dev subdomain |
| custom_domain_statuses | no | Map of domain to activation status |
