<#
.SYNOPSIS
    Converge the Windows desktop to the state declared in desktop.psd1.

.DESCRIPTION
    The desktop's equivalent of ansible/playbooks/laptop.yml: the machine
    converges itself, run by the person sitting at it, from code in this repo.
    There is no remote-administration listener and no scheduled run.

    Design:  docs/superpowers/specs/2026-09-29-desktop-iac-design.md
    Plan:    docs/superpowers/plans/2026-09-29-desktop-iac-openmessage.md
    Usage:   desktop/README.md

    Items are independent. A failure is recorded and the run continues to the
    next item, so a missing secret does not stop a binary install. The exit
    code is non-zero if any step failed.

.PARAMETER Item
    Items to run. Defaults to the client items -- the two daemon-retirement
    items must always be named explicitly, because they are sequenced against
    a cluster deploy rather than run whenever.

.PARAMETER ListItems
    Print the item names and what each one does, then exit.

.PARAMETER ConfigPath
    Override the desired-state data file. Defaults to desktop.psd1 next to
    this script.

.EXAMPLE
    pwsh -File .\Invoke-DesktopConverge.ps1 -WhatIf
    Dry run of the default items: report what would change, change nothing.

.EXAMPLE
    fnox exec -- pwsh -File .\Invoke-DesktopConverge.ps1
    Converge the client items with the control token injected from Bitwarden.

.EXAMPLE
    pwsh -File .\Invoke-DesktopConverge.ps1 -Item openmessage-daemon-stop
    Stop the local daemon before the cluster pod first starts.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet(
        'openmessage-binary',
        'openmessage-token',
        'openmessage-claude-code',
        'openmessage-claude-desktop',
        'openmessage-daemon-stop',
        'openmessage-daemon-remove'
    )]
    [string[]]$Item,

    [switch]$ListItems,

    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# No -Force on any Import-Module here: Converge.psm1 holds the run's step
# results in module scope, and reloading it mid-run would split them across
# two instances.
Import-Module (Join-Path $PSScriptRoot 'lib' 'Converge.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib' 'Items' 'OpenMessageClient.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib' 'Items' 'OpenMessageDaemon.psm1')

# name -> { Handler; Section; Default; Description }
# Section names the top-level key in desktop.psd1 the handler is given.
$ItemRegistry = [ordered]@{
    'openmessage-binary'         = @{
        Handler     = 'Invoke-OpenMessageBinaryItem'
        Section     = 'OpenMessage'
        Default     = $true
        Description = 'Install the pinned openmessage.exe, verified against the release SHA256SUMS'
    }
    'openmessage-token'          = @{
        Handler     = 'Invoke-OpenMessageTokenItem'
        Section     = 'OpenMessage'
        Default     = $true
        Description = 'Write the control token to a per-user, owner-only file (needs $env:OPENMESSAGE_CONTROL_TOKEN on first run)'
    }
    'openmessage-claude-code'    = @{
        Handler     = 'Invoke-OpenMessageClaudeCodeItem'
        Section     = 'OpenMessage'
        Default     = $true
        Description = 'Point the user-scope Claude Code MCP server at the cluster bridge'
    }
    'openmessage-claude-desktop' = @{
        Handler     = 'Invoke-OpenMessageClaudeDesktopItem'
        Section     = 'OpenMessage'
        Default     = $true
        Description = 'Merge the cluster bridge into claude_desktop_config.json (backs the file up first)'
    }
    'openmessage-daemon-stop'    = @{
        Handler     = 'Invoke-OpenMessageDaemonStopItem'
        Section     = 'OpenMessage'
        Default     = $false
        Description = 'RETIREMENT PHASE 1: stop the local Windows service and set it to Manual. Elevated.'
    }
    'openmessage-daemon-remove'  = @{
        Handler     = 'Invoke-OpenMessageDaemonRemoveItem'
        Section     = 'OpenMessage'
        Default     = $false
        Description = 'RETIREMENT PHASE 2: delete the service, once the cluster endpoint passes its health gate. Elevated.'
    }
}

if ($ListItems) {
    foreach ($name in $ItemRegistry.Keys) {
        $meta = $ItemRegistry[$name]
        $tag = if ($meta.Default) { 'default' } else { 'opt-in ' }
        Write-Host ("{0}  {1,-28} {2}" -f $tag, $name, $meta.Description)
    }
    exit 0
}

if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'desktop.psd1' }
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Desired-state file not found: $ConfigPath"
}
$Config = Import-PowerShellDataFile -LiteralPath $ConfigPath
if ($Config.SchemaVersion -ne 1) {
    throw "desktop.psd1 declares SchemaVersion $($Config.SchemaVersion); this script understands 1."
}

$selected = if ($Item) {
    $Item
}
else {
    @($ItemRegistry.Keys | Where-Object { $ItemRegistry[$_].Default })
}

Write-Host ''
Write-Host "Desktop converge -- $($selected.Count) item(s)$(if ($WhatIfPreference) { ' [WhatIf: nothing will change]' })"
Write-Host "Config: $ConfigPath"
Write-Host ''

Reset-ConvergeState

$failures = 0
foreach ($name in $selected) {
    $meta = $ItemRegistry[$name]
    Write-Host $name -ForegroundColor White
    try {
        & $meta.Handler -Config $Config[$meta.Section] -WhatIf:$WhatIfPreference
    }
    catch {
        $failures++
        Write-ConvergeLog -Level fail -Message $_.Exception.Message
    }
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
$results = Get-ConvergeState
$counts = @{ ok = 0; changed = 0; 'would-change' = 0; failed = 0 }
foreach ($r in $results) { $counts[$r.Outcome] = $counts[$r.Outcome] + 1 }

Write-Host ("Steps: {0} ok, {1} changed, {2} would change, {3} failed; {4} item(s) errored." -f
    $counts['ok'], $counts['changed'], $counts['would-change'], $counts['failed'], $failures)

if ($failures -gt 0 -or $counts['failed'] -gt 0) { exit 1 }
if ($WhatIfPreference -and $counts['would-change'] -gt 0) { exit 2 }  # drift detected, nothing changed
exit 0
