<#
    Desired state for the Windows desktop.

    This file is data, not code. Import-PowerShellDataFile refuses anything
    that would execute, which is why paths use %VAR% tokens instead of $env:
    references -- Expand-ConvergePath resolves them at run time. It also keeps
    every real user name out of a public repo.

    Everything a reviewer should have an opinion about (pinned version, URLs,
    paths, service and server names) is here. The logic that acts on it is in
    lib/Items/.

    Design:  docs/superpowers/specs/2026-09-29-desktop-iac-design.md
    Plan:    docs/superpowers/plans/2026-09-29-desktop-iac-openmessage.md
    Linux counterpart: ansible/playbooks/tasks/openmessage_client.yml
#>
@{
    # Schema version for this file. Bump when an item's expected keys change.
    SchemaVersion = 1

    OpenMessage   = @{
        # --- release pin -------------------------------------------------
        # Fork release tag. The same tag's container image is what
        # ansible/helm/openmessage/values.yaml pins by digest; keep them on
        # the same release so the client and the daemon speak the same
        # protocol. Bump both together.
        Version         = 'v0.2.9-remote.1'
        ReleaseBaseUrl  = 'https://github.com/Deathnerd/openmessage/releases/download'
        Asset           = 'openmessage-windows-amd64.zip'
        # Archive holds a single openmessage.exe at its root
        # (scripts/ci/cross-build.sh in the fork).
        AssetMember     = 'openmessage.exe'
        ChecksumAsset   = 'SHA256SUMS'

        # --- installed binary --------------------------------------------
        # C:\tools is already on the machine PATH.
        BinaryPath      = 'C:\tools\openmessage.exe'
        # Records the installed tag plus the extracted exe's own hash, so a
        # swapped binary is drift, not just a missing version bump.
        StampPath       = '%LOCALAPPDATA%\irl-desktop\openmessage-binary.json'

        # --- control token -------------------------------------------------
        # Content comes from $env:OPENMESSAGE_CONTROL_TOKEN at apply time
        # (Bitwarden item `openmessage-control-token`, login password field).
        # Never stored here, never written into a Claude config.
        TokenFile       = '%USERPROFILE%\.config\openmessage\token'
        TokenEnvVar     = 'OPENMESSAGE_CONTROL_TOKEN'

        # --- cluster endpoint ----------------------------------------------
        McpUrl          = 'https://openmessage.lab.infiniteroomlabs.cloud/mcp'
        HealthUrl       = 'https://openmessage.lab.infiniteroomlabs.cloud/healthz'

        # --- MCP client registration ----------------------------------------
        McpServerName   = 'openmessage'
        ClaudeDesktopConfig = '%APPDATA%\Claude\claude_desktop_config.json'

        # --- the local daemon being retired -----------------------------------
        ServiceName     = 'OpenMessage'
        # Left in place as a cold backup when the service is removed; also the
        # source for the one-off data export.
        DataDir         = '%USERPROFILE%\.local\share\openmessage'
        # Copied as one unit: SQLite is in WAL mode, so messages.db alone can
        # be a torn database. -wal/-shm are absent after a clean stop.
        DataFiles       = @(
            'messages.db'
            'messages.db-wal'
            'messages.db-shm'
            'session.json'
        )
        # The only one whose absence means "there is nothing to migrate".
        DataRequired    = @('messages.db', 'session.json')
    }
}
