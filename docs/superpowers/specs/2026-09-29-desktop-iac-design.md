# Desktop IaC Layer -- Design

**Date**: 2026-09-29
**Status**: Proposed (draft PR, nothing applied)
**Scope**: How this repo manages the Windows 10 desktop workstation, and the first thing it manages there (the OpenMessage client cutover)

## Context

The house rule is that every change to any machine we own -- homelab, laptop, desktop, tailnet, DNS -- is infrastructure-as-code in this repo, lands by PR, and is applied with the repo's own tools. Today that rule has two implementations:

- **Homelab**: `ansible/` playbooks run against `100.86.213.22` over SSH, orchestrated by `site.yml`. The control node is the agent-box container.
- **Laptop**: `ansible/playbooks/laptop.yml`, `hosts: laptop`, `connection: local`, `become: false`. Deliberately excluded from `site.yml` -- the homelab orchestrator must never reach into a personal machine. You run it on the laptop, for the laptop.

The Windows desktop has neither. Everything on it was done by hand from a PowerShell prompt, and the only record is a runbook in a different repo (`Deathnerd/openmessage`, `docs/windows-runbook.md`). That was tolerable while the desktop only ran one thing. It stops being tolerable now: OpenMessage moved into k3s (PR #17), so the desktop needs a coordinated, reversible, multi-step change -- swap the MCP transport, retire a Windows service, and hand its data to the cluster -- with the one-pod rule hanging over every step. That is exactly the class of change that should not be a sequence of remembered commands.

So this spec answers one question: **what is the engine that converges the Windows desktop, and where does it live in this repo?** OpenMessage is its first managed item, and the design is judged by whether it makes that first item boring.

### What we know about the desktop

| Fact | Value |
|---|---|
| OS | Windows 10 Pro 22H2, x64 |
| Shells | PowerShell 7 (`pwsh`) and Windows PowerShell 5.1; Git for Windows (Git Bash) |
| Containers | Docker Desktop (the agent-box runs here) |
| CLI binaries | `C:\tools`, already on the machine `PATH` |
| Remote admin | **Unknown** whether OpenSSH Server or WinRM is enabled. Assume neither. |
| Role | Personal workstation, not a server. Admin elevation available interactively. |

That last row is the one that drives the decision. It is a machine someone sits at, sleeps, moves between networks, and browses the web on -- not a rack unit with a fixed address and an uptime target.

## Options considered

### A. Ansible from the agent-box over SSH (`ansible.windows` + OpenSSH Server)

Install and enable the Windows OpenSSH Server feature, set `ansible_shell_type: powershell`, add the desktop to `inventory/hosts.ini`, write a `desktop.yml` playbook using `ansible.windows.win_service`, `win_acl`, `win_get_url`, `win_copy`.

- **For**: one engine for the whole estate; check mode and idempotency come from Ansible, not from us; the Windows modules are mature and well-documented; a second Windows machine would cost nothing to add.
- **Against**: it requires **a permanently listening remote-administration service on a personal workstation**. That is the single largest new attack surface in any option here, and it is paid continuously to support a converge that runs a few times a year. Worse, the control node (the agent-box) runs *on the desktop itself* under Docker Desktop, so we would be enabling inbound sshd on the host purely so a container on that host can loop back into it. Paying a standing network-exposure cost for a loopback is a bad trade.
- **Also against**: Windows Ansible needs a connection account. A personal machine's interactive account is the only one that exists; service-account provisioning on a workstation is its own project.

### B. Ansible over WinRM

Same shape as A, with `ansible_connection: winrm`.

- **For**: no new component to install; WinRM ships with Windows.
- **Against**: strictly worse than A on every axis we care about. Still a listener (5985/5986), with a harder TLS story (self-signed cert plumbing or unencrypted HTTP with NTLM), and Microsoft's own direction of travel is SSH. The Ansible docs now lead with SSH for Windows. Choosing the deprecated remoting stack to avoid installing the recommended one is not a saving.

### C. WSL-hosted Ansible against `localhost`

Run Ansible inside WSL2 (which Docker Desktop already provides) with `connection: local`.

- **Against**: this does not work, and it is worth writing down why so nobody tries it. WSL2 is a separate Linux kernel and filesystem namespace. `connection: local` from WSL converges *WSL*, not Windows. To reach the Windows host you still need SSH or WinRM back into it -- so this is option A or B with an extra hop, not an alternative to them. The only thing it would buy is running the Ansible binary without a container, which we do not need.

### D. PowerShell DSC v3 (`dsc`)

Express desired state as a DSC v3 configuration document (YAML/JSON), converge with `dsc config set`, check with `dsc config test` and `--what-if`.

- **For**: native to Windows, no listener, declarative document is reviewable, and `dsc config test` is a genuine check mode. It is the strategically "correct" Microsoft answer.
- **Against**: the three things we actually need to do on this machine are (1) install a release binary verified against a checksum, (2) write a file with a specific ACL from a secret supplied at apply time, and (3) idempotently register an MCP server in two different client configs, one of which is a JSON file we must merge rather than overwrite. None of those is a stock DSC resource. DSC v3 would have us write command-based resources implementing exactly the get/test/set logic we would otherwise write directly -- so the custom code is identical, and DSC contributes only an outer engine plus a new tool to install and pin. That is a real cost for no reduction in the code we own.
- **Also against**: DSC v3 is young. Betting the desktop layer's entry point on it now means owning both our logic and the churn in its resource contract.

### E. Idempotent `pwsh` converge driven by a declarative data file

A repo-owned entry point, `desktop/Invoke-DesktopConverge.ps1`, reads desired state from `desktop/desktop.psd1` and converges it item by item. Every item is a `Test`/`Set` pair behind a shared `Invoke-ConvergeStep` helper that honours `-WhatIf` and re-tests after every change. Run it elevated, on the desktop, in `pwsh`.

- **For**: shape-identical to how `laptop.yml` works -- the machine converges itself, run by the person sitting at it, from code in this repo. Zero new listeners and zero new daemons on a personal workstation. `pwsh` is already installed, so there is nothing to bootstrap. `-WhatIf` gives check mode. The data file is where review attention belongs (versions, paths, URLs), and it is `Import-PowerShellDataFile`-safe, so reading it never executes code.
- **Against**: **we own the idempotency**. Ansible and DSC would have given it to us; here, a sloppy item can silently do nothing or do it twice. This is the real cost of the option, and the mitigation is structural, not aspirational: no item may call `Set` directly, every item goes through `Invoke-ConvergeStep -Test {...} -Set {...}`, and the helper re-runs `Test` after `Set` and fails the item if state did not converge. An item that lies about its own state fails loudly on the same run.
- **Also against**: a second engine in a repo that otherwise speaks Ansible. Accepted -- see below.

## Decision

**Option E.** The desktop layer is a `pwsh` converge script plus a declarative data file, in a new top-level `desktop/` directory, run locally and elevated on the desktop.

The reasoning, in the order the criteria were weighed:

1. **House-rule fit is a tie, so it does not decide.** A, B, D and E all put the change in the repo, behind a PR, applied by a repo tool, with a check mode. C fails outright. Every surviving option satisfies the rule, so the rule cannot pick among them.
2. **Attack surface decides against A and B.** Both buy their convenience with a standing inbound remote-administration listener on a personal workstation, and A additionally pays it for a loopback. A converge that runs a handful of times a year does not justify a service that listens all year. This is the load-bearing argument.
3. **Effort decides against D.** DSC v3 and E write the same custom get/test/set logic, because none of our three operations has a stock resource. D adds a tool to install, pin and track on top of that. Same code, more dependencies.
4. **`laptop.yml` is the precedent, and it points at E.** The repo already decided that a personal machine converges itself locally rather than being reached into remotely. `desktop/` is that same decision, expressed in the only language the machine speaks natively.

`desktop/` is a new top-level directory because `CLAUDE.md` already states the convention: one top-level directory per IaC tool (`terraform/`, `ansible/`, `helm-charts/`, `docker/`). A PowerShell converge is a new tool, so it gets a directory rather than being smuggled into `ansible/`, which would imply Ansible runs it.

### Layout

```
desktop/
  README.md                          What it is, how to run it, the item list
  desktop.psd1                       Desired state (the reviewable surface)
  Invoke-DesktopConverge.ps1         Entry point: -Item, -WhatIf, -ListItems
  Export-OpenMessageData.ps1         One-shot: stage the daemon's data for migration
  lib/
    Converge.psm1                    Invoke-ConvergeStep, verified download, ACLs, health gate
    Items/
      OpenMessageClient.psm1         Binary, token file, Claude Code MCP, Claude Desktop MCP
      OpenMessageDaemon.psm1         Retirement: stop phase, remove phase
```

### The item contract

Every item is a function that takes the item's config hashtable and calls `Invoke-ConvergeStep` one or more times. `Invoke-ConvergeStep`:

- runs `Test`; if it returns `$true`, records `ok` and does nothing;
- otherwise, if `-WhatIf` is in effect, records `would-change` and does nothing;
- otherwise runs `Set`, then runs `Test` again and fails the step if it still returns `$false`.

That post-check is what keeps "we own the idempotency" from being a wish. It also means `-WhatIf` is honest: a step that reports `would-change` is one whose `Test` actually failed, not one we assumed was dirty.

Failures are collected per-item rather than aborting the run, and the script exits non-zero if any step failed. A missing secret should not stop the binary from being installed.

## Consequences

**Good:**

- The desktop gains no network-reachable administration path. Converging it requires physical or interactive access, which is the correct bar for a personal machine.
- `-WhatIf` is a genuine dry run over the whole item set, so a reviewer can see the diff a converge would make before it makes it.
- The desired state lives in one small data file. Version bumps, URL changes and path changes are one-line diffs in `desktop.psd1`, not edits scattered through a script.
- The data-migration guard rails become code: the export refuses to run while the daemon is still running, and the import refuses to run unless the export said so.

**Bad, and accepted:**

- **Two config engines.** Someone working on the laptop writes YAML tasks; someone working on the desktop writes PowerShell. There is no shared module, and a change to the OpenMessage client target state has to be made twice (`ansible/playbooks/tasks/openmessage_client.yml` and `desktop/lib/Items/OpenMessageClient.psm1`). Mitigation is honesty rather than abstraction: both files carry a pointer to each other and to this spec, and the values that must agree (release tag, endpoint URL, MCP server name) are stated once in each layer's data file. A premature shared abstraction across two operating systems, two package formats and two Claude config locations would cost more than the duplication.
- **No CI can execute it.** There is no Windows runner in this repo, so the converge is only ever exercised by running it. `-WhatIf` on the desktop is the pre-flight; PSScriptAnalyzer and Pester are available to a future CI job if a Windows runner ever appears.
- **We own idempotency bugs.** Structurally mitigated by the post-`Set` re-test, but still true.

**Revisit this decision if:**

- A second Windows machine appears. Two machines change the arithmetic: option A's per-machine setup cost amortizes, and "converge it by sitting at it" stops scaling. At that point, the item logic here is still the thing worth keeping -- it would be ported into `ansible.windows` tasks, not rewritten.
- The desktop ever becomes a server (always-on, fixed address, hosting something). Then it belongs in `site.yml` behind SSH like the homelab, and the personal-workstation argument no longer applies.
- DSC v3 grows stock resources for checksum-verified binary installs and JSON-merge file edits, which would flip the effort argument in D's favour.

## First managed item: OpenMessage

The desktop's current OpenMessage setup (from the fork's `docs/windows-runbook.md`) is a local daemon plus two MCP clients that talk to it through the local store:

