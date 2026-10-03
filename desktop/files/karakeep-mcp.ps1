<#
.SYNOPSIS
    Launch the Karakeep MCP server over stdio with the API key read from a file.

.DESCRIPTION
    @karakeep/mcp takes its credentials from the environment and nowhere else.
    Putting them in Claude Code's `env` block would write the key into
    ~/.claude.json, so this wrapper plays the role the OpenMessage bridge plays
    for that server: it reads the key from an owner-only file and sets the
    variable for the duration of one child process. The MCP registration then
    holds only paths and a package pin.

    stdout is the MCP protocol channel. Nothing may be written to it but the
    server's own stream -- no Write-Host, no Write-Output, no progress. All
    diagnostics go to stderr.

    Installed to %LOCALAPPDATA%\irl-desktop\bin\ by the `karakeep-launcher`
    item in desktop/lib/Items/KarakeepMcp.psm1; the package version is pinned
    in desktop/desktop.psd1. Edit this file in the repo, not in place.

.PARAMETER ApiAddr
    Base URL of the Karakeep instance.

.PARAMETER KeyFile
    Path to the file holding the API key. Written by the `karakeep-api-key`
    converge item.

.PARAMETER Package
    npm package spec to run, including the pinned version.
#>

param(
    [Parameter(Mandatory)][string]$ApiAddr,
    [Parameter(Mandatory)][string]$KeyFile,
    [Parameter(Mandatory)][string]$Package
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $KeyFile -PathType Leaf)) {
    [Console]::Error.WriteLine("karakeep-mcp: key file not found: $KeyFile -- run the 'karakeep-api-key' converge item (desktop/README.md).")
    exit 1
}

$key = [System.IO.File]::ReadAllText($KeyFile).Trim()
if ([string]::IsNullOrEmpty($key)) {
    [Console]::Error.WriteLine("karakeep-mcp: key file is empty: $KeyFile -- re-run the 'karakeep-api-key' converge item with the secret supplied (desktop/README.md).")
    exit 1
}

$env:KARAKEEP_API_ADDR = $ApiAddr
$env:KARAKEEP_API_KEY = $key

$npx = Get-Command npx.cmd -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($null -eq $npx) {
    [Console]::Error.WriteLine('karakeep-mcp: npx.cmd is not on PATH. Node.js is a prerequisite for this MCP server; the desktop layer does not install it.')
    exit 1
}

# Not wrapped in a pipeline on purpose: an unpiped native call in pwsh 7 hands
# the real stdin/stdout through to the child, which is what the MCP transport
# needs.
& $npx.Source -y $Package
exit $LASTEXITCODE
