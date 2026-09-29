# Desktop IaC layer

Infrastructure-as-code for the Windows 10 workstation, in the same spirit as `ansible/playbooks/laptop.yml`: **the machine converges itself, run by the person sitting at it, from code in this repo.** There is no remote-administration listener, no scheduled run, and nothing here reaches out to any other machine except to download a pinned release and to check that the cluster endpoint is healthy.

- Design and the options that were rejected: [`docs/superpowers/specs/2026-09-29-desktop-iac-design.md`](../docs/superpowers/specs/2026-09-29-desktop-iac-design.md)
- Implementation plan and apply sequence: [`docs/superpowers/plans/2026-09-29-desktop-iac-openmessage.md`](../docs/superpowers/plans/2026-09-29-desktop-iac-openmessage.md)
- Linux counterpart for the OpenMessage items: [`ansible/playbooks/tasks/openmessage_client.yml`](../ansible/playbooks/tasks/openmessage_client.yml)

## Requirements

- PowerShell 7 (`pwsh`). Windows PowerShell 5.1 is not supported: the code uses `ConvertFrom-Json -AsHashtable`, `Invoke-WebRequest -SkipHttpErrorCheck` and `[ordered]` parameter defaults from 7.x.
- An elevated session for the two daemon-retirement items only. The client items run unelevated.
- `claude` (Claude Code CLI) on `PATH` for the Claude Code item.

## Layout

| Path | What it is |
|---|---|
| `desktop.psd1` | **The desired state.** Pinned release, URLs, paths, service and server names. This is the file to review and the file to edit. |
| `Invoke-DesktopConverge.ps1` | Entry point. Selects items, runs them, prints a summary, exits non-zero on failure. |
| `Export-OpenMessageData.ps1` | One-shot: stage the local daemon's SQLite store and pairing credential for migration into the cluster. |
| `lib/Converge.psm1` | `Invoke-ConvergeStep` plus verified downloads, ACL helpers, the cluster health gate. |
| `lib/Items/*.psm1` | One module per subject. Each item is a `Test`/`Set` pair. |

`desktop.psd1` is read with `Import-PowerShellDataFile`, which cannot execute code. That is why paths use `%USERPROFILE%` / `%APPDATA%` tokens rather than `$env:` references -- they are expanded at run time, and it keeps real user names out of a public repo.

## Running it

```powershell
cd <repo>\desktop

# What would change? Changes nothing.
pwsh -File .\Invoke-DesktopConverge.ps1 -WhatIf

# Converge the default (client) items.
pwsh -File .\Invoke-DesktopConverge.ps1

# What items exist?
pwsh -File .\Invoke-DesktopConverge.ps1 -ListItems

# One item only.
pwsh -File .\Invoke-DesktopConverge.ps1 -Item openmessage-claude-desktop
```

Exit codes: `0` converged (or already converged), `1` at least one step failed, `2` under `-WhatIf` only, meaning drift was found and nothing was changed.

### Supplying the control token

The converge never talks to Bitwarden. The token arrives in `$env:OPENMESSAGE_CONTROL_TOKEN` for one command, from Bitwarden item `openmessage-control-token` (the token is its login password field):

```powershell
# Preferred, if fnox is installed on this machine -- same lane as
# scripts/with-secrets.sh on the laptop.
fnox exec -- pwsh -File .\Invoke-DesktopConverge.ps1

# Otherwise, for one shell:
$env:OPENMESSAGE_CONTROL_TOKEN = (bw get password openmessage-control-token)
pwsh -File .\Invoke-DesktopConverge.ps1
Remove-Item Env:\OPENMESSAGE_CONTROL_TOKEN
```

The token item is a no-op when the file already holds the right value, so routine converges do not need an unlocked vault. It fails (without stopping the rest of the run) only when the file does not exist and the variable is not set.

## Items

