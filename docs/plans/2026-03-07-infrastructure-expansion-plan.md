# Infrastructure Expansion Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement Phases 0.5, 1.25, 2.5 of the infrastructure expansion -- managed observability accounts, OTel pipeline, Netdata, Grafana Cloud dashboards, Ghost CMS website on Cloudflare Pages, and project onboarding automation.

**Architecture:** OTel-centric observability pipeline exporting to Grafana Cloud (managed free tier). Netdata on every node for system metrics. Ghost CMS behind Tailscale serving content via API to Astro static builds deployed on Cloudflare Pages. All services containerized with Docker Compose, deployed via Ansible, IaC-managed with Terraform/Terragrunt.

> **UPDATE 2026-03-21**: The architecture has pivoted from Docker Compose + Grafana Cloud to **k3s + Helm + self-hosted observability**. The OTel pipeline concept remains valid but targets self-hosted Prometheus/Loki/Tempo instead of Grafana Cloud. See the active deployment plan at `docs/plans/2026-03-20-homelab-k3s-helm-deployment.md` for current decisions and the observability architecture diagram. The monitoring stack is `irl-monitoring` in `InfiniteRoomLabs/helm-charts`.

**Tech Stack:** Terraform + Terragrunt (Grafana Cloud provider, Cloudflare provider), Ansible, Docker Compose, OpenTelemetry Collector, Netdata, Grafana Cloud, Sentry, Ghost CMS, Astro, Cloudflare Pages.

**Dependencies:** Phase 1.25+ tasks require Phase 1 (Tailscale + Vault) to be complete first. Phase 0.5 and scaffolding tasks can run immediately.

**Design doc:** `docs/plans/2026-03-07-infrastructure-expansion-design.md`

---

## Task 1: Document Free Tier Accounts and Limits

Phase 0.5 -- capture account information and free tier limits as a reference document in the repo.

**Files:**
- Create: `docs/accounts/free-tier-inventory.md`

**Step 1: Create accounts directory**

```bash
mkdir -p docs/accounts
```

**Step 2: Write free tier inventory document**

Create `docs/accounts/free-tier-inventory.md` with this content:

```markdown
# Free Tier Inventory

Managed service accounts used by IRL infrastructure. Update this document when accounts are created or limits change.

## Active Accounts

### Grafana Cloud

- **URL**: https://grafana.com/ (sign up at grafana.com/auth/sign-up/create-user)
- **Tier**: Free
- **Limits**:
  - 10,000 active metrics series
  - 50 GB logs
  - 50 GB traces
  - 14-day retention
  - 3 users
- **Services included**: Managed Prometheus, Loki, Tempo, Grafana dashboards
- **Status**: [ ] Account created
- **Credentials**: Store API keys in Vault (Phase 1) or env vars until then

### Sentry

- **URL**: https://sentry.io/
- **Tier**: Developer (free)
- **Limits**:
  - 5,000 errors/month
  - 10,000 performance units/month
  - 1 GB attachments
  - 1 user
  - 30-day retention
- **Status**: [ ] Account created
- **DSN**: Store in Vault (Phase 1) or env vars until then

### Cloudflare

- **URL**: https://dash.cloudflare.com/
- **Tier**: Free
- **Services used**: DNS zones, email routing, Pages (500 builds/mo, unlimited bandwidth)
- **Status**: [x] Active -- DNS zones for all domains

### Oracle Cloud

- **Tier**: Always Free
- **Limits**: 4 OCPU, 24 GB RAM (ARM), 200 GB block storage, 2 AMD VMs
- **Status**: [ ] Account created

### Terraform Cloud

- **URL**: https://app.terraform.io/
- **Org**: infinite-room-labs
- **Tier**: Free (5 users, unlimited workspaces)
- **Status**: [x] Active

## Planned Accounts

### Netdata Cloud (optional)

- **Tier**: Free (5 nodes)
- **Evaluate during**: Phase 1.25
- **Status**: [ ] Not yet needed
```

**Step 3: Commit**

```bash
git add docs/accounts/free-tier-inventory.md
git commit -m "Add free tier inventory document for Phase 0.5"
```

---

## Task 2: Add Grafana Cloud Provider to Root Terragrunt Config

Extend `root.hcl` to include the Grafana provider so Grafana Cloud resources (dashboards, alerts, data sources) can be managed via Terraform.

**Files:**
- Modify: `terraform/root.hcl`

**Step 1: Research the Grafana Terraform provider**

Check the latest Grafana provider version:

```bash
# Use the Terraform MCP tool: get_latest_provider_version for grafana/grafana
# Or check: https://registry.terraform.io/providers/grafana/grafana/latest
```

**Step 2: Update root.hcl to include the Grafana provider**

The root.hcl `generate "providers"` block currently only includes Cloudflare and Porkbun. However, the root config applies to ALL leaf modules via `include "root"`. Since not every leaf needs the Grafana provider, do NOT add it to root.hcl's global providers block.

Instead, create a provider.hcl for Grafana Cloud at the environment level (same pattern as Cloudflare and Porkbun):

**Files:**
- Create: `terraform/environments/prod/grafana-cloud/provider.hcl`