- Windows service `OpenMessage`, virtual account `NT SERVICE\OpenMessage`, delayed auto-start, binary `C:\tools\openmessage.exe`, command line `service`.
- Data directory under the user profile (`.local\share\openmessage`), with a Modify ACL granted to the service account. It holds `messages.db` (+ `-wal`/`-shm`), `session.json` (the Google pairing credential), `control.token` and `daemon.log`.
- Claude Code (user scope) and Claude Desktop (`%APPDATA%\Claude\claude_desktop_config.json`) both register MCP server `openmessage` as `C:\tools\openmessage.exe serve --mcp-stdio`.

Target state after this layer converges:

1. `C:\tools\openmessage.exe` is the release pinned in `desktop.psd1` (`v0.2.9-remote.1`), verified against that release's `SHA256SUMS`.
2. A per-user token file at `%USERPROFILE%\.config\openmessage\token`, inheritance disabled and only the current user granted, written from `$env:OPENMESSAGE_CONTROL_TOKEN` at apply time. Never in the repo, never in a Claude config, never logged.
3. Both Claude clients run the bridge instead of the local server:
   `openmessage mcp-bridge --url https://openmessage.lab.infiniteroomlabs.cloud/mcp --token-file <that file>`.
   The bridge (`cmd/mcp_bridge.go` in the fork) relays stdio to the cluster's streamable-HTTP endpoint and adds the `Authorization` header itself, which is why the token stays out of Claude's JSON. Claude Desktop needs it because its remote connectors run from Anthropic's cloud and cannot reach a tailnet-only host.
