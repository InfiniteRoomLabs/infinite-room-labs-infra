<#
.SYNOPSIS
    Stage the local OpenMessage daemon's data for migration into the cluster.

.DESCRIPTION
    Step one of two. This runs on the desktop and produces a self-describing
    bundle; scripts/openmessage-import-data.sh consumes it from a tailnet host
    and lands it on the homelab PV.

    Two things make this a script rather than four Copy-Item calls:

      1. It refuses to run while the daemon is still running. SQLite is in WAL
         mode, so copying messages.db out from under a live writer can produce
         a torn database -- and the whole point of the migration is to reuse
         session.json rather than re-pair.
      2. It writes SHA256SUMS and a manifest.json recording the service state
         it observed. The import script refuses a bundle whose manifest does
         not say Stopped or Absent, which is how a guard that can only be
         checked on Windows still protects a step that runs on Linux.

    Nothing here starts, stops or deletes anything. Stopping the service is
    Invoke-DesktopConverge.ps1 -Item openmessage-daemon-stop.

    Plan: docs/superpowers/plans/2026-09-29-desktop-iac-openmessage.md

.PARAMETER Destination
    Directory to create and fill. Defaults to a timestamped directory under
    the user profile.

.PARAMETER ConfigPath
    Override the desired-state data file (paths and file list come from it).

.EXAMPLE
    pwsh -File .\Export-OpenMessageData.ps1 -WhatIf

.EXAMPLE
    pwsh -File .\Export-OpenMessageData.ps1 -Destination D:\om-export
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Destination,
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib' 'Converge.psm1')

if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'desktop.psd1' }
$config = (Import-PowerShellDataFile -LiteralPath $ConfigPath).OpenMessage

$serviceName = $config.ServiceName
$dataDir = Expand-ConvergePath $config.DataDir

# ---------------------------------------------------------------------------
# Guard: the daemon must not be running
# ---------------------------------------------------------------------------
$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
$serviceState = if ($null -eq $service) { 'Absent' } else { [string]$service.Status }

if ($serviceState -notin @('Absent', 'Stopped')) {
    throw ("Refusing to export: service '$serviceName' is $serviceState. " +
        "SQLite is in WAL mode, so a copy taken while the daemon writes can be torn. " +
        "Stop it first: pwsh -File .\Invoke-DesktopConverge.ps1 -Item openmessage-daemon-stop")
}

# A stray foreground `openmessage serve` would hold the store too, and the
# service check says nothing about it.
$stray = Get-CimInstance Win32_Process -Filter "Name='openmessage.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine -notmatch '--mcp-stdio' -and $_.CommandLine -notmatch 'mcp-bridge' }
if ($stray) {
    throw ("Refusing to export: an openmessage.exe process that is not an MCP client is running " +
        "(PID $($stray.ProcessId -join ', ')). Stop it before exporting.")
}

if (-not (Test-Path -LiteralPath $dataDir -PathType Container)) {
    throw "Data directory not found: $dataDir"
}

foreach ($required in $config.DataRequired) {
    if (-not (Test-Path -LiteralPath (Join-Path $dataDir $required) -PathType Leaf)) {
        throw "Required file missing from $dataDir`: $required -- there is nothing to migrate."
    }
}

$present = @($config.DataFiles | Where-Object { Test-Path -LiteralPath (Join-Path $dataDir $_) -PathType Leaf })

if (-not $Destination) {
    $Destination = Join-Path $env:USERPROFILE ("openmessage-export-" + (Get-Date).ToString('yyyyMMdd-HHmmss'))
}

Write-Host "Source:      $dataDir"
Write-Host "Service:     $serviceName is $serviceState"
Write-Host "Destination: $Destination"
Write-Host "Files:       $($present -join ', ')"
# -wal/-shm are absent after a clean stop; that is normal, not a problem.
$missing = @($config.DataFiles | Where-Object { $_ -notin $present })
if ($missing) { Write-Host "Not present: $($missing -join ', ') (normal after a clean stop)" }

if (-not $PSCmdlet.ShouldProcess($Destination, 'write OpenMessage data bundle')) {
    Write-Host ''
    Write-Host 'WhatIf: nothing written.'
    exit 0
}

New-Item -ItemType Directory -Path $Destination -Force | Out-Null

foreach ($file in $present) {
    Copy-Item -LiteralPath (Join-Path $dataDir $file) -Destination (Join-Path $Destination $file) -Force
}

# sha256sum -c compatible: lowercase hex, two spaces, bare file name. The far
# side verifies with the coreutils tool, so the format is not ours to choose.
$sumLines = foreach ($file in $present) {
    $hash = (Get-FileHash -LiteralPath (Join-Path $Destination $file) -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $file"
}
Write-TextFileNoBom -Path (Join-Path $Destination 'SHA256SUMS') -Content (($sumLines -join "`n") + "`n")

$manifest = [ordered]@{
    schema        = 1
    kind          = 'openmessage-data-bundle'
    exported_at   = (Get-Date).ToUniversalTime().ToString('o')
    service_name  = $serviceName
    service_state = $serviceState
    files         = $present
}
Write-TextFileNoBom -Path (Join-Path $Destination 'manifest.json') -Content ($manifest | ConvertTo-Json -Depth 5)

Write-Host ''
Write-Host "Bundle written to $Destination"
Write-Host 'Next (from a tailnet host with kubectl and SSH to the homelab):'
Write-Host "  ./scripts/openmessage-import-data.sh --from <copy of $Destination>"