```hcl
# Grafana Cloud provider configuration
# Auth: GRAFANA_AUTH env var (API key or service account token)
# URL: GRAFANA_CLOUD_STACK_SLUG determines the stack URL

generate "grafana_provider" {
  path      = "provider-grafana.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    terraform {
      required_providers {
        grafana = {
          source  = "grafana/grafana"
          version = "~> 3.0"
        }
      }
    }

    provider "grafana" {
      # Uses GRAFANA_AUTH and GRAFANA_URL environment variables
    }
  EOF
}
```

**Step 3: Create environment directory structure**

```bash
mkdir -p terraform/environments/prod/grafana-cloud/dashboards
mkdir -p terraform/environments/prod/grafana-cloud/alerts
mkdir -p terraform/environments/prod/grafana-cloud/data-sources
```

**Step 4: Commit**

```bash
git add terraform/environments/prod/grafana-cloud/
git commit -m "Scaffold Grafana Cloud Terraform environment with provider config"
```

---

## Task 3: Scaffold Ansible Directory Structure

There is no Ansible directory in the repo yet. Create the foundational structure that all roles will live in.

**Files:**
- Create: `ansible/ansible.cfg`
- Create: `ansible/site.yml`
- Create: `ansible/inventory/hosts.yml`
- Create: `ansible/requirements.yml`
- Create: `ansible/group_vars/all.yml`
- Create: `ansible/README.md`

**Step 1: Create directory structure**

```bash
mkdir -p ansible/{inventory,group_vars,host_vars,roles,playbooks}
```

**Step 2: Write ansible.cfg**

```ini
[defaults]
inventory = inventory/hosts.yml
roles_path = roles
retry_files_enabled = false
stdout_callback = yaml
host_key_checking = false

[privilege_escalation]
become = true
become_method = sudo
```

**Step 3: Write inventory/hosts.yml**

```yaml
---
# Inventory for IRL infrastructure
# Update as nodes are provisioned
all:
  children:
    oracle_arm:
      hosts: {}
      # Add Oracle ARM VM(s) here when provisioned:
      # oracle-arm-01:
      #   ansible_host: <tailscale-ip>
      #   ansible_user: ubuntu
    proxmox:
      hosts: {}
      # Add Proxmox VMs here when available:
      # proxmox-vm-01:
      #   ansible_host: <tailscale-ip>
      #   ansible_user: ubuntu
  vars:
    # OTel Collector endpoint (set when Phase 1.25 deploys)
    otel_collector_endpoint: "http://otel-collector:4317"
```

**Step 4: Write group_vars/all.yml**

```yaml
---
# Global variables for all hosts
docker_compose_version: "2.27"
tailscale_domain: "tail-xxxxx.ts.net"  # Update with actual tailnet domain
```

**Step 5: Write site.yml**

```yaml
---
# Main playbook -- apply all roles based on group membership
- name: Common setup for all nodes
  hosts: all
  roles:
    - role: netdata
      tags: [netdata, monitoring]

- name: Observability infrastructure
  hosts: oracle_arm
  roles:
    - role: otel-collector
      tags: [otel, monitoring]
```

**Step 6: Write requirements.yml**

```yaml
---
# Ansible Galaxy requirements
collections:
  - name: community.docker
    version: ">=3.0.0"
  - name: community.general
    version: ">=9.0.0"
```

**Step 7: Write README.md**

```markdown
# Ansible Configuration Management

Ansible roles for deploying and configuring IRL infrastructure services.

## Prerequisites

- Ansible >= 2.15
- Python 3.10+
- Tailscale connected to the IRL tailnet

## Setup

Install Galaxy requirements:

    ansible-galaxy install -r requirements.yml

## Usage

Deploy everything:

    ansible-playbook site.yml

Deploy specific roles:

    ansible-playbook site.yml --tags netdata
    ansible-playbook site.yml --tags otel

Deploy to specific hosts:

    ansible-playbook site.yml --limit oracle-arm-01

## Adding a New Role

1. Create role scaffold: `ansible/roles/<role-name>/`
2. Minimum files: `tasks/main.yml`, `defaults/main.yml`, `templates/`, `handlers/main.yml`
3. Add role to appropriate play in `site.yml`
4. Document required variables in `defaults/main.yml` with comments
```

**Step 8: Commit**

```bash
git add ansible/
git commit -m "Scaffold Ansible directory structure for configuration management"
```

---

## Task 4: Create OTel Collector Ansible Role

Ansible role to deploy the OpenTelemetry Collector as a Docker Compose service. The collector receives OTLP data from applications and infrastructure, then exports to Grafana Cloud.

**Depends on:** Task 3 (Ansible scaffold), Phase 1 (Tailscale -- for networking)

**Files:**
- Create: `ansible/roles/otel-collector/defaults/main.yml`
- Create: `ansible/roles/otel-collector/tasks/main.yml`
- Create: `ansible/roles/otel-collector/templates/otel-collector-config.yml.j2`
- Create: `ansible/roles/otel-collector/templates/docker-compose.yml.j2`
- Create: `ansible/roles/otel-collector/handlers/main.yml`