4. The local daemon is retired in **two separately-invokable phases**, because exactly one OpenMessage may hold the Google pairing:
   - **stop** -- service Stopped and StartupType Manual, so a reboot cannot revive it. Runs *before* the cluster pod first starts.
   - **remove** -- `sc.exe delete OpenMessage`. Refuses unless the cluster endpoint is healthy (`/healthz` 200 **and** `/mcp` 401, which proves both that the remote daemon serves and that its token gate is a gate) and the service is already Stopped. The data directory is left in place as a cold backup.

Neither retirement phase runs by default; both must be named with `-Item`. The default converge is the three client items, which are safe to run at any time and on any machine state.

### Secret supply

The converge never talks to Bitwarden. It reads `$env:OPENMESSAGE_CONTROL_TOKEN` and writes it to the token file. Supplying it is the operator's job, the same way `scripts/with-secrets.sh` supplies secrets to terragrunt: `fnox exec` if fnox is present on the desktop, otherwise one `bw get password openmessage-control-token` piped into the variable for one command. The item is skipped-with-error (not fatal to the run) when the variable is absent and the file does not already exist; it is a no-op when the file already holds the right value, which is how a no-secret converge stays useful.

## Non-goals

- Managing anything else on the desktop yet. The layer is built so the next item is a new file under `lib/Items/` and a new block in `desktop.psd1`, but this PR adds exactly one subject.
- Unattended or scheduled converges. There is no Windows equivalent of the laptop's systemd timers here, and adding one would reintroduce the "runs without a human" property that the local-run model exists to avoid.
- Deleting the desktop's OpenMessage data directory. It is the rollback, and it stays until someone decides otherwise by hand.
