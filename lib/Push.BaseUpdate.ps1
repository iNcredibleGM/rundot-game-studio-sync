# Push.BaseUpdate.ps1 - Verified BASE update.
#
# Part of the Push split (#70). Loaded by lib/Push.ps1; do not dot-source
# directly. Function bodies are unchanged from the original lib/Push.ps1.

function New-RundotSyncPushBaseFiles {
    param(
        $BaseFiles,
        [object[]]$AppliedLocals,

        [AllowNull()]
        [string[]]$DeletedPaths
    )

    $files = Copy-SyncMapToHashtable -Map $BaseFiles

    foreach ($applied in @($AppliedLocals)) {
        if ($null -eq $applied) {
            continue
        }

        $files[[string]$applied.Path] = [pscustomobject]@{
            Sha256            = [string]$applied.Sha256
            Size              = $applied.Size
            LocalDetectedKind = [string]$applied.LocalDetectedKind
            LineEnding        = $applied.LineEnding
            HasBom            = [bool]$applied.HasBom
        }
    }

    # A deleted path is dropped from BASE, not tombstoned. The path is now gone
    # from both LOCAL and REMOTE, so a later identical re-create in Studio
    # classifies as a download rather than another delete candidate.
    foreach ($deletedPath in @($DeletedPaths)) {
        if ([string]::IsNullOrEmpty([string]$deletedPath)) {
            continue
        }

        if ($files.ContainsKey([string]$deletedPath)) {
            [void]$files.Remove([string]$deletedPath)
        }
    }

    return $files
}

function Assert-SyncPushBaseUpdatePreconditions {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [object[]]$AppliedActions
    )

    foreach ($action in @($AppliedActions | Where-Object { $null -ne $_ })) {
        $path = [string]$action.Path
        $full = ConvertTo-LocalFullPath -WorkspaceRoot $WorkspaceRoot -CanonicalPath $path

        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw [System.InvalidOperationException]::new(
                "Refusing to update BASE: '$path' is not present in LOCAL."
            )
        }

        $identity = Get-LocalFileIdentity -LiteralPath $full
        if (-not (Test-SyncHashEqual `
                -LeftSha256 $identity.Sha256 `
                -RightSha256 ([string]$action.LocalSha256))) {
            throw [System.InvalidOperationException]::new(
                "Refusing to update BASE: '$path' no longer matches the published content hash."
            )
        }
    }
}

function Update-RundotSyncBaseAfterPush {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [object[]]$AppliedActions,

        [object[]]$AppliedLocals,

        [AllowNull()]
        [string[]]$DeletedPaths,

        $BaseFiles
    )

    Assert-SyncPushBaseUpdatePreconditions `
        -WorkspaceRoot $WorkspaceRoot `
        -AppliedActions $AppliedActions

    $files = New-RundotSyncPushBaseFiles `
        -BaseFiles $BaseFiles `
        -AppliedLocals $AppliedLocals `
        -DeletedPaths $DeletedPaths

    Save-BaseManifest `
        -WorkspaceRoot $WorkspaceRoot `
        -ProjectId $ProjectId `
        -Files $files

    return $files
}