**Step 1: Write defaults/main.yml**

```yaml
---
# OTel Collector configuration
# Required variables (no defaults -- must be set):
#   otel_grafana_prometheus_url: Grafana Cloud Prometheus remote write URL
#   otel_grafana_prometheus_user: Grafana Cloud Prometheus username (instance ID)
#   otel_grafana_prometheus_password: Grafana Cloud API key
#   otel_grafana_loki_url: Grafana Cloud Loki push URL
#   otel_grafana_loki_user: Grafana Cloud Loki username (instance ID)
#   otel_grafana_loki_password: Grafana Cloud API key
#   otel_grafana_tempo_url: Grafana Cloud Tempo push URL
#   otel_grafana_tempo_user: Grafana Cloud Tempo username (instance ID)
#   otel_grafana_tempo_password: Grafana Cloud API key

# Optional overrides
otel_collector_image: "otel/opentelemetry-collector-contrib:latest"
otel_collector_grpc_port: 4317
otel_collector_http_port: 4318
otel_collector_memory_limit_mib: 256
otel_collector_install_dir: "/opt/otel-collector"

# Prometheus scrape targets (infrastructure services with /metrics endpoints)
# Add services here as they're deployed
otel_scrape_targets: []
# Example:
# otel_scrape_targets:
#   - job_name: vault
#     targets: ["vault.tailscale:8200"]
#     metrics_path: /v1/sys/metrics
#     params:
#       format: ["prometheus"]
```

**Step 2: Write templates/otel-collector-config.yml.j2**

```yaml
# OpenTelemetry Collector Configuration
# Managed by Ansible -- do not edit manually

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: "0.0.0.0:{{ otel_collector_grpc_port }}"
      http:
        endpoint: "0.0.0.0:{{ otel_collector_http_port }}"

  hostmetrics:
    collection_interval: 30s
    scrapers:
      cpu: {}
      memory: {}
      disk: {}
      filesystem: {}
      network: {}
      load: {}

{% if otel_scrape_targets | length > 0 %}
  prometheus:
    config:
      scrape_configs:
{% for target in otel_scrape_targets %}
        - job_name: "{{ target.job_name }}"
          scrape_interval: 30s
          static_configs:
            - targets: {{ target.targets | to_json }}
{% if target.metrics_path is defined %}
          metrics_path: "{{ target.metrics_path }}"
{% endif %}
{% if target.params is defined %}
          params:
{{ target.params | to_nice_yaml(indent=12) }}
{% endif %}
{% endfor %}
{% endif %}

processors:
  batch:
    timeout: 10s
    send_batch_size: 1024

  memory_limiter:
    check_interval: 5s
    limit_mib: {{ otel_collector_memory_limit_mib }}

  resourcedetection:
    detectors: [system]
    system:
      hostname_sources: [os]

exporters:
  prometheusremotewrite:
    endpoint: "{{ otel_grafana_prometheus_url }}"
    auth:
      authenticator: basicauth/prometheus

  otlphttp/loki:
    endpoint: "{{ otel_grafana_loki_url }}"
    auth:
      authenticator: basicauth/loki

  otlphttp/tempo:
    endpoint: "{{ otel_grafana_tempo_url }}"
    auth:
      authenticator: basicauth/tempo

extensions:
  basicauth/prometheus:
    client_auth:
      username: "{{ otel_grafana_prometheus_user }}"
      password: "{{ otel_grafana_prometheus_password }}"

  basicauth/loki:
    client_auth:
      username: "{{ otel_grafana_loki_user }}"
      password: "{{ otel_grafana_loki_password }}"

  basicauth/tempo:
    client_auth:
      username: "{{ otel_grafana_tempo_user }}"
      password: "{{ otel_grafana_tempo_password }}"

service:
  extensions: [basicauth/prometheus, basicauth/loki, basicauth/tempo]
  pipelines:
    metrics:
      receivers: [otlp, hostmetrics{% if otel_scrape_targets | length > 0 %}, prometheus{% endif %}]
      processors: [memory_limiter, resourcedetection, batch]
      exporters: [prometheusremotewrite]
    logs:
      receivers: [otlp]
      processors: [memory_limiter, resourcedetection, batch]
      exporters: [otlphttp/loki]
    traces:
      receivers: [otlp]
      processors: [memory_limiter, resourcedetection, batch]
      exporters: [otlphttp/tempo]
```

**Step 3: Write templates/docker-compose.yml.j2**

```yaml
# OTel Collector Docker Compose
# Managed by Ansible -- do not edit manually

services:
  otel-collector:
    image: {{ otel_collector_image }}
    container_name: otel-collector
    restart: unless-stopped
    ports:
      - "{{ otel_collector_grpc_port }}:{{ otel_collector_grpc_port }}"
      - "{{ otel_collector_http_port }}:{{ otel_collector_http_port }}"
    volumes:
      - ./otel-collector-config.yml:/etc/otelcol-contrib/config.yaml:ro
    mem_limit: {{ otel_collector_memory_limit_mib }}m
```

**Step 4: Write tasks/main.yml**

