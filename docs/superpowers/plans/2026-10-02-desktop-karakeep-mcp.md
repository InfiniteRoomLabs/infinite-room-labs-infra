# Karakeep MCP on the desktop -- Implementation Plan (work order)

**Goal:** Give Claude Code on the Windows desktop a user-scope MCP server for the homelab Karakeep (`bookmarks.lab.infiniteroomlabs.cloud`), managed by the `desktop/` converge layer, with the API key supplied from Bitwarden and never written into a Claude config.

**Architecture:** Three new items in `desktop/`, same contract as the OpenMessage client items: an owner-only key file written from an environment variable at apply time, a repo-shipped launcher script installed to a stable per-user path, and a user-scope Claude Code registration that runs the launcher. The launcher reads the key file and runs the official `@karakeep/mcp` server over stdio via `npx`, so the registration itself holds only paths and a package pin.

**Tech stack:** PowerShell 7 (`desktop/lib/Converge.psm1` helpers), `@karakeep/mcp` 0.33.1 (npm, stdio; needs Node on `PATH`), Bitwarden item `karakeep-mcp-api-key`, fnox declaration for machines that have it.

**Spec:** the desktop layer design, `docs/superpowers/specs/2026-09-29-desktop-iac-design.md`, section "The item contract". This plan adds the second subject that spec said would test the contract.

**Depends on:** PR #19 (`feat/desktop-iac-openmessage`), which creates `desktop/`. This branch is **stacked on it**: branch `feat/desktop-karakeep-mcp`, PR base `feat/desktop-iac-openmessage`.

## Decisions already made (do not re-derive)

1. **User scope, not project scope.** The server is for the whole machine. Nothing is added to the repo's `.mcp.json`.
2. **Key file + launcher, not `env` in the registration.** Claude Code's user-scope config can carry an `env` block, but that writes the secret into `~/.claude.json`. The OpenMessage items solved the same problem with a bridge that reads a token file; Karakeep's server has no bridge, so a 20-line launcher plays that role.
3. **`npx -y @karakeep/mcp@0.33.1`, pinned.** Repo policy is no floating `latest`. The Docker image alternative was rejected: it adds a Docker Desktop dependency to every Claude session start and a WSL2-to-tailnet routing question for a one-process tool.
4. **Claude Code only.** No Claude Desktop item in this PR. Claude Desktop's config merge helper (`Test-McpEntryMatches`) is private to `OpenMessageClient.psm1`; lifting it into `Converge.psm1` is a follow-up with its own PR.
5. **Desktop only.** No laptop counterpart in `laptop.yml`. Follow-up if wanted; the fnox declaration below is what the laptop would consume.
6. **The Bitwarden item already exists.** `karakeep-mcp-api-key`, Login item, password field = the key, folder `IRL/Services/Karakeep`, created 2026-10-02, 57 characters. Do not create or edit it. It is a per-user key named `mcp` on the single admin account, so it carries full access; rotation policy 365 days (service secret).
7. **The key never appears in output.** Not in logs, not in `-WhatIf` output, not in a tool result. Drift is detected by SHA-256 comparison (`Get-StringSha256`), exactly as `Invoke-OpenMessageTokenItem` does.

## Target state on the desktop

| Thing | Value |
|---|---|
| Key file | `%USERPROFILE%\.config\karakeep\api-key`, UTF-8 no BOM, owner-only ACL (`Set-OwnerOnlyAcl`) |
| Launcher | `%LOCALAPPDATA%\irl-desktop\bin\karakeep-mcp.ps1`, byte-identical to `desktop/files/karakeep-mcp.ps1` |
| Claude Code MCP `karakeep` (user scope) | `pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File <launcher> -ApiAddr https://bookmarks.lab.infiniteroomlabs.cloud -KeyFile <key file> -Package @karakeep/mcp@0.33.1` |

## Task 1: Desired state

**File:** `desktop/desktop.psd1`

- [ ] Add a top-level `Karakeep` section next to `OpenMessage`:
  `Package = '@karakeep/mcp'`, `PackageVersion = '0.33.1'`, `ApiAddr = 'https://bookmarks.lab.infiniteroomlabs.cloud'`,
  `KeyFile = '%USERPROFILE%\.config\karakeep\api-key'`, `KeyEnvVar = 'KARAKEEP_API_KEY'`,
  `LauncherSource = 'files\karakeep-mcp.ps1'` (relative to `desktop/`), `LauncherPath = '%LOCALAPPDATA%\irl-desktop\bin\karakeep-mcp.ps1'`,
  `McpServerName = 'karakeep'`.
