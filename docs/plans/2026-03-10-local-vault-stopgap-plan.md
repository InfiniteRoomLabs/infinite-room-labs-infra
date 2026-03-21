# Local Vault Stopgap Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Install HashiCorp Vault as a localhost systemd service on this laptop via a new Ansible role, and update all documentation so every human and AI agent knows about it.

**Architecture:** Ansible role installs the official Vault binary, configures Raft storage on localhost:8200 (no TLS), creates a systemd unit with auto-unseal, and initializes Vault on first run. This is the first Ansible role in the infra monorepo, so the entire `ansible/` directory is scaffolded here.

**Tech Stack:** Ansible (system install), HashiCorp Vault 1.21.4 (official binary), systemd, Raft storage.

---

### Task 1: Install Ansible

Ansible must be available on the system before anything else.

**Step 1: Check if Ansible is already installed**

Run: `which ansible && ansible --version`
If installed, skip to Task 2.

**Step 2: Install Ansible via system package manager**

```bash
sudo apt-get update && sudo apt-get install -y ansible
```

**Step 3: Verify installation**

Run: `ansible --version`
Expected: Version output with config file path.

---

### Task 2: Scaffold Ansible directory structure

Create the entire `ansible/` tree with all boilerplate files. No Vault-specific content yet -- just the skeleton that all future roles will follow.

**Files:**
- Create: `ansible/ansible.cfg`
- Create: `ansible/site.yml`
- Create: `ansible/requirements.yml`
- Create: `ansible/inventory/hosts.yml`
- Create: `ansible/inventory/group_vars/all.yml`
- Create: `ansible/inventory/group_vars/vault_servers.yml`
- Create: `ansible/CLAUDE.md`

**Step 1: Create `ansible/ansible.cfg`**

```ini
[defaults]
inventory = inventory/hosts.yml
roles_path = roles
host_key_checking = False
retry_files_enabled = False

[privilege_escalation]
become = True
become_method = sudo
```

**Step 2: Create `ansible/site.yml`**

```yaml
---
# Master playbook entrypoint.
# Use --tags to select which services to deploy.
#
# Examples:
#   ansible-playbook site.yml --tags vault
#   ansible-playbook site.yml --tags vault --check  (dry run)
#   ansible-playbook site.yml                        (deploy everything)

- name: Deploy Vault
  hosts: vault_servers
  tags: [vault]
  roles:
    - vault
```

**Step 3: Create `ansible/requirements.yml`**

```yaml
---
# Galaxy roles and collections required by this project.
# Install with: ansible-galaxy install -r requirements.yml
#
# Currently empty -- no external dependencies. Add entries as needed:
#
# roles:
#   - name: geerlingguy.docker
#     version: "7.4.1"
#
# collections:
#   - name: community.general
#     version: ">=9.0.0"

collections: []
```

**Step 4: Create `ansible/inventory/hosts.yml`**

```yaml
---
# Static inventory.
# localhost is the only host for now (Vault stopgap).
# When Hetzner CAX21 is provisioned, add it here.
#
# To run against localhost only:
#   ansible-playbook site.yml --tags vault
#
# To run against a remote host:
#   ansible-playbook site.yml --tags vault -l hetzner

all:
  children:
    vault_servers:
      hosts:
        localhost:
          ansible_connection: local
          ansible_python_interpreter: "{{ ansible_playbook_python }}"
```

**Step 5: Create `ansible/inventory/group_vars/all.yml`**

```yaml
---
# Variables shared across ALL hosts and roles.
#
# Keep this minimal. Role-specific variables belong in:
#   - group_vars/{group}.yml  (per host group)
#   - roles/{role}/defaults/main.yml  (role defaults, overridable)
```

**Step 6: Create `ansible/inventory/group_vars/vault_servers.yml`**

```yaml
---
# Variables for the vault_servers group.
# These override role defaults for all Vault hosts.
#
# For the local stopgap, we use all role defaults.
# Override here when deploying to Hetzner with TLS, different paths, etc.
#
# Example overrides for Hetzner:
#   vault_tls_disable: false
#   vault_tls_cert_file: /opt/vault/tls/tls.crt
#   vault_tls_key_file: /opt/vault/tls/tls.key
#   vault_listener_address: "0.0.0.0:8200"
```

**Step 7: Create `ansible/CLAUDE.md`**

```markdown
## Ansible Configuration Management

This directory contains Ansible playbooks and roles for post-provisioning application setup. Part of the IaC monorepo alongside `terraform/`.

### How to Run

```bash
cd ansible/

# Deploy a specific service:
ansible-playbook site.yml --tags vault

# Dry run (check mode):
ansible-playbook site.yml --tags vault --check

# Deploy everything:
ansible-playbook site.yml