```yaml
---
- name: Validate required variables
  ansible.builtin.assert:
    that:
      - otel_grafana_prometheus_url is defined
      - otel_grafana_prometheus_user is defined
      - otel_grafana_prometheus_password is defined
      - otel_grafana_loki_url is defined
      - otel_grafana_loki_user is defined
      - otel_grafana_loki_password is defined
      - otel_grafana_tempo_url is defined
      - otel_grafana_tempo_user is defined
      - otel_grafana_tempo_password is defined
    fail_msg: "Grafana Cloud credentials must be set. See defaults/main.yml for required variables."

- name: Create OTel Collector directory
  ansible.builtin.file:
    path: "{{ otel_collector_install_dir }}"
    state: directory
    mode: "0755"

- name: Deploy OTel Collector configuration
  ansible.builtin.template:
    src: otel-collector-config.yml.j2
    dest: "{{ otel_collector_install_dir }}/otel-collector-config.yml"
    mode: "0600"
  notify: restart otel-collector

- name: Deploy Docker Compose file
  ansible.builtin.template:
    src: docker-compose.yml.j2
    dest: "{{ otel_collector_install_dir }}/docker-compose.yml"
    mode: "0644"
  notify: restart otel-collector

- name: Start OTel Collector
  community.docker.docker_compose_v2:
    project_src: "{{ otel_collector_install_dir }}"
    state: present
```

**Step 5: Write handlers/main.yml**

```yaml
---
- name: restart otel-collector
  community.docker.docker_compose_v2:
    project_src: "{{ otel_collector_install_dir }}"
    state: restarted
```

**Step 6: Verify role structure**

```bash
find ansible/roles/otel-collector -type f | sort
# Expected:
# ansible/roles/otel-collector/defaults/main.yml
# ansible/roles/otel-collector/handlers/main.yml
# ansible/roles/otel-collector/tasks/main.yml
# ansible/roles/otel-collector/templates/docker-compose.yml.j2
# ansible/roles/otel-collector/templates/otel-collector-config.yml.j2
```

**Step 7: Commit**

```bash
git add ansible/roles/otel-collector/
git commit -m "Add OTel Collector Ansible role for Phase 1.25 observability"
```

---

## Task 5: Create Netdata Ansible Role

Ansible role to deploy Netdata on every node for system-level metrics and local dashboards. Exports metrics to the OTel Collector.

**Depends on:** Task 3 (Ansible scaffold)

**Files:**
- Create: `ansible/roles/netdata/defaults/main.yml`
- Create: `ansible/roles/netdata/tasks/main.yml`
- Create: `ansible/roles/netdata/templates/netdata.conf.j2`
- Create: `ansible/roles/netdata/templates/exporting.conf.j2`
- Create: `ansible/roles/netdata/handlers/main.yml`

**Step 1: Write defaults/main.yml**

```yaml
---
# Netdata configuration
netdata_install_method: "docker"  # "docker" or "package"

# Docker settings (when install_method = docker)
netdata_image: "netdata/netdata:stable"
netdata_install_dir: "/opt/netdata"
netdata_web_port: 19999

# OTel Collector export target
netdata_otel_export_enabled: true
netdata_otel_collector_url: "{{ otel_collector_endpoint | default('http://otel-collector:4317') }}"

# Prometheus remote write (to OTel Collector's Prometheus receiver)
netdata_prometheus_remote_write_url: "http://otel-collector:9090/api/v1/write"

# Memory limit
netdata_memory_limit_mib: 150
```

**Step 2: Write templates/netdata.conf.j2**

```ini
# Netdata configuration
# Managed by Ansible -- do not edit manually

[global]
    hostname = {{ ansible_hostname }}
    memory mode = ram
    history = 3600

[web]
    bind to = 0.0.0.0:{{ netdata_web_port }}
    allow connections from = *
```

**Step 3: Write templates/exporting.conf.j2**

```ini
# Netdata exporting configuration
# Exports metrics to OTel Collector via Prometheus remote write
# Managed by Ansible -- do not edit manually

[exporting:global]
    enabled = yes
    update every = 10

{% if netdata_otel_export_enabled %}
[prometheus_remote_write:otel_collector]
    enabled = yes
    destination = {{ netdata_prometheus_remote_write_url }}
    remote write URL path = /api/v1/write
{% endif %}
```

**Step 4: Write templates/docker-compose.yml.j2**

```yaml
# Netdata Docker Compose
# Managed by Ansible -- do not edit manually

services:
  netdata:
    image: {{ netdata_image }}
    container_name: netdata
    hostname: {{ ansible_hostname }}
    restart: unless-stopped
    ports:
      - "{{ netdata_web_port }}:{{ netdata_web_port }}"
    cap_add:
      - SYS_PTRACE
      - SYS_ADMIN
    security_opt:
      - apparmor:unconfined
    volumes:
      - netdataconfig:/etc/netdata
      - netdatalib:/var/lib/netdata
      - netdatacache:/var/cache/netdata
      - /etc/passwd:/host/etc/passwd:ro
      - /etc/group:/host/etc/group:ro
      - /etc/localtime:/etc/localtime:ro
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /etc/os-release:/host/etc/os-release:ro
      - /var/log:/host/var/log:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./netdata.conf:/etc/netdata/netdata.conf:ro
      - ./exporting.conf:/etc/netdata/exporting.conf:ro
    mem_limit: {{ netdata_memory_limit_mib }}m

volumes:
  netdataconfig:
  netdatalib:
  netdatacache:
```

