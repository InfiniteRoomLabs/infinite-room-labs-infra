# Code Review Feedback: Homelab Infrastructure Automation

  **Reviewed by**: Code Review Agent
  **Date**: 2026-03-19
  **Plan**: `ethereal-crafting-hearth.md`
  **Scope**: All new files in `ansible/` and expected Terraform additions

  ---

  ## Summary

  Comprehensive and well-structured scaffolding. Architecture decisions (flat playbooks, data-driven vars, containerized runner, phased execution) are sound. However, **6 bugs will cause runtime failures** and must be fixed before any
  Phase execution.

  ---

  ## Critical (Fix Before Running Any Phase)

  ### C1. Authentik is completely missing from the security compose template

  - **File**: `ansible/templates/compose/security/docker-compose.yml.j2`
  - **Playbook**: `ansible/playbooks/authentik.yml` (line 32)
  - **Problem**: The Authentik playbook says "Deploy updated security stack compose file (Vault + Authentik)" but the template only contains Vault. No Authentik server, worker, or Redis services exist anywhere. Running the Authentik
  playbook will just redeploy Vault with no changes.
  - **Fix**: Add Authentik services to the security compose template. Authentik requires:
    - `authentik-server` (image: `ghcr.io/goauthentik/server`)
    - `authentik-worker` (same image, different entrypoint)
    - `authentik-redis` (or reuse the shared Redis from the data stack via the `irl-backend` network)
    - Environment variables: `AUTHENTIK_SECRET_KEY`, `AUTHENTIK_POSTGRESQL__*`, `AUTHENTIK_REDIS__HOST`, `AUTHENTIK_BOOTSTRAP_PASSWORD`
    - Port mapping: `127.0.0.1:9000:9000` (matching `irl_services.authentik.port`)
    - Memory limits from `irl_mem_limits.authentik_server` and `irl_mem_limits.authentik_worker`
  - **Also needed**: Add `authentik_server` and `authentik_worker` entries to `irl_mem_limits` in `host_vars/homelab.yml` (currently missing).
  - **Also needed**: Add `vault_authentik_*` secrets aren't used by anything since Authentik doesn't exist in the compose template yet.

  ### C2. Gitea compose has broken cross-stack depends_on

  - **File**: `ansible/templates/compose/devplatform/docker-compose.yml.j2`, lines 29-49
  - **Problem**: The Gitea service has `depends_on: irl-postgres: condition: service_healthy`, referencing a dummy service with `profiles: [never-start]`. Docker Compose treats profiled services as non-existent unless their profile is
  activated. This will cause a compose error like `service "irl-postgres" is required by "gitea" but is not enabled`.
  - **Why it's wrong**: `depends_on` only works within a single compose file. You cannot depend on services in other compose stacks.
  - **Fix**: Remove the entire dummy `irl-postgres` service definition (lines 40-49). Remove the `depends_on` block from the `gitea` service (lines 29-31). The data stack runs first via Ansible playbook ordering. If you want runtime
  safety, add a health-check wait task in `gitea.yml` before `docker compose up`:
    ```yaml
    - name: Wait for PostgreSQL to be reachable
      ansible.builtin.wait_for:
        host: 127.0.0.1
        port: 5433
        timeout: 60

  C3. ZFS playbook: sanoid config deployed before directory exists

  - File: ansible/playbooks/zfs.yml, lines 56-71
  - Problem: "Deploy sanoid configuration" (line 56) copies to /etc/sanoid/sanoid.conf BEFORE "Ensure sanoid config directory exists" (line 65) creates /etc/sanoid/. On a fresh server, the copy task will fail with "No such file or
  directory".
  - Fix: Move lines 65-71 ("Ensure sanoid config directory exists") to BEFORE lines 56-63 ("Deploy sanoid configuration").

  C4. Docker prune cron will destroy named volumes

  - File: ansible/playbooks/docker.yml, line 51
  - Problem: The cron job runs docker system prune -af --volumes --filter 'until=168h'. The --volumes flag removes ALL unused volumes (named and anonymous). The --filter until=168h filter does NOT apply to volumes -- it only filters images
   and containers. If any compose stack is temporarily stopped (e.g., during a restart or maintenance), its data volumes will be permanently deleted.
  - Fix: Remove --volumes from the prune command:
  /usr/bin/docker system prune -af --filter 'until=168h' > /dev/null 2>&1

  ---
  Important (Fix Before Commit/Deploy)

  I1. Placeholder SSH pubkey will lock you out

  - File: ansible/inventory/group_vars/all/main.yml, line 88
  - Problem: irl_admin_ssh_pubkey contains PLACEHOLDER_REPLACE_WITH_ACTUAL_PUBKEY. If Phase 0 runs in order (users.yml writes this bad key, then security-hardening.yml disables root login and password auth), you will be locked out of the
  server.
  - Fix: Replace with the actual public key. Consider adding a pre-flight assertion in users.yml:
  - name: Validate SSH public key is not placeholder
    ansible.builtin.assert:
      that:
        - "'PLACEHOLDER' not in irl_admin_ssh_pubkey"
      fail_msg: "Replace irl_admin_ssh_pubkey in group_vars/all/main.yml before running"

  I2. vault.yml is unencrypted with plaintext placeholders

  - File: ansible/inventory/group_vars/all/vault.yml
  - Problem: Contains unencrypted CHANGEME_encrypt_this_file strings. If committed to git, these are in history forever. Even as placeholders, having an unencrypted vault file establishes a bad pattern.
  - Fix: Either encrypt it now (ansible-vault encrypt), or rename to vault.yml.example and add vault.yml to .gitignore.

  I3. Missing plan deliverables

  The following items are listed in the plan but were not created:

  ┌────────────────────────────────────────────────┬───────────────────────────────────────────────────────┐
  │                  Deliverable                   │                        Status                         │
  ├────────────────────────────────────────────────┼───────────────────────────────────────────────────────┤
  │ ansible/README.md                              │ Missing                                               │
  ├────────────────────────────────────────────────┼───────────────────────────────────────────────────────┤
  │ terraform/modules/cloudflare-dns-records/      │ Missing (entire module)                               │
  ├────────────────────────────────────────────────┼───────────────────────────────────────────────────────┤
  │ terraform/modules/tailscale-acl/               │ Missing (entire module)                               │
  ├────────────────────────────────────────────────┼───────────────────────────────────────────────────────┤
  │ terraform/environments/homelab/                │ Missing (env.hcl, provider.hcl, terragrunt.hcl files) │
  ├────────────────────────────────────────────────┼───────────────────────────────────────────────────────┤
  │ terraform/root.hcl Tailscale provider addition │ Not applied                                           │
  ├────────────────────────────────────────────────┼───────────────────────────────────────────────────────┤
  │ docs/plans/infrastructure-roadmap.md update    │ Not applied                                           │
  └────────────────────────────────────────────────┴───────────────────────────────────────────────────────┘

  I4. Ollama binds 0.0.0.0, not Tailscale-only

  - File: ansible/playbooks/ollama.yml, line 29
  - Problem: Plan says "bind Tailscale" but OLLAMA_HOST=0.0.0.0:11434 binds to all interfaces. While nftables blocks port 11434 from non-Tailscale sources, defense-in-depth says bind to localhost only.
  - Fix: Change to OLLAMA_HOST=127.0.0.1:11434. Agents access it via SSH tunnel or Tailscale direct connection to localhost.

  ---
  Notes (Not Blocking, Worth Knowing)

  - Vault healthcheck will report unhealthy when sealed (expected state after deploy). This is correct behavior but will show yellow in docker ps until manually unsealed. Consider using a script that treats exit code 2 (sealed) as
  healthy-but-sealed.
  - Jenkins initial password is output via ansible.builtin.debug, which means it appears in plain text in Ansible output. Use no_log: true or instruct the operator to retrieve it manually.
  - nftables + Docker iptables coexistence: Docker still manages its own iptables rules (daemon.json doesn't set "iptables": false). The nftables forward chain allows docker* interfaces which should coexist, but test carefully -- this is a
   known friction area.
  - Grafana dashboard JSON files use {{ name }}, {{ device }}, {{ mountpoint }} which are Grafana template variables. These are correctly deployed via ansible.builtin.copy (not template), so Jinja2 won't process them. Good.

  ---
  Fix Priority Order

  1. C3 (task ordering) -- 30-second fix, swap two task blocks
  2. C4 (docker prune) -- 30-second fix, remove --volumes
  3. C2 (gitea depends_on) -- 5 min, delete dummy service + depends_on
  4. C1 (Authentik missing) -- 30-60 min, write full Authentik compose services
  5. I1 (SSH key placeholder) -- add assertion, actual key is operator's responsibility
  6. I2 (vault.yml encryption) -- 1 min, rename to .example
  7. I3 (missing deliverables) -- separate work item, Terraform modules are Phase 2+
  8. I4 (Ollama bind) -- 1 min, change 0.0.0.0 to 127.0.0.1
