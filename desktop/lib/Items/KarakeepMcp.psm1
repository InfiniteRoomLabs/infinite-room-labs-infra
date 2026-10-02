<#
.SYNOPSIS
    Desktop items 4-6: the Karakeep API key file, the MCP launcher, and the
    user-scope Claude Code registration that runs it.

.DESCRIPTION
    Target state:

      1. %USERPROFILE%\.config\karakeep\api-key holds the Karakeep API key
         with an owner-only ACL, written from the environment at apply time.
      2. %LOCALAPPDATA%\irl-desktop\bin\karakeep-mcp.ps1 is byte-identical to
         desktop/files/karakeep-mcp.ps1.
      3. Claude Code (user scope) runs that launcher with the API address, the
         key file and the pinned `@karakeep/mcp` spec as arguments.

    The launcher is what keeps the key out of Claude's JSON. @karakeep/mcp
    reads its credentials from the environment only, and Claude Code's `env`
    block would write them into ~/.claude.json -- so the launcher reads the
    key file and sets the variable for one child process, the same division of
    labour `openmessage mcp-bridge` provides for the OpenMessage items.

    Claude Desktop and a laptop counterpart are deliberately out of scope here;
    see the plan's "Out of scope" section.

    Design: docs/superpowers/specs/2026-09-29-desktop-iac-design.md
    Plan:   docs/superpowers/plans/2026-10-02-desktop-karakeep-mcp.md
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# No -Force: Converge.psm1 keeps the run's step results in module scope, and
# -Force would reload it into a second instance with its own empty result
# list, silently emptying the run summary.
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Converge.psm1')

function Get-KarakeepPackageSpec {
    <#
    .SYNOPSIS
        The pinned npm spec, as npx receives it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Config)

    "$($Config.Package)@$($Config.PackageVersion)"
}

function Get-KarakeepLaunchArgument {
    <#
    .SYNOPSIS
        The argument vector Claude Code must launch after `pwsh`, in order.

    .DESCRIPTION
        -NoProfile and -NonInteractive because the launcher's stdout is the MCP
        transport: a profile that prints a banner would corrupt the stream, and
        a prompt would hang the handshake. -ExecutionPolicy Bypass because the
        installed launcher is an unsigned local script.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable]$Config)

    @(
        '-NoProfile'
        '-NonInteractive'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        (Expand-ConvergePath $Config.LauncherPath)
        '-ApiAddr'
        $Config.ApiAddr
        '-KeyFile'
        (Expand-ConvergePath $Config.KeyFile)
        '-Package'
        (Get-KarakeepPackageSpec -Config $Config)
    )
}

# ---------------------------------------------------------------------------
# Item: karakeep-api-key
# ---------------------------------------------------------------------------

function Invoke-KarakeepApiKeyItem {
    <#
    .SYNOPSIS
        Write the Karakeep API key to a per-user, owner-only file.

    .DESCRIPTION
        The key never comes from this repo. It arrives in
        $env:KARAKEEP_API_KEY for the duration of one command, from Bitwarden
        item `karakeep-mcp-api-key`:

            fnox exec -- pwsh -File .\Invoke-DesktopConverge.ps1
            # or, without fnox on this machine:
            $env:KARAKEEP_API_KEY = (bw get password karakeep-mcp-api-key)

        When the variable is absent and the file already holds a key, this is a
        no-op -- which is what makes a routine converge runnable without
        unlocking a vault. When the variable is absent and the file does not
        exist, the item fails (and the rest of the run continues).

        The value is never logged. Drift is detected by comparing SHA-256
        digests, so neither the old nor the new key is ever rendered.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][hashtable]$Config)

    $keyFile = Expand-ConvergePath $Config.KeyFile
    $keyDir = Split-Path -Parent $keyFile
    $supplied = [System.Environment]::GetEnvironmentVariable($Config.KeyEnvVar)
    if ($null -ne $supplied) { $supplied = $supplied.Trim() }

    Invoke-ConvergeStep -Item 'karakeep-api-key' -Name "$keyDir exists" -WhatIf:$WhatIfPreference -Test {
        Test-Path -LiteralPath $keyDir -PathType Container
    } -Set {
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null
    }

    Invoke-ConvergeStep -Item 'karakeep-api-key' -Name 'API key file matches the supplied secret' -WhatIf:$WhatIfPreference -Test {
        if (-not (Test-Path -LiteralPath $keyFile -PathType Leaf)) { return $false }
        if ([string]::IsNullOrEmpty($supplied)) {
            # Nothing to compare against: an existing non-empty file is
            # accepted as-is rather than treated as drift.
            return ((Get-Item -LiteralPath $keyFile).Length -gt 0)
        }
        $current = [System.IO.File]::ReadAllText($keyFile).Trim()
        return ((Get-StringSha256 $current) -eq (Get-StringSha256 $supplied))
    } -Set {
        if ([string]::IsNullOrEmpty($supplied)) {
            throw ("$($Config.KeyEnvVar) is not set and $keyFile does not exist. " +
                "Supply the key for one command from Bitwarden item 'karakeep-mcp-api-key', either " +
                "'fnox exec -- pwsh -File .\Invoke-DesktopConverge.ps1' or " +
                "'`$env:$($Config.KeyEnvVar) = (bw get password karakeep-mcp-api-key)' before the run " +
                "(see desktop/README.md).")
        }
        Write-TextFileNoBom -Path $keyFile -Content $supplied
    }

    Invoke-ConvergeStep -Item 'karakeep-api-key' -Name "$keyFile ACL grants only the current user" -WhatIf:$WhatIfPreference -Test {
        Test-OwnerOnlyAcl -Path $keyFile
    } -Set {
        Set-OwnerOnlyAcl -Path $keyFile
    }
}