# Limit to a specific host:
ansible-playbook site.yml --tags vault -l hetzner
```

### Directory Layout

```
ansible/
  ansible.cfg              # Project-level config (roles path, inventory, defaults)
  site.yml                 # Master playbook entrypoint (--tags selects services)
  requirements.yml         # Galaxy/collection dependencies
  inventory/
    hosts.yml              # Static inventory
    group_vars/
      all.yml              # Variables shared across all hosts
      {group}.yml          # Variables for a specific host group
  roles/
    {service}/
      defaults/main.yml    # All tunables with full documentation (THE variable interface)
      tasks/main.yml       # Task entrypoint (includes phase files)
      tasks/{phase}.yml    # Tasks split by phase (install, configure, init, etc.)
      handlers/main.yml    # Restart/reload handlers
      templates/           # Jinja2 templates for config files
      vars/main.yml        # Internal role vars (not user-facing)
      meta/main.yml        # Role metadata and dependencies
      README.md            # Role docs: purpose, variables, examples, usage
```

### Conventions

1. **`defaults/main.yml` is the variable interface.** Every tunable has a comment block explaining what it does, valid values, and why the default was chosen. This is the single source of truth for "what can I configure."
2. **`README.md` per role.** Documents purpose, requirements, all variables, example playbook, and post-install notes.
3. **`site.yml` with tags.** One entrypoint, `--tags {service}` selects the role. No per-service playbook files unless complexity demands it.
4. **No magic.** Explicit variable names, no implicit defaults hiding behavior. An AI agent or a new team member should be able to operate any role from its interface alone.
5. **Tasks split by phase.** `install.yml`, `configure.yml`, `init.yml` -- not one monolithic `main.yml`.
6. **Idempotent always.** Running a playbook twice produces no changes on the second run.

### Adding a New Role

1. Create `roles/{service}/` with the directory layout above
2. Add a play to `site.yml` with appropriate `hosts` and `tags`
3. Add group variables to `inventory/group_vars/{group}.yml` if needed
4. Write the role `README.md` before writing tasks
5. Test idempotency: run the playbook twice, second run should report 0 changed
```

**Step 8: Commit**

```bash
cd /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra
git add ansible/ansible.cfg ansible/site.yml ansible/requirements.yml \
        ansible/inventory/hosts.yml ansible/inventory/group_vars/all.yml \
        ansible/inventory/group_vars/vault_servers.yml ansible/CLAUDE.md
git commit -m "Scaffold ansible/ directory with conventions and inventory"
```

---

### Task 3: Write Vault role -- defaults and metadata

Set up the role's variable interface and metadata. This defines the contract before any tasks exist.

**Files:**
- Create: `ansible/roles/vault/defaults/main.yml`
- Create: `ansible/roles/vault/vars/main.yml`
- Create: `ansible/roles/vault/meta/main.yml`

**Step 1: Create `ansible/roles/vault/defaults/main.yml`**

```yaml
---
# ============================================================================
# HashiCorp Vault Role - Default Variables
# ============================================================================
#
# This file is the SINGLE SOURCE OF TRUTH for what you can configure.
# Every variable has a comment explaining what it does, valid values, and
# why the default was chosen.
#
# Override these in:
#   - inventory/group_vars/vault_servers.yml  (per-group)
#   - inventory/host_vars/{host}.yml          (per-host)
#   - command line: -e vault_version=1.22.0
#
# ============================================================================

# ----------------------------------------------------------------------------
# Installation
# ----------------------------------------------------------------------------

# Vault version to install.
# Check https://releases.hashicorp.com/vault/ for available versions.
vault_version: "1.21.4"

# CPU architecture for the download. Matches `dpkg --print-architecture` output.
# Valid values: amd64, arm64
vault_arch: "amd64"

# Where to install the Vault binary.
vault_bin_path: "/usr/bin/vault"

# ----------------------------------------------------------------------------
# System User
# ----------------------------------------------------------------------------

# System user and group that Vault runs as.
# Created automatically if they don't exist.
vault_user: "vault"
vault_group: "vault"

# ----------------------------------------------------------------------------
# Paths
# ----------------------------------------------------------------------------

# Directory for Vault configuration files.
vault_config_dir: "/etc/vault.d"

# Directory for Raft storage data.
# Must be owned by vault_user with mode 0700.
vault_data_dir: "/opt/vault/data"

# Directory for Vault helper scripts (unseal, etc.).
vault_bin_dir: "/opt/vault/bin"

# ----------------------------------------------------------------------------
# Listener
# ----------------------------------------------------------------------------

# Address and port for the TCP listener.
# Default binds to localhost only (no network exposure).
# For production with TLS, set to "0.0.0.0:8200".
vault_listener_address: "127.0.0.1:8200"

# Disable TLS on the listener.
# Only safe when binding to 127.0.0.1 (localhost).
# Set to false and provide cert/key paths for production.
vault_tls_disable: true

# TLS certificate and key paths (only used when vault_tls_disable is false).
# vault_tls_cert_file: "/opt/vault/tls/tls.crt"
# vault_tls_key_file: "/opt/vault/tls/tls.key"

# ----------------------------------------------------------------------------
# Storage
# ----------------------------------------------------------------------------

# Raft node ID. Must be unique per node in a cluster.
vault_raft_node_id: "local-1"

# ----------------------------------------------------------------------------
# API & Cluster Addresses
# ----------------------------------------------------------------------------

# Address for Vault API. Used by CLI and other clients.
vault_api_addr: "http://127.0.0.1:8200"

# Address for Raft cluster communication.
vault_cluster_addr: "http://127.0.0.1:8201"

# ----------------------------------------------------------------------------
# Security
# ----------------------------------------------------------------------------

# Disable mlock (memory locking).
# Setting to true avoids needing IPC_LOCK capability.
# Acceptable on a single-user laptop. Set to false in production.
vault_disable_mlock: true

# Enable the Vault web UI.
vault_ui: true

# ----------------------------------------------------------------------------
# Initialization
# ----------------------------------------------------------------------------

# Number of unseal key shares to generate during vault operator init.
# For single-operator stopgap: 1. For production: 5 (with threshold 3).
vault_key_shares: 1

# Number of key shares required to unseal.
# For single-operator stopgap: 1. For production: 3 (of 5).
vault_key_threshold: 1

# Where to store the init output (root token + unseal keys).
# This file is root-only readable (mode 0600).
vault_init_keys_file: "/root/.vault-init-keys"

# ----------------------------------------------------------------------------
# Auto-Unseal
# ----------------------------------------------------------------------------

# Enable auto-unseal via script on service start.
# When true, a script reads the unseal key from vault_init_keys_file
# and unseals Vault automatically after systemd starts the service.
# Only appropriate when vault_key_shares == 1 and vault_key_threshold == 1.
vault_auto_unseal: true
```

