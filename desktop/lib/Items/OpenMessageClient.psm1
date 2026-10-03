<#
.SYNOPSIS
    Desktop items 1-3: the OpenMessage binary, its control-token file, and the
    two Claude MCP registrations that point at the cluster.

.DESCRIPTION
    Target state (spec section "First managed item"):

      1. C:\tools\openmessage.exe is the pinned fork release, verified against
         that release's SHA256SUMS.
      2. %USERPROFILE%\.config\openmessage\token holds the control token with
         an owner-only ACL, written from the environment at apply time.
      3. Claude Code (user scope) and Claude Desktop both run
         `openmessage mcp-bridge --url <cluster>/mcp --token-file <that file>`.

    The bridge is what keeps the token out of Claude's JSON: it reads the file
    itself and adds the Authorization header, so neither client config ever
    contains a secret.

    Linux counterpart: ansible/playbooks/tasks/openmessage_client.yml. The two
    must describe the same target state; there is no shared implementation.

    Design: docs/superpowers/specs/2026-09-29-desktop-iac-design.md
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# No -Force: Converge.psm1 keeps the run's step results in module scope, and
# -Force would reload it into a second instance with its own empty result
# list, silently emptying the run summary.
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Converge.psm1')

function Get-BridgeArgument {
    <#
    .SYNOPSIS
        The argument vector both Claude clients must launch, in order.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable]$Config)

    @(
        'mcp-bridge'
        '--url'
        $Config.McpUrl
        '--token-file'
        (Expand-ConvergePath $Config.TokenFile)
    )
}

# ---------------------------------------------------------------------------
# Item: openmessage-binary
# ---------------------------------------------------------------------------

function Get-BinaryStamp {
    param([string]$StampPath)
    if (-not (Test-Path -LiteralPath $StampPath -PathType Leaf)) { return $null }
    try { Get-Content -LiteralPath $StampPath -Raw | ConvertFrom-Json }
    catch { return $null }
}

function Invoke-OpenMessageBinaryItem {
    <#
    .SYNOPSIS
        Install the pinned openmessage.exe, verified against the release's
        SHA256SUMS.

    .DESCRIPTION
        The release checksum covers the .zip, not the .exe inside it. So the
        install verifies the archive, extracts it, and records the extracted
        exe's own hash in a stamp file. Drift detection then works in both
        directions: a version bump in desktop.psd1 and a binary someone
        replaced by hand both come back as "not converged".
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][hashtable]$Config)

    $binaryPath = Expand-ConvergePath $Config.BinaryPath
    $stampPath = Expand-ConvergePath $Config.StampPath
    $version = $Config.Version
    $assetUri = "$($Config.ReleaseBaseUrl)/$version/$($Config.Asset)"
    $sumsUri = "$($Config.ReleaseBaseUrl)/$version/$($Config.ChecksumAsset)"

    Invoke-ConvergeStep -Item 'openmessage-binary' -Name "$binaryPath is $version" -WhatIf:$WhatIfPreference -Test {
        if (-not (Test-Path -LiteralPath $binaryPath -PathType Leaf)) { return $false }
        $stamp = Get-BinaryStamp -StampPath $stampPath
        if ($null -eq $stamp) { return $false }
        if ($stamp.Version -ne $version) { return $false }
        $actual = (Get-FileHash -LiteralPath $binaryPath -Algorithm SHA256).Hash
        return ($actual -eq $stamp.BinarySha256)
    } -Set {
        $expected = Get-ReleaseChecksum -SumsUri $sumsUri -AssetName $Config.Asset
        $work = Join-Path ([System.IO.Path]::GetTempPath()) ("openmessage-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        try {
            $zip = Join-Path $work $Config.Asset
            Get-VerifiedDownload -Uri $assetUri -OutFile $zip -Sha256 $expected
            Expand-Archive -LiteralPath $zip -DestinationPath $work -Force

            $extracted = Join-Path $work $Config.AssetMember
            if (-not (Test-Path -LiteralPath $extracted -PathType Leaf)) {
                throw "Archive $($Config.Asset) did not contain $($Config.AssetMember)"
            }

            $parent = Split-Path -Parent $binaryPath
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }

            try {
                Copy-Item -LiteralPath $extracted -Destination $binaryPath -Force
            }
            catch [System.IO.IOException] {
                throw ("Cannot replace ${binaryPath}: the file is in use. Running MCP clients hold it open. " +
                    "Close Claude Code and Claude Desktop sessions (Get-Process openmessage | " +
                    "Select-Object Id, Path shows the holders) and re-run. Original error: $($_.Exception.Message)")
            }

            $stampDir = Split-Path -Parent $stampPath
            if (-not (Test-Path -LiteralPath $stampDir)) {
                New-Item -ItemType Directory -Path $stampDir -Force | Out-Null
            }
            [pscustomobject]@{
                Version      = $version
                Asset        = $Config.Asset
                AssetSha256  = $expected
                BinarySha256 = (Get-FileHash -LiteralPath $binaryPath -Algorithm SHA256).Hash
                InstalledAt  = (Get-Date).ToUniversalTime().ToString('o')
            } | ConvertTo-Json | Set-Content -LiteralPath $stampPath -Encoding utf8
        }
        finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# Item: openmessage-token