# ---------------------------------------------------------------------------
# Item: karakeep-launcher
# ---------------------------------------------------------------------------

function Invoke-KarakeepLauncherItem {
    <#
    .SYNOPSIS
        Install the repo's MCP launcher to a stable per-user path.

    .DESCRIPTION
        The MCP registration must not name a repo checkout: moving or renaming
        the clone would break every Claude session. So the launcher is copied
        to %LOCALAPPDATA%, and drift is a SHA-256 mismatch against the repo
        copy -- an edit on either side comes back as "not converged".

        This is the only item that needs to know where the repo is, which is
        why it takes -DesktopRoot. Invoke-DesktopConverge.ps1 supplies its own
        $PSScriptRoot to any handler declaring that parameter.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$DesktopRoot
    )

    $launcherPath = Expand-ConvergePath $Config.LauncherPath
    $launcherDir = Split-Path -Parent $launcherPath
    $sourcePath = Join-Path $DesktopRoot $Config.LauncherSource
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Launcher source not found: $sourcePath"
    }
    $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash

    Invoke-ConvergeStep -Item 'karakeep-launcher' -Name "$launcherPath matches the repo copy" -WhatIf:$WhatIfPreference -Test {
        if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) { return $false }
        return ((Get-FileHash -LiteralPath $launcherPath -Algorithm SHA256).Hash -eq $sourceHash)
    } -Set {
        if (-not (Test-Path -LiteralPath $launcherDir -PathType Container)) {
            New-Item -ItemType Directory -Path $launcherDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $sourcePath -Destination $launcherPath -Force
    }
}

# ---------------------------------------------------------------------------
# Item: karakeep-claude-code
# ---------------------------------------------------------------------------

function Invoke-KarakeepClaudeCodeItem {
    <#
    .SYNOPSIS
        Register (or re-point) the user-scope Claude Code MCP server.

    .DESCRIPTION
        `claude mcp add` is not idempotent -- it fails when the name already
        exists -- so the step is: read the current registration, and if it is
        missing or does not already name this launcher, this API address and
        this pinned package spec, remove and re-add it. Including the spec in
        the check is what makes a version bump in desktop.psd1 read as drift.

        As with the OpenMessage registration, drift detection is a substring
        check over `claude mcp get` output rather than a parse of Claude's own
        config file: that file's shape is an internal detail of the CLI, its
        printed output is the documented surface. The trade-off is the same --
        a registration that merely reorders arguments would read as converged.

        The command is the bare name `pwsh`, resolved by Claude Code on PATH.
        Pinning an absolute path would break on a PowerShell upgrade that
        moves the install directory.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][hashtable]$Config)

    $name = $Config.McpServerName
    $launcherPath = Expand-ConvergePath $Config.LauncherPath
    $packageSpec = Get-KarakeepPackageSpec -Config $Config
    $launchArgs = Get-KarakeepLaunchArgument -Config $Config

    $claude = Get-Command -Name 'claude' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $claude) {
        throw "The 'claude' CLI is not on PATH. Install Claude Code, or drop this item from the run with -Item."
    }

    Invoke-ConvergeStep -Item 'karakeep-claude-code' -Name "Claude Code user MCP '$name' runs the pinned launcher" -WhatIf:$WhatIfPreference -Test {
        $got = Invoke-NativeCapture -FilePath $claude.Source -Arguments @('mcp', 'get', $name)
        if ($got.ExitCode -ne 0) { return $false }
        return ($got.Output -like "*$launcherPath*") -and
        ($got.Output -like "*$($Config.ApiAddr)*") -and
        ($got.Output -like "*$packageSpec*")
    } -Set {
        # Ignore the exit code: "not found" is the common and fine case.
        [void](Invoke-NativeCapture -FilePath $claude.Source -Arguments @('mcp', 'remove', $name, '--scope', 'user'))
        $add = Invoke-NativeCapture -FilePath $claude.Source -Arguments (
            @('mcp', 'add', '--scope', 'user', $name, '--', 'pwsh') + $launchArgs)
        if ($add.ExitCode -ne 0) {
            throw "claude mcp add failed (exit $($add.ExitCode)): $($add.Output)"
        }
        Write-ConvergeLog -Level info -Message 'restart Claude Code for this to take effect'
    }
}

Export-ModuleMember -Function @(
    'Invoke-KarakeepApiKeyItem'
    'Invoke-KarakeepLauncherItem'
    'Invoke-KarakeepClaudeCodeItem'
    'Get-KarakeepLaunchArgument'
)