**Step 5: Write tasks/main.yml**

```yaml
---
- name: Create Netdata directory
  ansible.builtin.file:
    path: "{{ netdata_install_dir }}"
    state: directory
    mode: "0755"

- name: Deploy Netdata configuration
  ansible.builtin.template:
    src: netdata.conf.j2
    dest: "{{ netdata_install_dir }}/netdata.conf"
    mode: "0644"
  notify: restart netdata

- name: Deploy exporting configuration
  ansible.builtin.template:
    src: exporting.conf.j2
    dest: "{{ netdata_install_dir }}/exporting.conf"
    mode: "0644"
  notify: restart netdata

- name: Deploy Docker Compose file
  ansible.builtin.template:
    src: docker-compose.yml.j2
    dest: "{{ netdata_install_dir }}/docker-compose.yml"
    mode: "0644"
  notify: restart netdata

- name: Start Netdata
  community.docker.docker_compose_v2:
    project_src: "{{ netdata_install_dir }}"
    state: present
```

**Step 6: Write handlers/main.yml**

```yaml
---
- name: restart netdata
  community.docker.docker_compose_v2:
    project_src: "{{ netdata_install_dir }}"
    state: restarted
```

**Step 7: Commit**

```bash
git add ansible/roles/netdata/
git commit -m "Add Netdata Ansible role for node-level system metrics"
```

---

## Task 6: Create Grafana Cloud Dashboard Terraform Module

Terraform module + Terragrunt leaf to provision Grafana Cloud dashboards and data sources via the Grafana provider.

**Depends on:** Task 2 (Grafana Cloud provider)

**Files:**
- Create: `terraform/modules/grafana-cloud-stack/main.tf`
- Create: `terraform/modules/grafana-cloud-stack/variables.tf`
- Create: `terraform/modules/grafana-cloud-stack/outputs.tf`
- Create: `terraform/environments/prod/grafana-cloud/data-sources/terragrunt.hcl`

**Step 1: Write the Terraform module**

`terraform/modules/grafana-cloud-stack/variables.tf`:

```hcl
variable "stack_slug" {
  type        = string
  description = "Grafana Cloud stack slug (from your Grafana Cloud account)"
}

variable "prometheus_url" {
  type        = string
  description = "Grafana Cloud Prometheus datasource URL"
}

variable "loki_url" {
  type        = string
  description = "Grafana Cloud Loki datasource URL"
}

variable "tempo_url" {
  type        = string
  description = "Grafana Cloud Tempo datasource URL"
}
```

`terraform/modules/grafana-cloud-stack/main.tf`:

```hcl
# Grafana Cloud data source configuration
# Ensures Prometheus, Loki, and Tempo data sources exist and are configured

resource "grafana_data_source" "prometheus" {
  type = "prometheus"
  name = "IRL Prometheus"
  url  = var.prometheus_url

  json_data_encoded = jsonencode({
    httpMethod = "POST"
  })
}

resource "grafana_data_source" "loki" {
  type = "loki"
  name = "IRL Loki"
  url  = var.loki_url
}

resource "grafana_data_source" "tempo" {
  type = "tempo"
  name = "IRL Tempo"
  url  = var.tempo_url

  json_data_encoded = jsonencode({
    tracesToLogsV2 = {
      datasourceUid = grafana_data_source.loki.uid
    }
    tracesToMetrics = {
      datasourceUid = grafana_data_source.prometheus.uid
    }
  })
}

resource "grafana_folder" "irl_internal" {
  title = "IRL Internal"
}
```

`terraform/modules/grafana-cloud-stack/outputs.tf`:

```hcl
output "prometheus_datasource_uid" {
  value = grafana_data_source.prometheus.uid
}

output "loki_datasource_uid" {
  value = grafana_data_source.loki.uid
}

output "tempo_datasource_uid" {
  value = grafana_data_source.tempo.uid
}

output "irl_folder_uid" {
  value = grafana_folder.irl_internal.uid
}
```

**Step 2: Write the Terragrunt leaf config**

`terraform/environments/prod/grafana-cloud/data-sources/terragrunt.hcl`:

```hcl
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "provider" {
  path   = find_in_parent_folders("provider.hcl")
  expose = true
}

terraform {
  source = "${get_repo_root()}/terraform/modules//grafana-cloud-stack"
}

inputs = {
  stack_slug     = get_env("GRAFANA_CLOUD_STACK_SLUG", "")
  prometheus_url = get_env("GRAFANA_CLOUD_PROMETHEUS_URL", "")
  loki_url       = get_env("GRAFANA_CLOUD_LOKI_URL", "")
  tempo_url      = get_env("GRAFANA_CLOUD_TEMPO_URL", "")
}
```

**Step 3: Validate**

```bash
cd terraform/environments/prod/grafana-cloud/data-sources
terragrunt validate
# Expected: Success (or warning about missing env vars -- that's OK)
```