**Step 2: Create `ansible/roles/vault/vars/main.yml`**

```yaml
---
# Internal variables -- not intended for user override.
# These are derived or constant values used by the role's tasks.

vault_download_url: "https://releases.hashicorp.com/vault/{{ vault_version }}/vault_{{ vault_version }}_linux_{{ vault_arch }}.zip"
vault_checksum_url: "https://releases.hashicorp.com/vault/{{ vault_version }}/vault_{{ vault_version }}_SHA256SUMS"
vault_config_file: "{{ vault_config_dir }}/vault.hcl"
vault_env_file: "{{ vault_config_dir }}/vault.env"
vault_systemd_unit: "/etc/systemd/system/vault.service"
vault_unseal_script: "{{ vault_bin_dir }}/vault-unseal.sh"
vault_profile_script: "/etc/profile.d/vault.sh"
```

**Step 3: Create `ansible/roles/vault/meta/main.yml`**

```yaml
---
galaxy_info:
  role_name: vault
  author: Infinite Room Labs
  description: Install and configure HashiCorp Vault with Raft storage and auto-unseal.
  license: proprietary
  min_ansible_version: "2.14"
  platforms:
    - name: Ubuntu
      versions:
        - noble
  galaxy_tags:
    - vault
    - hashicorp
    - secrets
    - security

dependencies: []
```

**Step 4: Commit**

```bash
cd /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra
git add ansible/roles/vault/defaults/main.yml \
        ansible/roles/vault/vars/main.yml \
        ansible/roles/vault/meta/main.yml
git commit -m "Add vault role defaults, vars, and metadata"
```

---

### Task 4: Write Vault role -- templates

Create all Jinja2 templates that the tasks will deploy.

**Files:**
- Create: `ansible/roles/vault/templates/vault.hcl.j2`
- Create: `ansible/roles/vault/templates/vault.service.j2`
- Create: `ansible/roles/vault/templates/vault-unseal.sh.j2`

**Step 1: Create `ansible/roles/vault/templates/vault.hcl.j2`**

```hcl
# {{ ansible_managed }}
# HashiCorp Vault configuration.
# See: https://developer.hashicorp.com/vault/docs/configuration

ui = {{ vault_ui | lower }}

listener "tcp" {
  address     = "{{ vault_listener_address }}"
  tls_disable = {{ vault_tls_disable | lower }}
{% if not vault_tls_disable %}
  tls_cert_file = "{{ vault_tls_cert_file }}"
  tls_key_file  = "{{ vault_tls_key_file }}"
{% endif %}
}

storage "raft" {
  path    = "{{ vault_data_dir }}"
  node_id = "{{ vault_raft_node_id }}"
}

api_addr     = "{{ vault_api_addr }}"
cluster_addr = "{{ vault_cluster_addr }}"

disable_mlock = {{ vault_disable_mlock | lower }}
```

**Step 2: Create `ansible/roles/vault/templates/vault.service.j2`**

