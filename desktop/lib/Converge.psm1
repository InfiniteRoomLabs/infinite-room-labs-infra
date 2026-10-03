<#
.SYNOPSIS
    Shared helpers for the desktop converge.

.DESCRIPTION
    Design: docs/superpowers/specs/2026-09-29-desktop-iac-design.md

    The load-bearing piece here is Invoke-ConvergeStep. Items never call their
    own Set logic directly; they hand a Test/Set pair to this function, which
    runs Test first, skips or reports under -WhatIf, and -- crucially --
    re-runs Test after Set and fails the step if the state did not converge.
    That post-check is what keeps "we hand-rolled idempotency" from being an
    act of faith: an item that lies about its own state fails on the same run
    that introduced the lie.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Step outcomes for the run summary. Module-scoped so every item appends to
# the same list regardless of which module it lives in.
$script:Results = [System.Collections.Generic.List[pscustomobject]]::new()

function Reset-ConvergeState {
    [CmdletBinding()]
    param()
    $script:Results = [System.Collections.Generic.List[pscustomobject]]::new()
}

function Get-ConvergeState {
    [CmdletBinding()]
    param()
    , $script:Results
}

function Write-ConvergeLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('info', 'ok', 'change', 'whatif', 'warn', 'fail')][string]$Level = 'info'
    )
    $colour = switch ($Level) {
        'ok' { 'DarkGray' }
        'change' { 'Green' }
        'whatif' { 'Cyan' }
        'warn' { 'Yellow' }
        'fail' { 'Red' }
        default { 'Gray' }
    }
    Write-Host ("  [{0,-6}] {1}" -f $Level, $Message) -ForegroundColor $colour
}

function Add-ConvergeResult {
    param([string]$Item, [string]$Step, [string]$Outcome, [string]$Detail = '')
    $script:Results.Add([pscustomobject]@{
            Item    = $Item
            Step    = $Step
            Outcome = $Outcome
            Detail  = $Detail
        })
}

function Invoke-ConvergeStep {
    <#
    .SYNOPSIS
        Run one Test/Set pair, honouring -WhatIf, and verify convergence.

    .PARAMETER Test
        Scriptblock returning $true when the desired state already holds.

    .PARAMETER Set
        Scriptblock that makes it hold. Only ever called when Test returned
        $false and -WhatIf is not in effect.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Item,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Test,
        [Parameter(Mandatory)][scriptblock]$Set
    )

    if (& $Test) {
        Write-ConvergeLog -Level ok -Message $Name
        Add-ConvergeResult -Item $Item -Step $Name -Outcome 'ok'
        return
    }

    # Under -WhatIf, ShouldProcess returns $false and emits the standard
    # "What if:" line. The step is reported as a real pending change because
    # Test genuinely failed -- this is not a guess.
    if (-not $PSCmdlet.ShouldProcess($Name, 'converge')) {
        Write-ConvergeLog -Level whatif -Message "$Name -- would change"
        Add-ConvergeResult -Item $Item -Step $Name -Outcome 'would-change'
        return
    }

    & $Set

    if (-not (& $Test)) {
        Add-ConvergeResult -Item $Item -Step $Name -Outcome 'failed' -Detail 'state did not converge after Set'
        throw "Step '$Name' ran but the desired state still does not hold. This is a bug in the item's Test or Set."
    }

    Write-ConvergeLog -Level change -Message "$Name -- changed"
    Add-ConvergeResult -Item $Item -Step $Name -Outcome 'changed'
}

function Expand-ConvergePath {
    <#
    .SYNOPSIS
        Expand %VAR% tokens in a path from desktop.psd1.

    .DESCRIPTION
        desktop.psd1 is read with Import-PowerShellDataFile, which never
        executes code -- so it cannot contain $env: references. Paths are
        written with %USERPROFILE% / %APPDATA% tokens and expanded here. Also
        keeps the data file free of any real user name, which matters because
        this repo is public.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    $expanded = [System.Environment]::ExpandEnvironmentVariables($Path)
    if ($expanded -match '%[A-Za-z_]+%') {
        throw "Path '$Path' still contains an unexpanded environment token after expansion: '$expanded'"
    }
    $expanded
}