**Step 4: Commit**

```bash
git add terraform/modules/grafana-cloud-stack/ terraform/environments/prod/grafana-cloud/
git commit -m "Add Grafana Cloud Terraform module and Terragrunt config for data sources"
```

---

## Task 7: Create Ghost CMS Ansible Role

Ansible role to deploy Ghost CMS as a Docker Compose service. Ghost admin is Tailscale-only; Content API is used by Astro for static builds.

**Depends on:** Task 3 (Ansible scaffold), Phase 1 (Tailscale)

**Files:**
- Create: `ansible/roles/ghost/defaults/main.yml`
- Create: `ansible/roles/ghost/tasks/main.yml`
- Create: `ansible/roles/ghost/templates/docker-compose.yml.j2`
- Create: `ansible/roles/ghost/handlers/main.yml`

**Step 1: Write defaults/main.yml**

```yaml
---
# Ghost CMS configuration
ghost_image: "ghost:5-alpine"
ghost_install_dir: "/opt/ghost"
ghost_port: 2368

# Ghost URL -- the public-facing URL where the site is served
# This is what Ghost uses for generating links in the Content API
ghost_url: "https://infiniteroomlabs.com"

# Database -- SQLite by default, switch to MySQL when needed
ghost_database_type: "sqlite3"
ghost_database_filename: "/var/lib/ghost/content/data/ghost.db"

# Content API key -- generated after first Ghost setup
# Used by Astro to fetch content at build time
# ghost_content_api_key: "set-after-initial-setup"

# Memory limit
ghost_memory_limit_mib: 256
```

**Step 2: Write templates/docker-compose.yml.j2**

```yaml
# Ghost CMS Docker Compose
# Managed by Ansible -- do not edit manually

services:
  ghost:
    image: {{ ghost_image }}
    container_name: ghost
    restart: unless-stopped
    ports:
      - "{{ ghost_port }}:2368"
    environment:
      url: {{ ghost_url }}
      database__client: {{ ghost_database_type }}
{% if ghost_database_type == 'sqlite3' %}
      database__connection__filename: {{ ghost_database_filename }}
{% endif %}
    volumes:
      - ghost-content:/var/lib/ghost/content
    mem_limit: {{ ghost_memory_limit_mib }}m

volumes:
  ghost-content:
```

**Step 3: Write tasks/main.yml**

```yaml
---
- name: Create Ghost directory
  ansible.builtin.file:
    path: "{{ ghost_install_dir }}"
    state: directory
    mode: "0755"

- name: Deploy Docker Compose file
  ansible.builtin.template:
    src: docker-compose.yml.j2
    dest: "{{ ghost_install_dir }}/docker-compose.yml"
    mode: "0644"
  notify: restart ghost

- name: Start Ghost CMS
  community.docker.docker_compose_v2:
    project_src: "{{ ghost_install_dir }}"
    state: present
```

**Step 4: Write handlers/main.yml**

```yaml
---
- name: restart ghost
  community.docker.docker_compose_v2:
    project_src: "{{ ghost_install_dir }}"
    state: restarted
```

**Step 5: Commit**

```bash
git add ansible/roles/ghost/
git commit -m "Add Ghost CMS Ansible role for Phase 2.5 company website"
```

---

## Task 8: Create Cloudflare Pages Terraform Module

Terraform module + Terragrunt leaf to provision a Cloudflare Pages project with custom domains for the company website.

**Files:**
- Create: `terraform/modules/cloudflare-pages/main.tf`
- Create: `terraform/modules/cloudflare-pages/variables.tf`
- Create: `terraform/modules/cloudflare-pages/outputs.tf`
- Create: `terraform/environments/prod/cloudflare/pages-website/terragrunt.hcl`

**Step 1: Write the module**

`terraform/modules/cloudflare-pages/variables.tf`:

```hcl
variable "account_id" {
  type        = string
  description = "Cloudflare account ID"
}

variable "project_name" {
  type        = string
  description = "Name of the Pages project"
}

variable "production_branch" {
  type        = string
  default     = "main"
  description = "Git branch that triggers production deploys"
}

variable "custom_domains" {
  type        = list(string)
  default     = []
  description = "Custom domains to attach to the Pages project"
}
```

`terraform/modules/cloudflare-pages/main.tf`:

```hcl
resource "cloudflare_pages_project" "site" {
  account_id      = var.account_id
  name            = var.project_name
  production_branch = var.production_branch
}

resource "cloudflare_pages_domain" "domains" {
  for_each = toset(var.custom_domains)

  account_id   = var.account_id
  project_name = cloudflare_pages_project.site.name
  domain       = each.value
}
```

`terraform/modules/cloudflare-pages/outputs.tf`:

```hcl
output "pages_project_name" {
  value = cloudflare_pages_project.site.name
}

output "pages_subdomain" {
  value = cloudflare_pages_project.site.subdomain
}

output "custom_domain_statuses" {
  value = { for k, v in cloudflare_pages_domain.domains : k => v.status }
}
```

**Step 2: Write the Terragrunt leaf**