```ini
# {{ ansible_managed }}
# HashiCorp Vault systemd service unit.
# See: https://developer.hashicorp.com/vault/docs/configuration#systemd

[Unit]
Description=HashiCorp Vault - A tool for managing secrets
Documentation=https://developer.hashicorp.com/vault/docs
Requires=network-online.target
After=network-online.target
ConditionFileNotEmpty={{ vault_config_file }}
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=notify
User={{ vault_user }}
Group={{ vault_group }}
EnvironmentFile={{ vault_env_file }}
ExecStart={{ vault_bin_path }} server -config={{ vault_config_dir }}
ExecReload=/bin/kill --signal HUP $MAINPID
{% if vault_auto_unseal %}
ExecStartPost={{ vault_unseal_script }}
{% endif %}
KillMode=process
KillSignal=SIGINT
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
LimitNOFILE=65536
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
```

**Step 3: Create `ansible/roles/vault/templates/vault-unseal.sh.j2`**

```bash
#!/usr/bin/env bash
# {{ ansible_managed }}
# Auto-unseal script for HashiCorp Vault.
# Called by systemd ExecStartPost after Vault starts.
#
# Reads the unseal key from {{ vault_init_keys_file }} and unseals Vault.
# Only works when vault was initialized with key_shares=1, key_threshold=1.

set -euo pipefail

VAULT_ADDR="{{ vault_api_addr }}"
export VAULT_ADDR

INIT_KEYS_FILE="{{ vault_init_keys_file }}"

# Wait for Vault to be responsive (up to 30 seconds).
for i in $(seq 1 30); do
    if {{ vault_bin_path }} status -format=json 2>/dev/null | grep -q '"initialized"'; then
        break
    fi
    sleep 1
done

# If Vault is not yet initialized, exit silently.
# Initialization is handled by the Ansible init task on first run.
if ! {{ vault_bin_path }} status -format=json 2>/dev/null | grep -q '"initialized": true'; then
    exit 0
fi

# If already unsealed, nothing to do.
if {{ vault_bin_path }} status -format=json 2>/dev/null | grep -q '"sealed": false'; then
    exit 0
fi

# Read unseal key and unseal.
if [ -f "$INIT_KEYS_FILE" ]; then
    UNSEAL_KEY=$(grep 'Unseal Key' "$INIT_KEYS_FILE" | awk '{print $NF}')
    {{ vault_bin_path }} operator unseal "$UNSEAL_KEY" > /dev/null
fi
```

**Step 4: Commit**

```bash
cd /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra
git add ansible/roles/vault/templates/vault.hcl.j2 \
        ansible/roles/vault/templates/vault.service.j2 \
        ansible/roles/vault/templates/vault-unseal.sh.j2
git commit -m "Add vault role templates for config, systemd, and unseal"
```

---

### Task 5: Write Vault role -- tasks and handlers

The core automation: install, configure, initialize, unseal.

**Files:**
- Create: `ansible/roles/vault/tasks/main.yml`
- Create: `ansible/roles/vault/tasks/install.yml`
- Create: `ansible/roles/vault/tasks/configure.yml`
- Create: `ansible/roles/vault/tasks/init.yml`
- Create: `ansible/roles/vault/tasks/unseal.yml`
- Create: `ansible/roles/vault/handlers/main.yml`

**Step 1: Create `ansible/roles/vault/handlers/main.yml`**

```yaml
---
- name: Reload systemd
  ansible.builtin.systemd:
    daemon_reload: true

- name: Restart vault
  ansible.builtin.systemd:
    name: vault
    state: restarted
```

**Step 2: Create `ansible/roles/vault/tasks/main.yml`**

```yaml
---
# Vault role entrypoint.
# Tasks are split by phase for readability.

- name: Install Vault
  ansible.builtin.include_tasks: install.yml

- name: Configure Vault
  ansible.builtin.include_tasks: configure.yml

- name: Initialize Vault
  ansible.builtin.include_tasks: init.yml

- name: Unseal Vault
  ansible.builtin.include_tasks: unseal.yml
```

**Step 3: Create `ansible/roles/vault/tasks/install.yml`**

