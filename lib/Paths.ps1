# Canonical path helpers for sync identity and safety.
# Behavior is defined by tests/Paths.Tests.ps1.

function ConvertTo-CanonicalSyncPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
}

function ConvertTo-CanonicalSyncPathFromLocal {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$FullPath
    )
}

function ConvertTo-LocalFullPath {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$CanonicalPath
    )
}

function Assert-SafeSyncPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
}

function Assert-SafeSyncPathSet {
    param(
        [Parameter(Mandatory)]
        [string[]]$Paths
    )
}

function Assert-SyncPathRepresentable {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$CanonicalPath
    )
}

function Test-UnsafeSyncFileAttributes {
    param(
        [Parameter(Mandatory)]
        $Attributes
    )

    return $false
}

function Assert-LocalWorkspaceTreeSafe {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot
    )
}
