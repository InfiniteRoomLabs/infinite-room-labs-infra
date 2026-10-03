<#
.SYNOPSIS
    Desktop item 4: retiring the local OpenMessage Windows service, in two
    separately-invokable phases.

.DESCRIPTION
    Exactly one OpenMessage may hold the Google Messages pairing. Two daemons
    on one pairing fight over the session and Google can revoke it, which
    costs a re-pair from the phone. That is why retirement is two phases and
    not one item, and why neither runs by default.

      openmessage-daemon-stop
        Service Stopped, StartupType Manual. Reversible, and the precondition
        for the cluster pod ever starting. A reboot cannot revive the daemon
        behind your back once StartupType is Manual -- which is the actual
        point of touching StartupType at all.

      openmessage-daemon-remove
        sc.exe delete. Irreversible-ish (recreating the service is scripted in
        the fork's runbook, but the pairing is not). Refuses unless the
        cluster endpoint is serving AND its token gate answers 401, and
        unless the service is already Stopped. The data directory is left in
        place as a cold backup; deleting it is a deliberate human act.

    Design: docs/superpowers/specs/2026-09-29-desktop-iac-design.md
    Runbook for the cluster side: ansible/docs/runbooks/openmessage-down.md
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Converge.psm1')

function Get-OpenMessageService {
    param([Parameter(Mandatory)][string]$Name)
    Get-Service -Name $Name -ErrorAction SilentlyContinue
}

function Invoke-OpenMessageDaemonStopItem {
    <#
    .SYNOPSIS
        Stop the local daemon and stop it coming back on reboot.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][hashtable]$Config)

    $name = $Config.ServiceName

    if ($null -eq (Get-OpenMessageService -Name $name)) {
        Write-ConvergeLog -Level ok -Message "service '$name' is not installed -- nothing to stop"
        return
    }

    if (-not (Test-Elevated)) {
        throw "Stopping and reconfiguring the '$name' service needs an elevated pwsh. Re-run as Administrator."
    }

    Invoke-ConvergeStep -Item 'openmessage-daemon-stop' -Name "service '$name' is Stopped" -WhatIf:$WhatIfPreference -Test {
        $svc = Get-OpenMessageService -Name $name
        return ($null -eq $svc -or $svc.Status -eq 'Stopped')
    } -Set {
        # The daemon can take ~10s to exit: libgm waits on an in-flight Google
        # RPC with no deadline. Expected, and no data is lost -- SQLite in WAL
        # mode keeps every committed write across the exit.
        Stop-Service -Name $name
        (Get-OpenMessageService -Name $name).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
    }

    Invoke-ConvergeStep -Item 'openmessage-daemon-stop' -Name "service '$name' StartupType is Manual" -WhatIf:$WhatIfPreference -Test {
        $svc = Get-OpenMessageService -Name $name
        return ($null -eq $svc -or $svc.StartType -eq 'Manual')
    } -Set {
        Set-Service -Name $name -StartupType Manual
    }
}

function Invoke-OpenMessageDaemonRemoveItem {
    <#
    .SYNOPSIS
        Delete the Windows service, but only once the cluster has genuinely
        taken over.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][hashtable]$Config)

    $name = $Config.ServiceName
    $dataDir = Expand-ConvergePath $Config.DataDir

    if ($null -eq (Get-OpenMessageService -Name $name)) {
        Write-ConvergeLog -Level ok -Message "service '$name' is not installed -- nothing to remove"
        return
    }

    if (-not (Test-Elevated)) {
        throw "Deleting the '$name' service needs an elevated pwsh. Re-run as Administrator."
    }

    # --- guard rails ------------------------------------------------------
    # Both are checked even under -WhatIf: a dry run that reports "would
    # delete the service" while the replacement is down would be a lie, and
    # this is the step where being wrong costs the pairing.
    $svc = Get-OpenMessageService -Name $name
    if ($svc.Status -ne 'Stopped') {
        throw ("Refusing to remove '$name': the service is $($svc.Status), not Stopped. " +
            "Run the openmessage-daemon-stop item first.")
    }

    Write-ConvergeLog -Level info -Message "checking the cluster endpoint before removing '$name'"
    if (-not (Test-RemoteOpenMessageHealthy -HealthUrl $Config.HealthUrl -McpUrl $Config.McpUrl)) {
        throw ("Refusing to remove '$name': the cluster OpenMessage did not pass its health gate " +
            "($($Config.HealthUrl) must return 200 and $($Config.McpUrl) must return 401). " +
            "While that is true, the local service is still the working fallback. " +
            "Triage: ansible/docs/runbooks/openmessage-down.md")
    }

    Invoke-ConvergeStep -Item 'openmessage-daemon-remove' -Name "service '$name' is removed" -WhatIf:$WhatIfPreference -Test {
        return ($null -eq (Get-OpenMessageService -Name $name))
    } -Set {
        $result = Invoke-NativeCapture -FilePath 'sc.exe' -Arguments @('delete', $name)
        if ($result.ExitCode -ne 0) {
            throw "sc.exe delete $name failed (exit $($result.ExitCode)): $($result.Output)"
        }
        # The Service Control Manager deletes lazily when a handle is still
        # open; give it a moment before the post-Set re-test.
        Start-Sleep -Seconds 2
    }

    Write-ConvergeLog -Level info -Message "data directory left in place as a cold backup: $dataDir"
    Write-ConvergeLog -Level info -Message 'also remove the paired device on the phone only if you are abandoning the pairing entirely'
}

Export-ModuleMember -Function @(
    'Invoke-OpenMessageDaemonStopItem'
    'Invoke-OpenMessageDaemonRemoveItem'
)