```yaml
---
- name: Install unzip (required to extract Vault archive)
  ansible.builtin.apt:
    name: unzip
    state: present
    update_cache: true
    cache_valid_time: 3600

- name: Create vault group
  ansible.builtin.group:
    name: "{{ vault_group }}"
    system: true
    state: present

- name: Create vault user
  ansible.builtin.user:
    name: "{{ vault_user }}"
    group: "{{ vault_group }}"
    system: true
    shell: /usr/sbin/nologin
    home: "{{ vault_data_dir }}"
    create_home: false
    state: present

- name: Check current vault version
  ansible.builtin.command: "{{ vault_bin_path }} version"
  register: vault_current_version
  changed_when: false
  failed_when: false

- name: Download Vault {{ vault_version }}
  ansible.builtin.get_url:
    url: "{{ vault_download_url }}"
    dest: "/tmp/vault_{{ vault_version }}.zip"
    checksum: "sha256:{{ vault_checksum_url }}"
    mode: "0644"
  when: vault_current_version.rc != 0 or vault_version not in vault_current_version.stdout

- name: Extract Vault binary
  ansible.builtin.unarchive:
    src: "/tmp/vault_{{ vault_version }}.zip"
    dest: "{{ vault_bin_path | dirname }}"
    remote_src: true
    creates: "{{ vault_bin_path }}"
  when: vault_current_version.rc != 0 or vault_version not in vault_current_version.stdout
  notify:
    - Restart vault

- name: Set vault binary permissions
  ansible.builtin.file:
    path: "{{ vault_bin_path }}"
    owner: root
    group: root
    mode: "0755"

- name: Set vault binary cap_ipc_lock (if mlock enabled)
  community.general.capabilities:
    path: "{{ vault_bin_path }}"
    capability: cap_ipc_lock=+ep
    state: present
  when: not vault_disable_mlock

- name: Clean up download archive
  ansible.builtin.file:
    path: "/tmp/vault_{{ vault_version }}.zip"
    state: absent
```

**Step 4: Create `ansible/roles/vault/tasks/configure.yml`**

```yaml
---
- name: Create Vault config directory
  ansible.builtin.file:
    path: "{{ vault_config_dir }}"
    state: directory
    owner: "{{ vault_user }}"
    group: "{{ vault_group }}"
    mode: "0750"

- name: Create Vault data directory
  ansible.builtin.file:
    path: "{{ vault_data_dir }}"
    state: directory
    owner: "{{ vault_user }}"
    group: "{{ vault_group }}"
    mode: "0700"

- name: Create Vault bin directory
  ansible.builtin.file:
    path: "{{ vault_bin_dir }}"
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Deploy Vault configuration
  ansible.builtin.template:
    src: vault.hcl.j2
    dest: "{{ vault_config_file }}"
    owner: "{{ vault_user }}"
    group: "{{ vault_group }}"
    mode: "0640"
  notify:
    - Restart vault

- name: Deploy Vault environment file
  ansible.builtin.copy:
    content: |
      # {{ ansible_managed }}
      VAULT_ADDR={{ vault_api_addr }}
    dest: "{{ vault_env_file }}"
    owner: "{{ vault_user }}"
    group: "{{ vault_group }}"
    mode: "0640"

- name: Deploy shell profile for VAULT_ADDR
  ansible.builtin.copy:
    content: |
      # {{ ansible_managed }}
      # Makes VAULT_ADDR available in all shell sessions.
      export VAULT_ADDR="{{ vault_api_addr }}"
    dest: "{{ vault_profile_script }}"
    owner: root
    group: root
    mode: "0644"

- name: Deploy auto-unseal script
  ansible.builtin.template:
    src: vault-unseal.sh.j2
    dest: "{{ vault_unseal_script }}"
    owner: root
    group: root
    mode: "0700"
  when: vault_auto_unseal

- name: Deploy systemd unit
  ansible.builtin.template:
    src: vault.service.j2
    dest: "{{ vault_systemd_unit }}"
    owner: root
    group: root
    mode: "0644"
  notify:
    - Reload systemd
    - Restart vault

- name: Enable and start Vault service
  ansible.builtin.systemd:
    name: vault
    enabled: true
    state: started
    daemon_reload: true
```

**Step 5: Create `ansible/roles/vault/tasks/init.yml`**

```yaml
---
# Initialize Vault on first run only.
# This creates the unseal keys and root token.
# Subsequent runs skip this entirely.

- name: Check if Vault is initialized
  ansible.builtin.command: "{{ vault_bin_path }} status -format=json"
  environment:
    VAULT_ADDR: "{{ vault_api_addr }}"
  register: vault_status
  changed_when: false
  failed_when: false

- name: Set initialization status fact
  ansible.builtin.set_fact:
    vault_initialized: "{{ (vault_status.stdout | from_json).initialized | default(false) }}"
  when: vault_status.rc == 0 or vault_status.rc == 2

- name: Initialize Vault
  ansible.builtin.command: >
    {{ vault_bin_path }} operator init
    -key-shares={{ vault_key_shares }}
    -key-threshold={{ vault_key_threshold }}
    -format=json
  environment:
    VAULT_ADDR: "{{ vault_api_addr }}"
  register: vault_init_output
  changed_when: true
  when: vault_initialized is defined and not vault_initialized

- name: Save init keys to file
  ansible.builtin.copy:
    content: |
      # Vault initialization output -- generated {{ ansible_date_time.iso8601 }}
      # This file is root-only readable. DO NOT share or commit.
      #
      # Unseal Key 1: {{ (vault_init_output.stdout | from_json).unseal_keys_b64[0] }}
      # Root Token: {{ (vault_init_output.stdout | from_json).root_token }}
      #
      Unseal Key: {{ (vault_init_output.stdout | from_json).unseal_keys_b64[0] }}
      Root Token: {{ (vault_init_output.stdout | from_json).root_token }}
    dest: "{{ vault_init_keys_file }}"
    owner: root
    group: root
    mode: "0600"
  when: vault_init_output is changed
  no_log: true
```