# ---------------------------------------------------------------------------

function Invoke-OpenMessageTokenItem {
    <#
    .SYNOPSIS
        Write the control token to a per-user, owner-only file.

    .DESCRIPTION
        The token never comes from this repo. It arrives in
        $env:OPENMESSAGE_CONTROL_TOKEN for the duration of one command, from
        Bitwarden item `openmessage-control-token`:

            fnox exec -- pwsh -File .\Invoke-DesktopConverge.ps1
            # or, without fnox on this machine:
            $env:OPENMESSAGE_CONTROL_TOKEN = (bw get password openmessage-control-token)

        When the variable is absent and the file already holds a token, this
        is a no-op -- which is what makes a routine converge runnable without
        unlocking a vault. When the variable is absent and the file does not
        exist, the item fails (and the rest of the run continues).

        The value is never logged. Drift is detected by comparing SHA-256
        digests, so neither the old nor the new token is ever rendered.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][hashtable]$Config)

    $tokenFile = Expand-ConvergePath $Config.TokenFile
    $tokenDir = Split-Path -Parent $tokenFile
    $supplied = [System.Environment]::GetEnvironmentVariable($Config.TokenEnvVar)
    if ($null -ne $supplied) { $supplied = $supplied.Trim() }

    Invoke-ConvergeStep -Item 'openmessage-token' -Name "$tokenDir exists" -WhatIf:$WhatIfPreference -Test {
        Test-Path -LiteralPath $tokenDir -PathType Container
    } -Set {
        New-Item -ItemType Directory -Path $tokenDir -Force | Out-Null
    }

    Invoke-ConvergeStep -Item 'openmessage-token' -Name 'control token file matches the supplied secret' -WhatIf:$WhatIfPreference -Test {
        if (-not (Test-Path -LiteralPath $tokenFile -PathType Leaf)) { return $false }
        if ([string]::IsNullOrEmpty($supplied)) {
            # Nothing to compare against: an existing non-empty file is
            # accepted as-is rather than treated as drift.
            return ((Get-Item -LiteralPath $tokenFile).Length -gt 0)
        }
        $current = [System.IO.File]::ReadAllText($tokenFile).Trim()
        return ((Get-StringSha256 $current) -eq (Get-StringSha256 $supplied))
    } -Set {
        if ([string]::IsNullOrEmpty($supplied)) {
            throw ("$($Config.TokenEnvVar) is not set and $tokenFile does not exist. " +
                "Supply the token for one command from Bitwarden item 'openmessage-control-token' " +
                "(see the item's help, or desktop/README.md).")
        }
        Write-TextFileNoBom -Path $tokenFile -Content $supplied
    }

    Invoke-ConvergeStep -Item 'openmessage-token' -Name "$tokenFile ACL grants only the current user" -WhatIf:$WhatIfPreference -Test {
        Test-OwnerOnlyAcl -Path $tokenFile
    } -Set {
        Set-OwnerOnlyAcl -Path $tokenFile
    }
}

# ---------------------------------------------------------------------------
# Item: openmessage-claude-code
# ---------------------------------------------------------------------------

function Invoke-OpenMessageClaudeCodeItem {
    <#
    .SYNOPSIS
        Register (or re-point) the user-scope Claude Code MCP server.

    .DESCRIPTION
        `claude mcp add` is not idempotent -- it fails when the name already
        exists -- so the step is: read the current registration, and if it is
        missing or does not already name the bridge, this URL and this token
        file, remove and re-add it.

        Drift detection is a substring check over `claude mcp get` output
        rather than a parse of Claude's own config file. That file's shape is
        an internal detail of the CLI; its printed output is the documented
        surface. The trade-off is that a registration which merely reorders
        the arguments would read as converged -- acceptable, because the only
        thing that writes it is this item.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][hashtable]$Config)

    $name = $Config.McpServerName
    $binaryPath = Expand-ConvergePath $Config.BinaryPath
    $tokenFile = Expand-ConvergePath $Config.TokenFile
    $bridgeArgs = Get-BridgeArgument -Config $Config

    $claude = Get-Command -Name 'claude' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $claude) {
        throw "The 'claude' CLI is not on PATH. Install Claude Code, or drop this item from the run with -Item."
    }

    Invoke-ConvergeStep -Item 'openmessage-claude-code' -Name "Claude Code user MCP '$name' points at the bridge" -WhatIf:$WhatIfPreference -Test {
        $got = Invoke-NativeCapture -FilePath $claude.Source -Arguments @('mcp', 'get', $name)
        if ($got.ExitCode -ne 0) { return $false }
        return ($got.Output -match 'mcp-bridge') -and
        ($got.Output -like "*$($Config.McpUrl)*") -and
        ($got.Output -like "*$tokenFile*")
    } -Set {
        # Ignore the exit code: "not found" is the common and fine case.
        [void](Invoke-NativeCapture -FilePath $claude.Source -Arguments @('mcp', 'remove', $name, '--scope', 'user'))
        $add = Invoke-NativeCapture -FilePath $claude.Source -Arguments (
            @('mcp', 'add', '--scope', 'user', $name, '--', $binaryPath) + $bridgeArgs)
        if ($add.ExitCode -ne 0) {
            throw "claude mcp add failed (exit $($add.ExitCode)): $($add.Output)"
        }
    }
}