function Test-Elevated {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    ([System.Security.Principal.WindowsPrincipal]$identity).IsInRole(
        [System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ReleaseChecksum {
    <#
    .SYNOPSIS
        Look one asset's SHA-256 up in a release's SHA256SUMS file.

    .DESCRIPTION
        The fork's release workflow produces SHA256SUMS with `sha256sum -- *`
        over flat file names, so every line is "<64 hex>  <asset name>".
        Downloaded to a file rather than read from the response body because
        SHA256SUMS has no extension and is served as octet-stream, which
        Invoke-WebRequest may hand back as a byte array.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$SumsUri,
        [Parameter(Mandatory)][string]$AssetName
    )

    $tmp = New-TemporaryFile
    try {
        Invoke-WebRequest -Uri $SumsUri -OutFile $tmp.FullName -MaximumRedirection 5
        foreach ($line in (Get-Content -LiteralPath $tmp.FullName)) {
            $match = [regex]::Match($line.Trim(), '^([0-9a-fA-F]{64})\s+\*?(.+)$')
            if ($match.Success -and $match.Groups[2].Value.Trim() -eq $AssetName) {
                return $match.Groups[1].Value.ToUpperInvariant()
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $tmp.FullName -Force -ErrorAction SilentlyContinue
    }
    throw "No SHA-256 entry for '$AssetName' in $SumsUri"
}

function Get-VerifiedDownload {
    <#
    .SYNOPSIS
        Download a file and refuse to keep it unless it matches the checksum.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [Parameter(Mandatory)][string]$Sha256
    )

    $tmp = New-TemporaryFile
    try {
        Invoke-WebRequest -Uri $Uri -OutFile $tmp.FullName -MaximumRedirection 5
        $actual = (Get-FileHash -LiteralPath $tmp.FullName -Algorithm SHA256).Hash
        if ($actual -ne $Sha256.ToUpperInvariant()) {
            throw "Checksum mismatch for $Uri`n  expected $($Sha256.ToUpperInvariant())`n  got      $actual"
        }
        Move-Item -LiteralPath $tmp.FullName -Destination $OutFile -Force
    }
    finally {
        if (Test-Path -LiteralPath $tmp.FullName) {
            Remove-Item -LiteralPath $tmp.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-CurrentUserSid {
    [CmdletBinding()]
    [OutputType([System.Security.Principal.SecurityIdentifier])]
    param()
    [System.Security.Principal.WindowsIdentity]::GetCurrent().User
}

function Test-OwnerOnlyAcl {
    <#
    .SYNOPSIS
        True when the file's DACL is protected and grants only the current user.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $acl = Get-Acl -LiteralPath $Path
    if (-not $acl.AreAccessRulesProtected) { return $false }

    $me = (Get-CurrentUserSid).Value
    $granted = @(
        $acl.Access | ForEach-Object {
            $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
        } | Sort-Object -Unique
    )
    return ($granted.Count -eq 1 -and $granted[0] -eq $me)
}

function Set-OwnerOnlyAcl {
    <#
    .SYNOPSIS
        Strip inheritance and leave exactly one ACE: the current user, Full.

    .DESCRIPTION
        Administrators and SYSTEM are deliberately not granted. They can still
        take ownership -- that is not a control we can enforce against, and
        pretending otherwise would be theatre -- but every other account on the
        box, including service accounts, loses access.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)

    if (-not $PSCmdlet.ShouldProcess($Path, 'restrict ACL to the current user')) { return }

    $me = Get-CurrentUserSid
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)   # protected, drop inherited ACEs
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }
    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
            $me, 'FullControl', 'None', 'None', 'Allow'))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Write-TextFileNoBom {
    <#
    .SYNOPSIS
        Write text as UTF-8 with no BOM and no added newline.

    .DESCRIPTION
        Matters for the token file: the bridge trims surrounding whitespace but
        not a BOM, so a BOM-prefixed token silently produces a 401 that looks
        like a wrong secret.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Get-StringSha256 {
    <#
    .SYNOPSIS
        SHA-256 of a string, for comparing secrets without ever printing them.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value))
        return [System.BitConverter]::ToString($bytes).Replace('-', '')
    }
    finally { $sha.Dispose() }
}