**Step 6: Create `ansible/roles/vault/tasks/unseal.yml`**

```yaml
---
# Unseal Vault after initialization or restart.
# Skips if already unsealed.

- name: Check Vault seal status
  ansible.builtin.command: "{{ vault_bin_path }} status -format=json"
  environment:
    VAULT_ADDR: "{{ vault_api_addr }}"
  register: vault_seal_status
  changed_when: false
  failed_when: false

- name: Run auto-unseal script
  ansible.builtin.command: "{{ vault_unseal_script }}"
  environment:
    VAULT_ADDR: "{{ vault_api_addr }}"
  changed_when: true
  when:
    - vault_auto_unseal
    - vault_seal_status.rc == 2
    - (vault_seal_status.stdout | from_json).sealed | default(true)
```

**Step 7: Commit**

```bash
cd /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra
git add ansible/roles/vault/tasks/ ansible/roles/vault/handlers/
git commit -m "Add vault role tasks and handlers"
```

---

### Task 6: Write Vault role README

The role documentation that makes it self-describing for humans and agents.

**Files:**
- Create: `ansible/roles/vault/README.md`

**Step 1: Create `ansible/roles/vault/README.md`**

```markdown
# Vault Role

Install and configure [HashiCorp Vault](https://developer.hashicorp.com/vault) with integrated Raft storage and optional auto-unseal.

## What This Role Does

1. **Installs** the official Vault binary from HashiCorp releases
2. **Creates** a dedicated `vault` system user and group
3. **Deploys** configuration (`vault.hcl`), systemd unit, and environment file
4. **Initializes** Vault on first run (generates unseal key + root token)
5. **Auto-unseals** Vault after every start (when enabled)
6. **Sets** `VAULT_ADDR` system-wide via `/etc/profile.d/vault.sh`

## Requirements

- Ubuntu 24.04+ (tested on Noble)
- Ansible 2.14+
- Root/sudo access on target host
- Internet access (to download Vault binary)

## Variables

All variables are defined in `defaults/main.yml` with full documentation. Key variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `vault_version` | `1.21.4` | Vault version to install |
| `vault_arch` | `amd64` | CPU architecture (`amd64`, `arm64`) |
| `vault_listener_address` | `127.0.0.1:8200` | Listener bind address |
| `vault_tls_disable` | `true` | Disable TLS (only safe on localhost) |
| `vault_data_dir` | `/opt/vault/data` | Raft storage directory |
| `vault_disable_mlock` | `true` | Disable memory locking |
| `vault_ui` | `true` | Enable web UI |
| `vault_key_shares` | `1` | Unseal key shares |
| `vault_key_threshold` | `1` | Unseal key threshold |
| `vault_auto_unseal` | `true` | Auto-unseal on service start |

See `defaults/main.yml` for the complete list with detailed comments.

## Example Playbook

```yaml
- hosts: vault_servers
  roles:
    - vault
```

Or with overrides for production:

```yaml
- hosts: vault_servers
  roles:
    - role: vault
      vars:
        vault_tls_disable: false
        vault_tls_cert_file: /opt/vault/tls/tls.crt
        vault_tls_key_file: /opt/vault/tls/tls.key
        vault_listener_address: "0.0.0.0:8200"
        vault_api_addr: "https://vault.internal:8200"
        vault_cluster_addr: "https://vault.internal:8201"
        vault_disable_mlock: false
        vault_key_shares: 5
        vault_key_threshold: 3
        vault_auto_unseal: false
```

## Post-Install

After running the playbook:

- **Root token and unseal key** are saved to `/root/.vault-init-keys` (root-only readable)
- **Vault UI** is available at http://127.0.0.1:8200/ui (when listening on localhost)
- **CLI** works immediately: `vault status`, `vault kv put secret/foo bar=baz`
- **VAULT_ADDR** is set system-wide -- new shell sessions pick it up automatically

### First-Time Usage

```bash
# Source the environment (or open a new shell)
source /etc/profile.d/vault.sh

# Check status
vault status

# Log in with root token (read from init keys file)
sudo cat /root/.vault-init-keys  # note the Root Token
vault login <root-token>

# Enable KV v2 secrets engine
vault secrets enable -version=2 kv

# Store a secret
vault kv put kv/test foo=bar

# Read it back
vault kv get kv/test
```

## File Locations

| Path | Purpose |
|------|---------|
| `/usr/bin/vault` | Vault binary |
| `/etc/vault.d/vault.hcl` | Main configuration |
| `/etc/vault.d/vault.env` | Environment variables for systemd |
| `/opt/vault/data/` | Raft storage data |
| `/opt/vault/bin/vault-unseal.sh` | Auto-unseal script |
| `/root/.vault-init-keys` | Unseal key + root token (root-only) |
| `/etc/profile.d/vault.sh` | Shell environment (VAULT_ADDR) |
```