# ---------------------------------------------------------------------------
# Item: openmessage-claude-desktop
# ---------------------------------------------------------------------------

function Test-McpEntryMatches {
    param(
        $Entry,
        [string]$Command,
        [string[]]$Arguments
    )
    if ($null -eq $Entry) { return $false }
    if (-not $Entry.ContainsKey('command')) { return $false }
    if ($Entry.command -ne $Command) { return $false }
    if (-not $Entry.ContainsKey('args')) { return $false }
    $current = @($Entry.args)
    if ($current.Count -ne $Arguments.Count) { return $false }
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        if ($current[$i] -ne $Arguments[$i]) { return $false }
    }
    return $true
}

function Invoke-OpenMessageClaudeDesktopItem {
    <#
    .SYNOPSIS
        Merge the bridge registration into claude_desktop_config.json.

    .DESCRIPTION
        Merge, never overwrite: the file holds every other MCP server and any
        other Claude Desktop settings. The existing file is backed up
        alongside itself before any write.

        Claude Desktop needs the bridge for a different reason than Claude
        Code does: its remote connectors run from Anthropic's cloud, which
        cannot reach a tailnet-only host. A local stdio process that dials out
        over the tailnet can.

        Round-tripping through ConvertFrom-Json/ConvertTo-Json does not
        preserve key order or original formatting. Content is preserved; the
        diff against a hand-edited file will be noisy the first time.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][hashtable]$Config)

    $configPath = Expand-ConvergePath $Config.ClaudeDesktopConfig
    $name = $Config.McpServerName
    $binaryPath = Expand-ConvergePath $Config.BinaryPath
    $bridgeArgs = Get-BridgeArgument -Config $Config

    Invoke-ConvergeStep -Item 'openmessage-claude-desktop' -Name "Claude Desktop MCP '$name' points at the bridge" -WhatIf:$WhatIfPreference -Test {
        if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return $false }
        $raw = Get-Content -LiteralPath $configPath -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
        try { $doc = $raw | ConvertFrom-Json -AsHashtable } catch { return $false }
        if ($null -eq $doc -or -not $doc.ContainsKey('mcpServers')) { return $false }
        if (-not $doc.mcpServers.ContainsKey($name)) { return $false }
        Test-McpEntryMatches -Entry $doc.mcpServers[$name] -Command $binaryPath -Arguments $bridgeArgs
    } -Set {
        $dir = Split-Path -Parent $configPath
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        $doc = @{}
        if (Test-Path -LiteralPath $configPath -PathType Leaf) {
            $backup = "$configPath.bak-" + (Get-Date).ToString('yyyy-MM-dd-HHmmss')
            Copy-Item -LiteralPath $configPath -Destination $backup -Force
            Write-ConvergeLog -Level info -Message "backed up existing config to $backup"

            $raw = Get-Content -LiteralPath $configPath -Raw
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                # A malformed config is the operator's to fix: silently
                # replacing it would discard every other MCP server.
                $doc = $raw | ConvertFrom-Json -AsHashtable
            }
        }

        if ($null -eq $doc) { $doc = @{} }
        if (-not $doc.ContainsKey('mcpServers') -or $null -eq $doc['mcpServers']) {
            $doc['mcpServers'] = @{}
        }
        $doc['mcpServers'][$name] = @{
            command = $binaryPath
            args    = $bridgeArgs
        }

        Write-TextFileNoBom -Path $configPath -Content ($doc | ConvertTo-Json -Depth 20)
        Write-ConvergeLog -Level info -Message 'restart Claude Desktop for this to take effect'
    }
}

Export-ModuleMember -Function @(
    'Invoke-OpenMessageBinaryItem'
    'Invoke-OpenMessageTokenItem'
    'Invoke-OpenMessageClaudeCodeItem'
    'Invoke-OpenMessageClaudeDesktopItem'
    'Get-BridgeArgument'
)