function Invoke-NativeCapture {
    <#
    .SYNOPSIS
        Run a native command, capture its output, and return the exit code
        instead of throwing.

    .DESCRIPTION
        Several steps here read a non-zero exit as information rather than as
        an error ("is this MCP server registered?" answered by `claude mcp
        get`). PowerShell 7.4 turns native non-zero exits into terminating
        errors when $ErrorActionPreference is Stop, so the preference is
        disabled for the duration of the call -- explicitly, because relying
        on the host's default would make behaviour depend on the pwsh version.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @()
    )

    # The variable does not exist before pwsh 7.3, and StrictMode makes
    # reading an undefined variable fatal -- so probe before touching it.
    $hadPreference = Test-Path -LiteralPath 'Variable:PSNativeCommandUseErrorActionPreference'
    $previous = if ($hadPreference) { $PSNativeCommandUseErrorActionPreference } else { $null }
    try {
        if ($hadPreference) { $PSNativeCommandUseErrorActionPreference = $false }
        $output = & $FilePath @Arguments 2>&1 | Out-String
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = $output
        }
    }
    finally {
        if ($hadPreference) { $PSNativeCommandUseErrorActionPreference = $previous }
    }
}

function Test-RemoteOpenMessageHealthy {
    <#
    .SYNOPSIS
        Is the cluster OpenMessage actually serving, with its token gate up?

    .DESCRIPTION
        Two assertions, both required:
          /healthz  -> 200   the remote daemon is up and reachable from here
          /mcp      -> 401   the bearer-token gate is a gate, not decoration

        A 403 on either means the Traefik IP allowlist or the daemon's Host
        check rejected us -- which is a "you are not where you think you are"
        answer, not a health answer, so it fails the gate too.

        This is the guard on the irreversible half of the daemon retirement.
        It must not be softened into "200 or close enough".
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$HealthUrl,
        [Parameter(Mandatory)][string]$McpUrl,
        [int]$TimeoutSec = 15
    )

    try {
        $health = Invoke-WebRequest -Uri $HealthUrl -Method Get -TimeoutSec $TimeoutSec -SkipHttpErrorCheck
        $mcp = Invoke-WebRequest -Uri $McpUrl -Method Get -TimeoutSec $TimeoutSec -SkipHttpErrorCheck
    }
    catch {
        Write-ConvergeLog -Level warn -Message "cluster endpoint unreachable: $($_.Exception.Message)"
        return $false
    }

    if ($health.StatusCode -ne 200) {
        Write-ConvergeLog -Level warn -Message "$HealthUrl returned $($health.StatusCode), expected 200"
        return $false
    }
    if ($mcp.StatusCode -ne 401) {
        Write-ConvergeLog -Level warn -Message "$McpUrl returned $($mcp.StatusCode), expected 401 (an unauthenticated request must be refused)"
        return $false
    }
    return $true
}

Export-ModuleMember -Function @(
    'Reset-ConvergeState'
    'Get-ConvergeState'
    'Write-ConvergeLog'
    'Invoke-ConvergeStep'
    'Expand-ConvergePath'
    'Test-Elevated'
    'Get-ReleaseChecksum'
    'Get-VerifiedDownload'
    'Get-CurrentUserSid'
    'Test-OwnerOnlyAcl'
    'Set-OwnerOnlyAcl'
    'Write-TextFileNoBom'
    'Get-StringSha256'
    'Invoke-NativeCapture'
    'Test-RemoteOpenMessageHealthy'
)