- [ ] Comment the section the way `OpenMessage` is commented: what each key is, where the secret comes from, and that the file holds no user names (tokens only). `SchemaVersion` stays 1 -- this adds a section, it does not change an existing item's keys.

## Task 2: The launcher

**File:** `desktop/files/karakeep-mcp.ps1` (new)

- [ ] `param([Parameter(Mandatory)][string]$ApiAddr, [Parameter(Mandatory)][string]$KeyFile, [Parameter(Mandatory)][string]$Package)`.
- [ ] `Set-StrictMode -Version Latest`; `$ErrorActionPreference = 'Stop'`.
- [ ] Read the key with `[System.IO.File]::ReadAllText($KeyFile).Trim()`. If the file is missing or empty, write one line to **stderr** (`[Console]::Error.WriteLine(...)`) naming the converge item that creates it, and `exit 1`. Nothing may go to stdout except the MCP stream: stdout is the protocol channel, so no `Write-Host`, no `Write-Output`, no progress.
- [ ] `$env:KARAKEEP_API_ADDR = $ApiAddr`; `$env:KARAKEEP_API_KEY = $key`.
- [ ] Resolve `npx.cmd` with `Get-Command npx.cmd -CommandType Application`; if absent, stderr + `exit 1` with a one-line hint (Node is a prerequisite, not something this layer installs).
- [ ] `& $npx.Source -y $Package`; then `exit $LASTEXITCODE`. Native stdin/stdout pass straight through in pwsh 7 when nothing is piped; do not wrap the call in a pipeline.
- [ ] Header comment: what it is, why it exists (decision 2), that `desktop/lib/Items/KarakeepMcp.psm1` installs it and `desktop.psd1` pins the package.

## Task 3: The items

**File:** `desktop/lib/Items/KarakeepMcp.psm1` (new). Mirror the structure and comment style of `OpenMessageClient.psm1`. Import `Converge.psm1` the same way (no `-Force`).

- [ ] **`Invoke-KarakeepApiKeyItem`** (item `karakeep-api-key`). A copy of `Invoke-OpenMessageTokenItem` with the names changed: directory exists; file content matches `$env:KARAKEEP_API_KEY` by SHA-256 (no-op when the variable is absent and the file is non-empty; fails when neither exists, naming the Bitwarden item and the two supply commands from Task 5); ACL is owner-only.
- [ ] **`Invoke-KarakeepLauncherItem`** (item `karakeep-launcher`). Test: installed file exists and its SHA-256 equals the repo copy's. Set: create the directory, `Copy-Item -Force`. The source path is resolved against the entry point's directory, so the handler takes `-Config` and `-DesktopRoot`; `Invoke-DesktopConverge.ps1` supplies `$PSScriptRoot`. (This is the one contract change; see Task 4.)
- [ ] **`Invoke-KarakeepClaudeCodeItem`** (item `karakeep-claude-code`). Same shape as `Invoke-OpenMessageClaudeCodeItem`: `claude mcp get karakeep` via `Invoke-NativeCapture`; converged when exit 0 **and** the output contains the launcher path, the API address and the package spec (`@karakeep/mcp@0.33.1`), so a version bump in `desktop.psd1` reads as drift. Set: `claude mcp remove karakeep --scope user` (ignore exit), then `claude mcp add --scope user karakeep -- pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File <launcher> -ApiAddr <addr> -KeyFile <key> -Package <spec>`; throw on non-zero. Build the argument vector in one `Get-KarakeepLaunchArgument -Config` function and export it, as `Get-BridgeArgument` is.
- [ ] Export the three handlers and the argument builder.

## Task 4: Entry point and docs

**Files:** `desktop/Invoke-DesktopConverge.ps1`, `desktop/README.md`

- [ ] `Import-Module` the new item module. Add the three names to the `ValidateSet` and to `$ItemRegistry` with `Section = 'Karakeep'`, `Default = $true`, and one-line descriptions. For `karakeep-launcher`, the handler needs the repo path: pass `-DesktopRoot $PSScriptRoot` to every handler that declares that parameter (check with `(Get-Command $meta.Handler).Parameters.ContainsKey('DesktopRoot')`) so the OpenMessage handlers are untouched.
- [ ] README: three rows in the Items table; generalise "Supplying the control token" to "Supplying secrets" and list both variables and both Bitwarden items; add Node.js to Requirements ("for the Karakeep item; `npx` must resolve"); note under Known limitations that `claude mcp get` substring matching applies here too.