**Step 2: Commit**

```bash
cd /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra
git add ansible/roles/vault/README.md
git commit -m "Add vault role README with full documentation"
```

---

### Task 7: Run the Ansible playbook to install Vault

Actually deploy Vault on the local machine.

**Step 1: Run the playbook**

```bash
cd /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra/ansible
ansible-playbook site.yml --tags vault -v
```

Expected: All tasks succeed. Vault is installed, configured, initialized, and unsealed.

**Step 2: Verify Vault is running**

```bash
source /etc/profile.d/vault.sh
vault status
```

Expected output includes:
- `Initialized: true`
- `Sealed: false`
- `Storage Type: raft`

**Step 3: Verify systemd service**

```bash
systemctl status vault
```

Expected: `active (running)`, `enabled`

**Step 4: Verify idempotency -- run playbook again**

```bash
cd /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra/ansible
ansible-playbook site.yml --tags vault -v
```

Expected: 0 changed tasks on second run (except possibly the seal-status check).

**Step 5: Test round-trip**

```bash
# Read the root token
sudo grep 'Root Token' /root/.vault-init-keys | awk '{print $NF}'

# Log in (paste the token when prompted)
vault login <root-token>

# Enable KV v2
vault secrets enable -version=2 kv

# Write and read a test secret
vault kv put kv/test message="vault is working"
vault kv get kv/test
```

Expected: Secret round-trips successfully.

---

### Task 8: Update infra repo documentation

Update CLAUDE.md and README.md in the infra repo to reflect the new Ansible directory and Vault.

**Files:**
- Modify: `/home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra/CLAUDE.md`
- Modify: `/home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra/README.md`
- Modify: `/home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra/docs/plans/infrastructure-roadmap.md`

**Step 1: Update `CLAUDE.md` -- add Ansible to repo structure table**

Add a row to the repository structure table:

```
| `ansible/` | Ansible | Post-provisioning configuration management (Vault, future services) |
```

Add after the Terraform layout section:

```markdown
### Ansible layout

```
ansible/
  ansible.cfg              # Project-level config (roles path, inventory)
  site.yml                 # Master playbook entrypoint (--tags selects services)
  inventory/hosts.yml      # Static inventory
  inventory/group_vars/    # Per-group variable overrides
  roles/{service}/         # One role per service (vault, tailscale, etc.)
```

- **Roles** follow a strict convention: `defaults/main.yml` is the variable interface, `README.md` documents every variable, tasks are split by phase.
- **Run playbooks** from the `ansible/` directory: `ansible-playbook site.yml --tags vault`
- See `ansible/CLAUDE.md` for full conventions.
```

Add a Vault section:

```markdown
## Vault

HashiCorp Vault is installed locally as a systemd service (stopgap until Hetzner deployment).

- **Address**: `http://127.0.0.1:8200` (set system-wide via `/etc/profile.d/vault.sh`)
- **Status**: `vault status`
- **UI**: http://127.0.0.1:8200/ui
- **Init keys**: `/root/.vault-init-keys` (root-only, contains unseal key + root token)
- **Ansible role**: `ansible/roles/vault/`
```

**Step 2: Update `README.md` -- add Ansible section**

Add after the Terraform section, before Troubleshooting:

```markdown
## Ansible

Configuration management for service deployment. Lives under `ansible/`.

### Prerequisites

- [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/) >= 2.14

### What it manages

**Vault** (HashiCorp Vault): Secrets management service. Currently deployed locally as a stopgap; will move to Hetzner CAX21.

### Running playbooks

```bash
cd ansible/

# Deploy Vault:
ansible-playbook site.yml --tags vault

# Dry run:
ansible-playbook site.yml --tags vault --check

# Deploy everything:
ansible-playbook site.yml
```

### Structure

See `ansible/CLAUDE.md` for full conventions on role structure, variable documentation, and adding new roles.
```

**Step 3: Update `infrastructure-roadmap.md` -- note local stopgap**

In the Phase 1 section under Vault, add a note:

```markdown
> **Status (2026-03-10):** Vault deployed locally on dev laptop as a stopgap.
> Ansible role at `ansible/roles/vault/`. Will redeploy to Hetzner CAX21 when provisioned.
> Localhost-only (127.0.0.1:8200), no TLS, auto-unseal with single key.
```

**Step 4: Commit**

```bash
cd /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra
git add CLAUDE.md README.md docs/plans/infrastructure-roadmap.md
git commit -m "Update infra docs with Ansible conventions and Vault stopgap"
```

---

### Task 9: Update home directory and global Claude docs

Make every Claude session aware of Vault.

**Files:**
- Modify: `/home/deathnerd/CLAUDE.md`
- Modify: `/home/deathnerd/.claude/CLAUDE.md`
- Modify: `/home/deathnerd/.claude/projects/-home-deathnerd-projects-infinite-room-labs/memory/MEMORY.md`

**Step 1: Update `~/CLAUDE.md` -- add Vault to Key Paths and services**

Add to the Key Paths section:

```markdown
- `/usr/bin/vault` -- HashiCorp Vault binary
- `/etc/vault.d/` -- Vault configuration
- `/opt/vault/data/` -- Vault Raft storage
```

Add a new section:

```markdown
## Services

