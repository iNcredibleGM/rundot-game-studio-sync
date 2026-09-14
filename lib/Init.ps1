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

# ----------------------------------------------------------------------------
# FromRemote promotion
#
# Order matters: verify the snapshot's own staging, refuse collisions, then
# move, then re-verify what actually landed on disk. BASE is written last, so
# every earlier failure leaves NO BASE rather than a trusted claim about a
# tree we did not just prove.
# ----------------------------------------------------------------------------

function Get-RundotSyncSnapshotFilePaths {
    param($Snapshot)

    if ($null -eq $Snapshot) {
        throw [System.InvalidOperationException]::new("Remote snapshot is missing.")
    }

    if ($Snapshot.Files -isnot [System.Collections.IDictionary]) {
        throw [System.InvalidOperationException]::new(
            "Remote snapshot has no file map to promote."
        )
    }

    return @($Snapshot.Files.Keys)
}

function Get-RundotSyncStagingFileIndex {
    param(
        [Parameter(Mandatory)]
        [string]$StagingRoot
    )

    $index = New-Object 'System.Collections.Generic.Dictionary[string,string]' (
        [System.StringComparer]::Ordinal
    )

    if (-not (Test-Path -LiteralPath $StagingRoot -PathType Container)) {
        return $index
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $StagingRoot -Recurse -Force -File)) {
        $canonical = ConvertTo-CanonicalSyncPathFromLocal `
            -WorkspaceRoot $StagingRoot `
            -FullPath $file.FullName
        $index[$canonical] = $file.FullName
    }

    return $index
}

function Test-RundotSyncStagingIntegrity {
    # Re-hash the staged bytes and confirm staging holds exactly the listed
    # set. A snapshot that disagrees with its own staging must never be
    # promoted, or BASE would describe bytes that were never verified.
    param(
        [Parameter(Mandatory)]
        $Snapshot
    )

    $paths = @(Get-RundotSyncSnapshotFilePaths -Snapshot $Snapshot)
    $stagingRoot = [string]$Snapshot.StagingRoot

    if ([string]::IsNullOrEmpty($stagingRoot)) {
        throw [System.InvalidOperationException]::new(
            "Remote snapshot has no staging folder to promote."
        )
    }

    $staged = Get-RundotSyncStagingFileIndex -StagingRoot $stagingRoot

    foreach ($path in $paths) {
        if (-not $staged.ContainsKey($path)) {
            throw [System.InvalidOperationException]::new(
                "Remote snapshot listed '$path', but it is missing from staging."
            )
        }

        $entry = $Snapshot.Files[$path]
        $stagedPath = $staged[$path]
        $identity = Get-LocalFileIdentity -LiteralPath $stagedPath

        if (
            -not [string]::Equals(
                [string]$identity.Sha256,
                [string](Get-BaseFileEntryProperty -Entry $entry -Names @('Sha256', 'sha256')),
                [System.StringComparison]::Ordinal
            )
        ) {
            throw [System.InvalidOperationException]::new(
                "Snapshot hash and staged bytes do not match for '$path'.`n" +
                "Refusing to promote: the snapshot would not describe this tree."
            )
        }
    }

    foreach ($canonical in @($staged.Keys)) {
        if (-not $Snapshot.Files.Contains($canonical)) {
            throw [System.InvalidOperationException]::new(
                "Staging contains '$canonical', which the remote snapshot does not list."
            )
        }
    }
}

function Test-RundotSyncPromotedMetadataCollision {
    # .git, .gitignore, and .rundot-sync are the only entries Init leaves in
    # place. A remote path under any of them would overwrite local metadata or
    # write into sync state, so refuse instead of clobbering.
    param(
        [Parameter(Mandatory)]
        [string]$LocalDir,

        [Parameter(Mandatory)]
        $Snapshot
    )

    $retained = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in @(Get-RundotSyncInitAllowedRootMetadata)) {
        if (Test-Path -LiteralPath (Join-Path $LocalDir $name)) {
            $retained.Add($name)
        }
    }

    # Sync state is created by the snapshot before promotion, so it is always
    # present by now and always reserved.
    $retained.Add('.rundot-sync')

    foreach ($path in @(Get-RundotSyncSnapshotFilePaths -Snapshot $Snapshot)) {
        $segments = $path.Split(@('/'), [System.StringSplitOptions]::None)
        $first = $segments[0]

        foreach ($name in $retained) {
            if ([string]::Equals($first, $name, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw [System.InvalidOperationException]::new(
                    "Remote path '$path' would overwrite retained metadata '$name' in LocalDir.`n" +
                    "Remove that local metadata, or attach this tree with -InitMode Adopt instead."
                )
            }
        }
    }
}