## Task 5: Secret lane and repo docs

**Files:** `fnox.toml`, `CHANGELOG.md`, `docs/homelab-access-guide.md`

- [ ] `fnox.toml`, after the OpenMessage block, using the neighbouring blocks' header style:
  ```toml
  # Karakeep (@karakeep/mcp on the desktop)
  # Per-user API key (named "mcp", admin account) for the homelab Karakeep.
  # Consumed CLIENT-SIDE by desktop/Invoke-DesktopConverge.ps1, which writes it
  # to an owner-only key file read by the launcher; never in a Claude config.
  # No cluster or Ansible target, so nothing rides the bw-sync lane.
  KARAKEEP_API_KEY = { provider = "bitwarden", value = "karakeep-mcp-api-key", description = "Karakeep API key for @karakeep/mcp (client side)" }
  ```
- [ ] `CHANGELOG.md`, `## [Unreleased]` / `### Added`, one entry in the repo's voice: what was added, why the launcher exists, what is pinned, where the key lives, that Claude Desktop and the laptop are follow-ups.
- [ ] `docs/homelab-access-guide.md`: extend the Karakeep row -- MCP for Claude Code is converged by `desktop/` (items `karakeep-*`), key is BW `karakeep-mcp-api-key` in the same folder.
- [ ] Supply commands to document (README and the item's error text):
  ```powershell
  # with fnox on the machine
  fnox exec -- pwsh -File .\Invoke-DesktopConverge.ps1
  # without fnox (this desktop today)
  $env:BW_SESSION = (Get-Content "$HOME\.bw_session" -Raw).Trim()
  $env:KARAKEEP_API_KEY = (bw get password karakeep-mcp-api-key)
  pwsh -File .\Invoke-DesktopConverge.ps1 -Item karakeep-api-key, karakeep-launcher, karakeep-claude-code
  Remove-Item Env:\KARAKEEP_API_KEY
  ```

## Verification split

The agent-box has the Linux toolchain but no `pwsh`; the desktop has `pwsh` but no fnox. Each side checks what it can.

**In the agent-box (before pushing):**
- [ ] `fnox check` and `v="$(fnox get KARAKEEP_API_KEY)"; echo "len=${#v}"` -- expect `len=57`. Never print the value.
- [ ] `cd tests && uv run pytest -m hygiene` -- docs encoding (ASCII only, no hard-wrapped prose) and fan-out contracts.
- [ ] Public-readiness leak scan over the diff and the new files: no key material, no user names, no home paths (`%USERPROFILE%` / `%LOCALAPPDATA%` tokens only).
- [ ] `git diff --check`; review the launcher by eye for anything that writes to stdout.

**On the desktop (after the PR is up; the operator or a host session does this):**
- [ ] `pwsh -File .\Invoke-DesktopConverge.ps1 -ListItems` shows the three items.
- [ ] `pwsh -File .\Invoke-DesktopConverge.ps1 -WhatIf -Item karakeep-api-key, karakeep-launcher, karakeep-claude-code` -- exit 2, three `would-change` lines, nothing changed.
- [ ] Apply with the supply commands above. Exit 0.
- [ ] Handshake without Claude: pipe an `initialize` + `tools/list` JSON-RPC pair into the launcher and confirm `serverInfo` and a tool list come back. Then a `search-bookmarks` call that returns `isError: false`.
- [ ] Re-run `-WhatIf`: exit 0, all `ok`.
- [ ] Restart Claude Code; `/mcp` shows `karakeep` connected.
- [ ] The temporary key file the operator staged has already been deleted (2026-10-02); Bitwarden is the only copy.

## Worktree note for the agent-box

Host-created git worktrees record an absolute Windows `gitdir` path and do not resolve inside the container. Create a worktree **inside the box** instead:

```bash
cd /work/infinite-room-labs/infinite-room-labs-infra
git fetch origin
git worktree add .claude/worktrees/box-desktop-karakeep-mcp feat/desktop-karakeep-mcp
```

`.claude/worktrees/` is git-ignored. The canonical clone's working tree is in use by a host session; do not switch its branch.

## Out of scope (follow-ups, each its own PR)

- Claude Desktop registration for Karakeep (lift `Test-McpEntryMatches` into `Converge.psm1` first).
- Laptop counterpart in `ansible/playbooks/laptop.yml` (bash launcher or fnox-wrapped `npx`).
- Installing fnox on the desktop (open question 1 in the OpenMessage plan).
