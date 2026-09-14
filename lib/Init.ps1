# Init: first-run workspace creation and the no-BASE escape hatch.
#
# Init is the only command that creates a workspace, so it is the only place
# that may turn REMOTE or an existing tree into trusted BASE. Every path here
# is GET-only: nothing in this file mutates Studio.
#
# Callers must load Paths.ps1, Ignore.ps1, Hashing.ps1, Workspace.ps1,
# RemoteApi.ps1, and Snapshot.ps1 first.

function Get-RundotSyncInitAllowedRootMetadata {
    # The only top-level entries an otherwise-empty destination may contain.
    # These are not project content, so promoting REMOTE over them is safe.
    return @('.git', '.gitignore')
}

function Get-RundotSyncInitUnexpectedEntries {
    param(
        [Parameter(Mandatory)]
        [string]$LocalDir
    )

    $allowed = Get-RundotSyncInitAllowedRootMetadata
    $unexpected = New-Object 'System.Collections.Generic.List[string]'

    if (-not (Test-Path -LiteralPath $LocalDir -PathType Container)) {
        return $unexpected.ToArray()
    }

    foreach ($item in @(Get-ChildItem -LiteralPath $LocalDir -Force)) {
        $name = $item.Name

        # A leftover .rundot-sync from a failed or interrupted attempt is
        # tolerated: it holds no BASE, so a re-run needs no manual cleanup.
        if ([string]::Equals($name, '.rundot-sync', [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $isAllowed = $false
        foreach ($allowedName in $allowed) {
            if ([string]::Equals($name, $allowedName, [System.StringComparison]::OrdinalIgnoreCase)) {
                $isAllowed = $true
                break
            }
        }

        if (-not $isAllowed) {
            $unexpected.Add($name)
        }
    }

    return $unexpected.ToArray()
}

function Assert-RundotSyncInitDestination {
    param(
        [Parameter(Mandatory)]
        [string]$LocalDir
    )

    if (Test-Path -LiteralPath $LocalDir -PathType Leaf) {
        throw [System.InvalidOperationException]::new(
            "Init destination '$LocalDir' is a file, not a folder."
        )
    }

    if (-not (Test-Path -LiteralPath $LocalDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null
    }

    # Reject a redirected destination root before anything is written into it.
    # Promoting through a junction would place the project outside LocalDir.
    $rootInfo = New-Object System.IO.DirectoryInfo ([System.IO.Path]::GetFullPath($LocalDir))
    if (Test-UnsafeSyncFileAttributes -Attributes $rootInfo.Attributes) {
        Assert-UnsafeSyncPath (
            "Init destination '$LocalDir' is a reparse point, symlink, or cloud placeholder."
        )
    }

    $basePath = Get-BaseManifestPath -WorkspaceRoot $LocalDir
    if (Test-Path -LiteralPath $basePath -PathType Leaf) {
        throw [System.InvalidOperationException]::new(
            "Init destination already has a BASE manifest:`n  $basePath`n`n" +
            "This workspace is already initialized. Re-running FromRemote would " +
            "discard its verified shared state.`n`n" +
            "To attach sync metadata to this existing tree instead, use -InitMode Adopt."
        )
    }

    $unexpected = @(Get-RundotSyncInitUnexpectedEntries -LocalDir $LocalDir)
    if ($unexpected.Count -gt 0) {
        $listed = ($unexpected | ForEach-Object { "  $_" }) -join "`n"
        throw [System.InvalidOperationException]::new(
            "Init -InitMode FromRemote requires an empty destination.`n" +
            "Only .git and .gitignore are allowed; found unexpected entries:`n" +
            "$listed`n`n" +
            "Refusing so no existing file is overwritten.`n" +
            "To attach sync metadata to this existing tree instead, use -InitMode Adopt."
        )
    }
}