- **HashiCorp Vault** -- secrets management, running as a systemd service on localhost
  - `VAULT_ADDR=http://127.0.0.1:8200` (set system-wide)
  - Status: `vault status`
  - UI: http://127.0.0.1:8200/ui
  - Init keys: `/root/.vault-init-keys` (root-only)
  - This is a local stopgap; production deployment will be on Hetzner CAX21
```

**Step 2: Update `~/.claude/CLAUDE.md` -- add Vault to environment**

Add a new section after PHP / Web Dev:

```markdown
# Services

- **HashiCorp Vault** running locally (`VAULT_ADDR=http://127.0.0.1:8200`)
- Use `vault status` to check, `vault kv` for secrets operations
- Init keys at `/root/.vault-init-keys` (needs sudo to read)
```

**Step 3: Update memory `MEMORY.md`**

Add under Project Knowledge:

```markdown
- **Vault**: HashiCorp Vault installed locally as systemd service (stopgap). Ansible role at `infinite-room-labs-infra/ansible/roles/vault/`. VAULT_ADDR=http://127.0.0.1:8200. Init keys at /root/.vault-init-keys.
- **Ansible**: First role (vault) scaffolded in infra repo. Conventions documented in `ansible/CLAUDE.md`. Flat roles layout, site.yml with --tags, self-documenting defaults/main.yml.
```

**Step 4: Commit (home directory files are not in a git repo, so no commit needed)**

These files are outside the infra repo. No git commit for these.

---

### Task 10: Update ideas repo

Update the ideas and strategic docs to reflect Vault deployment.

**Files:**
- Modify: `/home/deathnerd/projects/infinite-room-labs/ideas/ideas/005-secrets-iam-framework.md`
- Modify: `/home/deathnerd/projects/infinite-room-labs/ideas/strategic-roadmap.md`

**Step 1: Update idea 005 -- add note about Vault deployment**

Add after the Open Questions section:

```markdown
## Current Status

As of 2026-03-10, HashiCorp Vault is deployed locally as a stopgap secrets management solution (see `infinite-room-labs-infra/ansible/roles/vault/`). Combined with CCSM (in-progress), this covers the immediate secrets management needs. This idea should only be revisited if CCSM + Vault prove insufficient for the company's requirements.
```

**Step 2: Update strategic roadmap -- update Infra status**

In the Layer 0 Foundation table, update the Infrastructure Roadmap row:

Change:
```
| **Infrastructure Roadmap** | approved | Tailscale + Vault + GitLab/Gitea + Jenkins + SSO + databases on Oracle ARM free tier |
```

To:
```
| **Infrastructure Roadmap** | in-progress | Tailscale + Vault + GitLab/Gitea + Jenkins + SSO + databases. Vault deployed locally (stopgap); Hetzner CAX21 selected as primary compute |
```

**Step 3: Commit**

```bash
cd /home/deathnerd/projects/infinite-room-labs/ideas
git add ideas/005-secrets-iam-framework.md strategic-roadmap.md
git commit -m "Update ideas and roadmap to reflect local Vault deployment"
```

---

### Task 11: Final verification

Run all success criteria from the design doc.

**Step 1: Verify Vault status after fresh service restart**

```bash
sudo systemctl restart vault
sleep 5
vault status
```

Expected: `Sealed: false` (auto-unseal worked)

**Step 2: Verify KV round-trip**

```bash
vault kv put kv/test foo=bar
vault kv get kv/test
```

Expected: Returns `foo=bar`

**Step 3: Verify systemd**

```bash
systemctl is-enabled vault
systemctl is-active vault
```

Expected: Both return `enabled` / `active`

**Step 4: Verify idempotency**

```bash
cd /home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra/ansible
ansible-playbook site.yml --tags vault -v 2>&1 | tail -5
```

Expected: `changed=0` in the play recap

**Step 5: Spot-check CLAUDE.md files**

Read each updated CLAUDE.md and verify Vault is mentioned:
- `/home/deathnerd/projects/infinite-room-labs/infinite-room-labs-infra/CLAUDE.md`
- `/home/deathnerd/CLAUDE.md`
- `/home/deathnerd/.claude/CLAUDE.md`
- `/home/deathnerd/.claude/projects/-home-deathnerd-projects-infinite-room-labs/memory/MEMORY.md`
