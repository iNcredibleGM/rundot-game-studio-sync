# BASE workspace layout, ownership, and atomic manifest I/O.
# Behavior is defined by tests/Workspace.Tests.ps1.

function Initialize-RundotSyncLayout {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot
    )
}

function Get-LocalRootFingerprint {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot
    )
}

function Save-BaseManifest {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        $Files
    )
}

function Read-BaseManifest {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot
    )
}

function Assert-BaseOwnership {
    param(
        [Parameter(Mandatory)]
        $Base,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [string]$WorkspaceRoot
    )
}