function Move-RundotSyncStagingTree {
    # Staging lives under LocalDir/.rundot-sync/temp, so a same-volume move is
    # a rename: no partial copies, and nothing to clean up if it fails.
    param(
        [Parameter(Mandatory)]
        [string]$LocalDir,

        [Parameter(Mandatory)]
        [string]$StagingRoot
    )

    $moved = New-Object 'System.Collections.Generic.List[string]'

    if (-not (Test-Path -LiteralPath $StagingRoot -PathType Container)) {
        return $moved.ToArray()
    }

    try {
        foreach ($item in @(Get-ChildItem -LiteralPath $StagingRoot -Force)) {
            $destination = Join-Path $LocalDir $item.Name

            if (Test-Path -LiteralPath $destination) {
                throw [System.InvalidOperationException]::new(
                    "Refusing to overwrite existing path '$destination' while promoting."
                )
            }

            Move-Item -LiteralPath $item.FullName -Destination $destination
            $moved.Add($item.Name)
        }
    }
    catch {
        # A later rename failed. Undo the ones that already happened so the
        # caller never has to reason about a half-promoted tree.
        Undo-RundotSyncStagingMove `
            -LocalDir $LocalDir `
            -StagingRoot $StagingRoot `
            -MovedNames $moved.ToArray()
        throw
    }

    return $moved.ToArray()
}

function Undo-RundotSyncStagingMove {
    # Best effort. If this cannot complete, the caller still must not write
    # BASE; the data is preserved so nothing is lost.
    param(
        [Parameter(Mandatory)]
        [string]$LocalDir,

        [Parameter(Mandatory)]
        [string]$StagingRoot,

        [string[]]$MovedNames
    )

    foreach ($name in @($MovedNames)) {
        $promoted = Join-Path $LocalDir $name
        if (-not (Test-Path -LiteralPath $promoted)) {
            continue
        }

        $restore = Join-Path $StagingRoot $name
        if (Test-Path -LiteralPath $restore) {
            continue
        }

        try {
            Move-Item -LiteralPath $promoted -Destination $restore
        }
        catch {
            # Leave the promoted path in place; it is never recorded in BASE.
        }
    }
}

function Import-RundotRemoteSnapshot {
    param(
        [Parameter(Mandatory)]
        [string]$LocalDir,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        $Snapshot
    )

    $paths = @(Get-RundotSyncSnapshotFilePaths -Snapshot $Snapshot)

    # Defense in depth: a file may have appeared since the pre-flight check.
    Assert-RundotSyncInitDestination -LocalDir $LocalDir

    Test-RundotSyncStagingIntegrity -Snapshot $Snapshot
    Test-RundotSyncPromotedMetadataCollision -LocalDir $LocalDir -Snapshot $Snapshot

    foreach ($path in $paths) {
        Assert-SyncPathRepresentable -WorkspaceRoot $LocalDir -CanonicalPath $path
    }

    $moved = @(Move-RundotSyncStagingTree -LocalDir $LocalDir -StagingRoot $Snapshot.StagingRoot)

    try {
        # Build BASE from the bytes now on disk, re-verifying each against the
        # snapshot. This is the step that makes staging == REMOTE a checked
        # claim rather than an assumption.
        $files = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)
        $lineEndingByName = @{}

        foreach ($path in $paths) {
            $localPath = ConvertTo-LocalFullPath `
                -WorkspaceRoot $LocalDir `
                -CanonicalPath $path
            $identity = Get-LocalFileIdentity -LiteralPath $localPath
            $expected = [string](Get-BaseFileEntryProperty `
                -Entry $Snapshot.Files[$path] `
                -Names @('Sha256', 'sha256'))

            if (-not [string]::Equals($identity.Sha256, $expected, [System.StringComparison]::Ordinal)) {
                throw [System.InvalidOperationException]::new(
                    "Promoted bytes for '$path' do not match the remote snapshot hash."
                )
            }

            $files[$path] = [pscustomobject]@{
                Sha256            = $identity.Sha256
                Size              = $identity.Size
                LocalDetectedKind = $identity.LocalDetectedKind
                LineEnding        = $identity.LineEnding
                HasBom            = $identity.HasBom
            }
        }
    }
    catch {
        Undo-RundotSyncStagingMove `
            -LocalDir $LocalDir `
            -StagingRoot $Snapshot.StagingRoot `
            -MovedNames $moved
        throw
    }

    try {
        Save-BaseManifest `
            -WorkspaceRoot $LocalDir `
            -ProjectId $ProjectId `
            -Files $files
    }
    catch {
        Undo-RundotSyncStagingMove `
            -LocalDir $LocalDir `
            -StagingRoot $Snapshot.StagingRoot `
            -MovedNames $moved
        throw [System.InvalidOperationException]::new(
            "No BASE was written because the BASE manifest could not be saved.`n" +
            "The promoted files were moved back to staging, so LocalDir holds no project files.`n" +
            "Fix the cause and re-run Init.",
            $_.Exception
        )
    }

    Clear-RemoteSnapshotTemp -WorkspaceRoot $LocalDir

    return [pscustomobject]@{
        FileCount  = $files.Count
        StagingRoot = $Snapshot.StagingRoot
    }
}

function Initialize-RundotSyncFromRemote {
    param(
        [Parameter(Mandatory)]
        [string]$LocalDir,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    # Checked before the snapshot, because capturing REMOTE creates
    # .rundot-sync inside LocalDir and would dirty an otherwise empty folder.
    Assert-RundotSyncInitDestination -LocalDir $LocalDir

    $snapshot = Get-StableRemoteSnapshot `
        -WorkspaceRoot $LocalDir `
        -StudioOrigin $StudioOrigin `
        -ProjectId $ProjectId `
        -Headers $Headers

    return Import-RundotRemoteSnapshot `
        -LocalDir $LocalDir `
        -ProjectId $ProjectId `
        -Snapshot $snapshot
}