`terraform/environments/prod/cloudflare/pages-website/terragrunt.hcl`:

```hcl
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "provider" {
  path   = find_in_parent_folders("provider.hcl")
  expose = true
}

locals {
  env_config = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

dependency "bootstrap_tokens" {
  config_path = "${get_repo_root()}/terraform/environments/global/cloudflare/tokens"

  mock_outputs = {
    api_token = ""
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

terraform {
  source = "${get_repo_root()}/terraform/modules//cloudflare-pages"
}

inputs = {
  account_id          = local.env_config.locals.cloudflare_account_id
  project_name        = "irl-website"
  production_branch   = "main"
  custom_domains      = [
    "infiniteroomlabs.com",
    "www.infiniteroomlabs.com",
  ]
  bootstrap_api_token = dependency.bootstrap_tokens.outputs.api_token
}
```

**Step 3: Commit**

```bash
git add terraform/modules/cloudflare-pages/ terraform/environments/prod/cloudflare/pages-website/
git commit -m "Add Cloudflare Pages Terraform module for company website"
```

---

## Task 9: Write Project Onboarding Runbooks

Create documentation for onboarding new applications and nodes into the observability pipeline.

**Files:**
- Create: `docs/runbooks/add-new-project.md`
- Create: `docs/runbooks/add-new-node.md`
- Create: `docs/runbooks/observability-troubleshooting.md`

**Step 1: Create runbooks directory**

```bash
mkdir -p docs/runbooks
```

**Step 2: Write add-new-project.md**

```markdown
# Onboarding a New Project to Observability

Add OpenTelemetry instrumentation to any IRL project to send metrics, logs, and traces to the central pipeline.

## Prerequisites

- OTel Collector deployed (Phase 1.25)
- Grafana Cloud account configured
- Project can reach the OTel Collector via Tailscale

## Steps

### 1. Install OTel SDK

Choose the SDK for your language:

**Python:**
    pip install opentelemetry-sdk opentelemetry-exporter-otlp opentelemetry-instrumentation

**Node.js:**
    npm install @opentelemetry/sdk-node @opentelemetry/exporter-trace-otlp-grpc @opentelemetry/auto-instrumentations-node

**PHP (via Composer):**
    composer require open-telemetry/sdk open-telemetry/exporter-otlp

**Kotlin/Java (via Gradle):**
    implementation("io.opentelemetry:opentelemetry-sdk:1.x.x")
    implementation("io.opentelemetry:opentelemetry-exporter-otlp:1.x.x")

### 2. Set Environment Variables

Add to your service's environment (Docker Compose, .env, etc.):

    OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.tailscale:4317
    OTEL_SERVICE_NAME=my-service-name
    OTEL_RESOURCE_ATTRIBUTES=deployment.environment=prod,service.namespace=irl

### 3. Add Sentry (Optional)

For error tracking:

    SENTRY_DSN=<dsn-from-sentry-account>

Sentry's SDK integrates with OTel spans for correlated error + trace views.

### 4. Verify Data Flow

1. Start the service
2. Generate some traffic
3. Check Grafana Cloud dashboards for the new service name
4. Verify traces appear in Tempo
5. Verify logs appear in Loki

## Docker Compose Snippet

Add this to any Docker Compose service:

    environment:
      OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector:4317"
      OTEL_SERVICE_NAME: "my-service"
      OTEL_RESOURCE_ATTRIBUTES: "deployment.environment=prod"
```

**Step 3: Write add-new-node.md**

```markdown
# Onboarding a New Node to Monitoring

Deploy Netdata and connect a new infrastructure node to the observability pipeline.

## Prerequisites

- Node accessible via Tailscale
- Docker installed on the node
- Node added to Ansible inventory (`ansible/inventory/hosts.yml`)

## Steps

### 1. Add Node to Ansible Inventory

Edit `ansible/inventory/hosts.yml`:

    all:
      children:
        oracle_arm:
          hosts:
            new-node-name:
              ansible_host: <tailscale-ip>
              ansible_user: ubuntu

### 2. Run Ansible Playbook

    cd ansible
    ansible-playbook site.yml --limit new-node-name --tags netdata

### 3. Verify

1. Access Netdata dashboard: `http://<tailscale-ip>:19999`
2. Check Grafana Cloud for metrics from the new host
3. Verify host appears in the "Node Metrics" dashboard

## Manual Docker Deployment (without Ansible)

If Ansible isn't available:

    docker run -d --name=netdata \
      --hostname=$(hostname) \
      --cap-add SYS_PTRACE --cap-add SYS_ADMIN \
      -p 19999:19999 \
      -v /proc:/host/proc:ro \
      -v /sys:/host/sys:ro \
      -v /var/run/docker.sock:/var/run/docker.sock:ro \
      netdata/netdata:stable
```

**Step 4: Write observability-troubleshooting.md**

```markdown
# Observability Troubleshooting

Common issues and solutions for the IRL observability stack.

## OTel Collector Not Receiving Data

1. Check collector is running: `docker ps | grep otel-collector`
2. Check collector logs: `docker logs otel-collector`
3. Verify endpoint reachable: `curl -v http://otel-collector:4318/v1/traces`
4. Check Tailscale connectivity: `ping otel-collector.tailscale`