| Item | Default | What it converges |
|---|---|---|
| `openmessage-binary` | yes | `C:\tools\openmessage.exe` is the release pinned in `desktop.psd1`, verified against that release's `SHA256SUMS`. |
| `openmessage-token` | yes | `%USERPROFILE%\.config\openmessage\token` holds the control token, inheritance stripped and only the current user granted. |
| `openmessage-claude-code` | yes | User-scope Claude Code MCP server `openmessage` runs `openmessage mcp-bridge --url <cluster>/mcp --token-file <that file>`. |
| `openmessage-claude-desktop` | yes | Same registration merged into `%APPDATA%\Claude\claude_desktop_config.json`. Backs the file up first; never overwrites other servers. |
| `openmessage-daemon-stop` | **no** | Retirement phase 1: the local Windows service is Stopped and set to Manual. Elevated. |
| `openmessage-daemon-remove` | **no** | Retirement phase 2: the service is deleted. Elevated. Refuses unless the cluster endpoint passes its health gate. |

### Why the daemon retirement is two items

Exactly one OpenMessage may hold the Google Messages pairing. Two daemons on one pairing fight over the session and Google can revoke it, which costs a re-pair from the phone.

- **Stop** runs *before* the cluster pod first starts, and is reversible: `Start-Service OpenMessage` brings the local daemon back if the cutover goes wrong. Setting StartupType to Manual is the point of the phase -- it stops a reboot from quietly starting a second daemon.
- **Remove** runs only once every client is cut over and working. It refuses unless the service is already Stopped **and** the cluster endpoint returns 200 on `/healthz` *and* 401 on `/mcp` -- the 401 matters as much as the 200, because it proves the token gate is a gate rather than an open endpoint that happens to answer.

The data directory is never deleted. It is the rollback.

## Migrating the daemon's data into the cluster

Two steps, on two machines, because the guard that matters can only be checked on Windows:

```powershell
# On the desktop, after openmessage-daemon-stop:
pwsh -File .\Export-OpenMessageData.ps1 -WhatIf
pwsh -File .\Export-OpenMessageData.ps1
```

The export refuses to run while the daemon is running, copies `messages.db` and its `-wal`/`-shm` companions and `session.json` as one unit, and writes `SHA256SUMS` plus a `manifest.json` recording the service state it observed.

```bash
# On a tailnet host with kubectl and SSH to the homelab:
./scripts/openmessage-import-data.sh --from <bundle> --dry-run
./scripts/openmessage-import-data.sh --from <bundle>
```

The import refuses a bundle whose manifest does not say the service was Stopped or Absent, refuses while the cluster Deployment has replicas or pods, verifies checksums on both sides, and does not start the pod.

## Adding a new item

1. Add a section to `desktop.psd1`.
2. Add a module under `lib/Items/` exporting `Invoke-<Thing>Item -Config <hashtable>`.
3. Register it in `$ItemRegistry` in `Invoke-DesktopConverge.ps1`.

Every change goes through `Invoke-ConvergeStep -Test {...} -Set {...}`. Never call `Set` logic directly: the helper is what honours `-WhatIf`, and it re-runs `Test` after `Set` and fails the step if the state did not actually converge. That post-check is the only thing standing between hand-rolled idempotency and wishful thinking.

## Known limitations

- **No CI.** There is no Windows runner in this repo, so nothing here is exercised except by running it. `-WhatIf` is the pre-flight. PSScriptAnalyzer and Pester would be the obvious first CI job if a runner ever appears.
- **Duplicated target state.** The OpenMessage client target state exists twice, here and in `ansible/playbooks/tasks/openmessage_client.yml`, with no shared code. Change both. This was a deliberate trade in the design doc; see "Consequences".
- **Claude Desktop JSON is reformatted.** Merging round-trips the file through `ConvertFrom-Json`/`ConvertTo-Json`, which does not preserve key order or original whitespace. Content is preserved; the first diff will be noisy.
- **Drift detection for Claude Code reads CLI output**, not Claude's config file, so a registration that merely reorders arguments would read as converged.