## Metrics Not Appearing in Grafana Cloud

1. Check collector export logs for errors (auth failures, rate limits)
2. Verify Grafana Cloud credentials in collector config
3. Check free tier limits (10k active series)
4. Verify time range in Grafana dashboard (data may have retention lag)

## Netdata Not Exporting

1. Check Netdata logs: `docker logs netdata`
2. Verify exporting.conf has OTel collector URL
3. Check if Netdata can reach collector: `docker exec netdata curl http://otel-collector:4317`

## Sentry Not Receiving Errors

1. Verify SENTRY_DSN is set correctly
2. Check Sentry project settings for the correct platform
3. Trigger a test error and check Sentry dashboard
4. Check monthly error quota (5K on free tier)
```

**Step 5: Commit**

```bash
git add docs/runbooks/
git commit -m "Add observability onboarding runbooks for projects and nodes"
```

---

## Task 10: Update Infrastructure Roadmap with New Phases

Update the existing infrastructure roadmap document to reflect the new phases (0.5, 1.25, 2.5, 4 expansion, 5) and mark the observability open question as addressed.

**Files:**
- Modify: `docs/plans/infrastructure-roadmap.md` (add new phases to sequencing section)
- Modify: `docs/plans/RESEARCH.md` (update R11 Observability status)

**Step 1: Read current RESEARCH.md to find R11**

```bash
grep -n "R11\|[Oo]bservability" docs/plans/RESEARCH.md
```

**Step 2: Update RESEARCH.md**

Change R11 status from `open` to `resolved` and add a reference to the design doc:

> R11: Observability -- **resolved** via `2026-03-07-infrastructure-expansion-design.md`. OTel-centric pipeline with Grafana Cloud backends, Netdata on nodes, Sentry free tier for errors.

**Step 3: Add cross-reference in infrastructure-roadmap.md**

Add a note in the "Open Questions" section:

> **Monitoring / observability**: Resolved. See `2026-03-07-infrastructure-expansion-design.md` for the complete observability design (OTel Collector + Grafana Cloud + Netdata + Sentry).

**Step 4: Commit**

```bash
git add docs/plans/infrastructure-roadmap.md docs/plans/RESEARCH.md
git commit -m "Update roadmap and research docs to reference observability design"
```

---

## Task 11: Update CLAUDE.md with Ansible and Observability Info

Update the repo's CLAUDE.md to document the new Ansible directory and observability components so future agent sessions know about them.

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Add Ansible section to the Repository Structure table**

Add a row:

| `ansible/` | Ansible | Configuration management (roles for OTel, Netdata, Ghost, etc.) |

**Step 2: Add Ansible layout section**

```markdown
### Ansible layout

    ansible/
      ansible.cfg                # Ansible configuration
      site.yml                   # Main playbook
      inventory/hosts.yml        # Host inventory (update with Tailscale IPs)
      group_vars/all.yml         # Global variables
      roles/                     # Reusable roles (otel-collector, netdata, ghost, etc.)
      requirements.yml           # Galaxy collection requirements
```

**Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "Update CLAUDE.md with Ansible structure and observability context"
```

---

## Task 12: Bootstrap TFC Workspaces for New Resources

Update the global TFC workspace bootstrap to include workspaces for the new Grafana Cloud and Cloudflare Pages resources.

**Depends on:** Tasks 6 and 8

**Files:**
- Modify: `terraform/environments/global/tfc/workspaces/terragrunt.hcl` (or the main.tf it references)

**Step 1: Read current workspace bootstrap config**

```bash
cat terraform/environments/global/tfc/workspaces/main.tf
```

**Step 2: Add new workspaces**

Add workspace entries for:
- `prod-grafana-cloud-data-sources`
- `prod-cloudflare-pages-website`

Follow the existing pattern from the file.

**Step 3: Validate**

```bash
cd terraform/environments/global/tfc/workspaces
terraform validate
```

**Step 4: Commit**

```bash
git add terraform/environments/global/tfc/workspaces/
git commit -m "Add TFC workspaces for Grafana Cloud and Cloudflare Pages"
```

---

## Future Tasks (Phase 4 + 5 -- Not Yet Actionable)

These are documented here for reference but depend on infrastructure not yet deployed.

### Phase 4: Dark Matter Multi-Tenant Observability

- Create Terraform module for per-tenant OTel Collector provisioning
- Create Terraform module for per-tenant Grafana org/folder creation
- Create Ansible role for deploying OTel agents to client infrastructure
- Create client onboarding automation (Terraform + Ansible pipeline)
- Document client onboarding runbook

### Phase 5: Proxmox Migration

- Create Ansible roles for self-hosted Prometheus, Loki, Tempo, Grafana
- Create Proxmox VM provisioning Terraform module (or manual + Ansible)
- Write migration runbook: `docs/runbooks/proxmox-migration.md`
- OTel Collector config swap (Grafana Cloud export targets -> self-hosted)
- Grafana dashboard export/import procedure
- Service-by-service migration playbook (databases, Git, Jenkins)
