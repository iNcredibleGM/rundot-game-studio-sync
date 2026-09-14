# Safe Pull: the one command in this milestone that writes LOCAL.
#
# Pull applies exactly one classification: a clean download
# (BASE=A LOCAL=A REMOTE=B). Neither LOCAL nor REMOTE is authoritative, so
# everything else is excluded with a reason and left alone. In particular:
#
#   - a local-only change (A/B/A) is never overwritten by a pull
#   - a conflict (A/B/C) has no safe direction
#   - deleteLocalCandidate (A/A/-) reports and leaves the local file in place
#   - deleteRemoteCandidate (A/-/A), settledAbsent, ignored, and every no-op
#     are report-only
#
# A download that replaces an existing local file is flagged as an overwrite:
# the caller counts those, confirms them, and backs each one up before writing.
#
# This file also owns the apply/verify/rollback path and the verified BASE
# update. Every local write is backed up first and re-hashed afterwards, so a
# partial run can be rolled back and can never leave a BASE that describes
# bytes that were not just verified.
#
# Callers must load Paths.ps1, Ignore.ps1, Hashing.ps1, Workspace.ps1,
# Manifest.ps1, Snapshot.ps1, Classifier.ps1, Plan.ps1, Backup.ps1, and
# Journal.ps1 first.


function Get-SyncPullSelection {
    # Split the three-way classification into the actions Pull may apply and
    # everything else, with a reason. Pure: no filesystem access, no network,
    # and no mutation of any input map.
    param(
        $Base,
        $Local,
        $Remote
    )

    $changes = @(Get-SyncPlanChanges -Base $Base -Local $Local -Remote $Remote)

    $actions = New-Object 'System.Collections.Generic.List[object]'
    $excluded = New-Object 'System.Collections.Generic.List[object]'

    foreach ($change in @($changes)) {
        $path = [string]$change.Path
        $status = [string]$change.Status

        if ($status -ne $script:SyncStatusDownload) {
            $excluded.Add([pscustomobject]@{
                Path       = $path
                Status     = $status
                Reason     = Get-SyncPullExclusionReason -Change $change
                Ignored    = [bool]$change.Ignored
                KindChange = [bool]$change.KindChange
            })
            continue
        }

        $localEntry = Get-SyncMapEntry -Map $Local -Path $path
        $remoteEntry = Get-SyncMapEntry -Map $Remote -Path $path
        $isOverwrite = ($null -ne $localEntry)

        $actions.Add([pscustomobject]@{
            Path              = $path
            Status            = $status
            Kind              = [string](Get-SyncEntryKind -Entry $remoteEntry)
            LocalSha256       = $change.LocalSha256
            RemoteSha256      = $change.RemoteSha256
            RemoteStagingPath = [string](Get-SyncEntryProperty `
                -Entry $remoteEntry `
                -Names @('StagingPath', 'stagingPath'))
            IsOverwrite       = [bool]$isOverwrite
        })
    }

    $actionRows = @()
    if ($actions.Count -gt 0) {
        $actionRows = $actions.ToArray()
    }

    $excludedRows = @()
    if ($excluded.Count -gt 0) {
        $excludedRows = $excluded.ToArray()
    }

    return [pscustomobject]@{
        Actions    = $actionRows
        Excluded   = $excludedRows
        Overwrites = @(Get-SyncPullOverwriteRows -Actions $actionRows)
    }
}

function Get-SyncPullExclusionReason {
    # One reason per non-download status. The wording is a safety surface:
    # a local-only change must read as "Pull will not overwrite this", not as
    # a pending action.
    param($Change)

    $status = [string]$Change.Status

    switch ($status) {
        $script:SyncStatusUpload {
            return 'LOCAL differs from BASE while REMOTE still matches BASE. Pull never overwrites a local change.'
        }
        $script:SyncStatusConflict {
            if ([bool]$Change.KindChange) {
                return $script:SyncKindChangeReason
            }

            return $script:SyncConflictReason
        }
        $script:SyncStatusDeleteLocalCandidate {
            return 'REMOTE no longer has this path while LOCAL still matches BASE. Pull reports it and leaves the local file in place.'
        }
        $script:SyncStatusDeleteRemoteCandidate {
            return 'LOCAL no longer has this path while REMOTE still matches BASE. Pull does not delete remote content.'
        }
        $script:SyncStatusIgnored {
            return $script:SyncIgnoredReason
        }
        $script:SyncStatusUnchanged {
            return 'BASE, LOCAL, and REMOTE all agree, so there is nothing to pull.'
        }
        $script:SyncStatusSynchronizedChange {
            return 'LOCAL and REMOTE already agree on the new content, so there is nothing to pull.'
        }
        $script:SyncStatusSynchronizedAddition {
            return 'LOCAL and REMOTE already agree on this untracked path, so there is nothing to pull.'
        }
        $script:SyncStatusSettledAbsent {
            return 'This path is absent from both LOCAL and REMOTE, so there is nothing to pull.'
        }
    }

    return 'This path is not a clean remote-only change, so Pull does not apply it.'
}

function Get-SyncPullOverwriteRows {
    # The subset of actions that replace an existing local file. This is what
    # the confirmation prompt counts and what the backup set must cover.
    param([object[]]$Actions)

    if ($null -eq $Actions) {
        return @()
    }

    $rows = @($Actions | Where-Object { [bool]$_.IsOverwrite })
    if ($rows.Count -eq 0) {
        return @()
    }

    return $rows
}


# ----------------------------------------------------------------------------
# Apply, verify, and rollback
#
# Order is the safety property. Nothing is written until every action is
# representable, every staged source exists, and every overwrite is still the
# exact file that was scanned. Every overwrite is then backed up before the
# first write. A write is atomic (tmp, verify, replace). Any failure restores
# the backups, removes the files Pull created, prunes the directories Pull
# created, and re-throws, so the caller never records success and BASE is never
# updated.
# ----------------------------------------------------------------------------

function Get-SyncPullDirectorySet {
    # The set of existing directories under the workspace, used to tell a
    # directory Pull created from one that was already there.
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot
    )

    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $root = Get-NormalizedWorkspaceRoot -WorkspaceRoot $WorkspaceRoot

    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        return $set
    }

    foreach ($dir in @(Get-ChildItem -LiteralPath $root -Recurse -Directory -Force -ErrorAction SilentlyContinue)) {
        [void]$set.Add($dir.FullName)
    }

    return $set
}

function Remove-RundotSyncCreatedDirectories {
    # Best-effort cleanup of empty directories that did not exist before the
    # pull. Deepest first, and only when empty, so a directory holding
    # anything else is never removed.
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        $DirectoriesBefore
    )

    $removed = 0
    $root = Get-NormalizedWorkspaceRoot -WorkspaceRoot $WorkspaceRoot

    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        return 0
    }

    $existing = @(Get-ChildItem -LiteralPath $root -Recurse -Directory -Force -ErrorAction SilentlyContinue)
    $ordered = @($existing | Sort-Object -Property { $_.FullName.Length } -Descending)

    foreach ($dir in $ordered) {
        if ($null -ne $DirectoriesBefore -and $DirectoriesBefore.Contains($dir.FullName)) {
            continue
        }

        $children = @(Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue)
        if ($children.Count -gt 0) {
            continue
        }

        try {
            Remove-Item -LiteralPath $dir.FullName -Force -ErrorAction Stop
            $removed++
        }
        catch {
            # Best effort; a stuck directory never fails a rollback.
        }
    }

    return $removed
}

function Assert-SyncPullLocalUnchanged {
    # The concurrent-edit guard. A file that changed between the LOCAL manifest
    # capture and this moment is not the file the plan was computed against, so
    # it is never overwritten. Force does not bypass this: it is not a
    # preference, it is a correctness check.
    param(
        [Parameter(Mandatory)]
        $Action,

        $Local,

        [Parameter(Mandatory)]
        [string]$LocalFullPath
    )

    $path = [string]$Action.Path
    $entry = Get-SyncMapEntry -Map $Local -Path $path

    if ($null -eq $entry) {
        throw [System.InvalidOperationException]::new(
            "Local file '$path' changed since it was scanned: it no longer exists. Refusing to overwrite it."
        )
    }

    if (-not (Test-Path -LiteralPath $LocalFullPath -PathType Leaf)) {
        throw [System.InvalidOperationException]::new(
            "Local file '$path' changed since it was scanned: it is no longer a file. Refusing to overwrite it."
        )
    }

    $current = Get-LocalFileIdentity -LiteralPath $LocalFullPath
    $expected = [string](Get-SyncEntrySha256 -Entry $entry)

    if (-not (Test-SyncHashEqual -LeftSha256 $current.Sha256 -RightSha256 $expected)) {
        throw [System.InvalidOperationException]::new(
            "Local file '$path' changed since it was scanned. Refusing to overwrite it."
        )
    }
}

function Assert-SyncPullStagedSource {
    param(
        [Parameter(Mandatory)]
        $Action
    )

    $staging = [string]$Action.RemoteStagingPath

    if ([string]::IsNullOrEmpty($staging) -or -not (Test-Path -LiteralPath $staging -PathType Leaf)) {
        throw [System.InvalidOperationException]::new(
            "Staged remote content for '$($Action.Path)' is missing. Refusing to pull."
        )
    }
}

function Invoke-RundotSyncPullWriteAction {
    # Write one action's staged remote bytes to its local path, atomically and
    # verified. The destination is either its exact previous content or exactly
    # the verified remote bytes; a partially written destination is impossible.
    param(
        [Parameter(Mandatory)]
        $Action,

        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$LocalFullPath,

        # Accepted so callers (and tests) can pass the remote map through. The
        # action already carries the staged source path, so it is not needed
        # for the write itself.
        $RemoteMap
    )

    $path = [string]$Action.Path

    Assert-SyncPullStagedSource -Action $Action
    $staging = [string]$Action.RemoteStagingPath

    $parent = Split-Path -Parent $LocalFullPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $tmp = $LocalFullPath + '.tmp'
    if (Test-Path -LiteralPath $tmp) {
        Remove-Item -LiteralPath $tmp -Force
    }

    try {
        [System.IO.File]::Copy($staging, $tmp, $true)

        # Verify the bytes that will land, before they land.
        $written = Get-LocalFileIdentity -LiteralPath $tmp
        if (-not (Test-SyncHashEqual `
                -LeftSha256 $written.Sha256 `
                -RightSha256 ([string]$Action.RemoteSha256))) {
            throw [System.InvalidOperationException]::new(
                "Written bytes for '$path' do not match the remote snapshot. Refusing to replace the local file."
            )
        }

        if (Test-Path -LiteralPath $LocalFullPath -PathType Leaf) {
            $replaceBackup = $LocalFullPath + '.pullbak'
            [System.IO.File]::Replace($tmp, $LocalFullPath, $replaceBackup)
            if (Test-Path -LiteralPath $replaceBackup) {
                Remove-Item -LiteralPath $replaceBackup -Force
            }
        }
        else {
            [System.IO.File]::Move($tmp, $LocalFullPath)
        }
    }
    catch {
        if (Test-Path -LiteralPath $tmp) {
            try {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction Stop
            }
            catch {
                # The destination is never the tmp path, so a stuck tmp is not
                # a partial destination. Surface the original failure.
            }
        }

        throw
    }

    return $LocalFullPath
}

function Assert-SyncPullAppliedLocal {
    # Final LOCAL check: every applied path must exist and hash to the remote
    # identity, or the run is rolled back.
    param(
        [object[]]$AppliedActions,

        [Parameter(Mandatory)]
        [string]$WorkspaceRoot
    )

    foreach ($action in @($AppliedActions)) {
        $path = [string]$action.Path
        $full = ConvertTo-LocalFullPath -WorkspaceRoot $WorkspaceRoot -CanonicalPath $path

        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw [System.InvalidOperationException]::new(
                "Post-write verification failed for '$path': the file is missing."
            )
        }

        $identity = Get-LocalFileIdentity -LiteralPath $full
        if (-not (Test-SyncHashEqual `
                -LeftSha256 $identity.Sha256 `
                -RightSha256 ([string]$action.RemoteSha256))) {
            throw [System.InvalidOperationException]::new(
                "Post-write verification failed for '$path': local bytes do not match the remote snapshot."
            )
        }
    }
}

function Invoke-RundotSyncPullRollback {
    # Undo a partially applied pull. Overwritten files come back from the
    # backup set, files Pull created are removed, and directories Pull created
    # are pruned when empty. Best effort throughout: the original failure is
    # what the caller must see, and a rollback that cannot finish still leaves
    # the backup set on disk for manual recovery.
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [object[]]$AppliedActions,

        $BackupSet,

        $DirectoriesBefore
    )

    $restored = 0
    $removed = 0

    foreach ($action in @($AppliedActions)) {
        $path = [string]$action.Path
        $full = ConvertTo-LocalFullPath -WorkspaceRoot $WorkspaceRoot -CanonicalPath $path

        if ([bool]$action.IsOverwrite -and $null -ne $BackupSet) {
            $backupPath = Join-Path $BackupSet.Path ($path.Replace('/', '\'))

            if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                try {
                    Restore-RundotSyncBackupFile -BackupPath $backupPath -DestinationPath $full
                    $restored++
                    continue
                }
                catch {
                    # Fall through: leaving the pulled content is better than
                    # deleting a file that has a backup we could not apply.
                }
            }
        }

        if (Test-Path -LiteralPath $full -PathType Leaf) {
            try {
                Remove-Item -LiteralPath $full -Force -ErrorAction Stop
                $removed++
            }
            catch {
                # Best effort.
            }
        }
    }

    $directoriesRemoved = Remove-RundotSyncCreatedDirectories `
        -WorkspaceRoot $WorkspaceRoot `
        -DirectoriesBefore $DirectoriesBefore

    return [pscustomobject]@{
        Restored           = $restored
        Removed            = $removed
        DirectoriesRemoved = $directoriesRemoved
    }
}

function Invoke-RundotSyncPullApply {
    # Apply the selected clean downloads to LOCAL. Returns counts plus the
    # backup set. Throws on any failure, after rolling back, so the caller
    # never records success and never updates BASE.
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [object[]]$Actions,

        $Local,

        $Remote,

        [string]$BackupRoot
    )

    Initialize-RundotSyncLayout -WorkspaceRoot $WorkspaceRoot

    $actionRows = @($Actions | Where-Object { $null -ne $_ })
    $overwrites = @(Get-SyncPullOverwriteRows -Actions $actionRows)

    if ($actionRows.Count -eq 0) {
        return [pscustomobject]@{
            Applied        = 0
            Overwritten    = 0
            Created        = 0
            BackupSet      = $null
            AppliedActions = @()
        }
    }

    # Pre-flight. No backup set and no write happens until every action is
    # provably safe to apply against the tree as it is right now.
    foreach ($action in $actionRows) {
        Assert-SyncPathRepresentable `
            -WorkspaceRoot $WorkspaceRoot `
            -CanonicalPath ([string]$action.Path)
        Assert-SyncPullStagedSource -Action $action
    }

    foreach ($action in $overwrites) {
        $full = ConvertTo-LocalFullPath `
            -WorkspaceRoot $WorkspaceRoot `
            -CanonicalPath ([string]$action.Path)
        Assert-SyncPullLocalUnchanged -Action $action -Local $Local -LocalFullPath $full
    }

    # Back up every original before the first write. A backup failure aborts
    # here, with nothing overwritten.
    $backupSet = $null
    if ($overwrites.Count -gt 0) {
        $backupSet = New-RundotSyncBackupSet -WorkspaceRoot $WorkspaceRoot

        foreach ($action in $overwrites) {
            $full = ConvertTo-LocalFullPath `
                -WorkspaceRoot $WorkspaceRoot `
                -CanonicalPath ([string]$action.Path)
            $backupPath = Join-Path $backupSet.Path (([string]$action.Path).Replace('/', '\'))
            Copy-RundotSyncBackupFile -SourcePath $full -DestinationPath $backupPath
        }
    }

    $directoriesBefore = Get-SyncPullDirectorySet -WorkspaceRoot $WorkspaceRoot

    $appliedActions = New-Object 'System.Collections.Generic.List[object]'
    $overwritten = 0
    $created = 0

    try {
        foreach ($action in $actionRows) {
            $full = ConvertTo-LocalFullPath `
                -WorkspaceRoot $WorkspaceRoot `
                -CanonicalPath ([string]$action.Path)

            [void](Invoke-RundotSyncPullWriteAction `
                -Action $action `
                -WorkspaceRoot $WorkspaceRoot `
                -LocalFullPath $full `
                -RemoteMap $Remote)

            [void]$appliedActions.Add($action)

            if ([bool]$action.IsOverwrite) {
                $overwritten++
            }
            else {
                $created++
            }
        }

        Assert-SyncPullAppliedLocal `
            -AppliedActions $appliedActions.ToArray() `
            -WorkspaceRoot $WorkspaceRoot
    }
    catch {
        [void](Invoke-RundotSyncPullRollback `
            -WorkspaceRoot $WorkspaceRoot `
            -AppliedActions $appliedActions.ToArray() `
            -BackupSet $backupSet `
            -DirectoriesBefore $directoriesBefore)

        throw
    }

    return [pscustomobject]@{
        Applied        = $appliedActions.Count
        Overwritten    = $overwritten
        Created        = $created
        BackupSet      = $backupSet
        AppliedActions = $appliedActions.ToArray()
    }
}


# ==========================================================================
# Apply, verify, and rollback
#
# Pull writes only when it can prove three things: the action is a clean
# download, the local file it replaces still matches the manifest captured
# this run, and the bytes it wrote hash to the remote identity. Every local
# write is backed up first, so any failure can be rolled back exactly.
# ==========================================================================

function Invoke-RundotSyncPullWriteAction {
    # Write one action's remote bytes to LOCAL, atomically, then re-hash what
    # landed. The re-hash is the proof the caller's BASE update depends on.
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$LocalFullPath,
        [Parameter(Mandatory)]$Action,
        $RemoteMap
    )

    $path = [string]$Action.Path
    $stagingPath = [string]$Action.RemoteStagingPath

    if ([string]::IsNullOrEmpty($stagingPath) -or -not (Test-Path -LiteralPath $stagingPath -PathType Leaf)) {
        throw [System.InvalidOperationException]::new(
            "No staged remote content is available for '$path'."
        )
    }

    # Prefer the staged bytes the snapshot actually verified. Only fall back to
    # the map when an action carries no staging path, so tests can drive this
    # without a snapshot.
    $sourcePath = $stagingPath
    $remoteEntry = Get-SyncMapEntry -Map $RemoteMap -Path $path
    if ($null -ne $remoteEntry) {
        $mapStaging = [string](Get-SyncEntryProperty -Entry $remoteEntry -Names @('StagingPath', 'stagingPath'))
        if (-not [string]::IsNullOrEmpty($mapStaging)) {
            $sourcePath = $mapStaging
        }
    }

    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw [System.InvalidOperationException]::new(
            "Staged remote content for '$path' is missing."
        )
    }

    $expectedSha = [string]$Action.RemoteSha256
    if ([string]::IsNullOrEmpty($expectedSha)) {
        throw [System.InvalidOperationException]::new(
            "Pull action for '$path' has no remote hash to verify against."
        )
    }

    # Atomic write: tmp, then rename over the destination. A crash must never
    # leave a truncated local file.
    $parent = Split-Path -Parent $LocalFullPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $tmp = $LocalFullPath + '.tmp'
    if (Test-Path -LiteralPath $tmp) {
        Remove-Item -LiteralPath $tmp -Force
    }

    try {
        [System.IO.File]::Copy($sourcePath, $tmp, $true)

        if (Test-Path -LiteralPath $LocalFullPath) {
            Remove-Item -LiteralPath $LocalFullPath -Force
        }

        [System.IO.File]::Move($tmp, $LocalFullPath)
    }
    catch {
        if (Test-Path -LiteralPath $tmp) {
            try {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction Stop
            }
            catch {
                # A stuck tmp is not a partial destination.
            }
        }

        throw
    }

    # Verify the bytes now on disk, not the bytes we intended to write.
    $writtenSha = Get-FileSha256Hex -LiteralPath $LocalFullPath
    if (-not [string]::Equals($writtenSha, $expectedSha, [System.StringComparison]::Ordinal)) {
        throw [System.InvalidOperationException]::new(
            "Written bytes for '$path' do not match the remote snapshot hash."
        )
    }

    return $LocalFullPath
}

function Get-SyncPullCreatedDirectories {
    # Directories that had to be created to place a path. Used by rollback to
    # remove only what this pull made, never a pre-existing directory.
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$LocalFullPath
    )

    $created = New-Object 'System.Collections.Generic.List[string]'
    $root = Get-NormalizedWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $parent = Split-Path -Parent $LocalFullPath

    while (-not [string]::IsNullOrEmpty($parent)) {
        if ([string]::Equals($parent, $root, [System.StringComparison]::OrdinalIgnoreCase)) {
            break
        }

        if (Test-Path -LiteralPath $parent) {
            break
        }

        [void]$created.Add($parent)
        $parent = Split-Path -Parent $parent
    }

    if ($created.Count -eq 0) {
        return @()
    }

    return $created.ToArray()
}

function Undo-RundotSyncPullApply {
    # Best effort, in reverse order: put every replaced file back from its
    # backup, delete every file this run created, and prune only directories
    # this run created. A rollback failure must never hide the original error,
    # so the caller keeps the original exception and this only preserves data.
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][object[]]$Applied,
        $BackupSet
    )

    for ($i = $Applied.Count - 1; $i -ge 0; $i--) {
        $row = $Applied[$i]
        $localFullPath = [string]$row.LocalFullPath

        try {
            if ([bool]$row.IsOverwrite) {
                if ($null -ne $BackupSet) {
                    $backupPath = Join-Path $BackupSet.Path ([string]$row.Path).Replace('/', '\')
                    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                        Restore-RundotSyncBackupFile `
                            -BackupPath $backupPath `
                            -DestinationPath $localFullPath
                        continue
                    }
                }

                # No backup means this overwrite never happened; leave it be.
            }
            else {
                if (Test-Path -LiteralPath $localFullPath) {
                    Remove-Item -LiteralPath $localFullPath -Force
                }

                foreach ($directory in @($row.CreatedDirectories)) {
                    if (Test-Path -LiteralPath $directory -PathType Container) {
                        try {
                            Remove-Item -LiteralPath $directory -Force -ErrorAction Stop
                        }
                        catch {
                            # Not empty, or not ours to remove.
                        }
                    }
                }
            }
        }
        catch {
            # A rollback step failing is never allowed to mask the pull error.
        }
    }
}

function Assert-SyncPullLocalUnchanged {
    # The file LOCAL had when this run captured its manifest must still be the
    # file Pull is about to replace. A concurrent edit is a hard abort, and
    # -ForcePull does not bypass it.
    param(
        [Parameter(Mandatory)][string]$Path,
        $LocalEntry,
        [Parameter(Mandatory)][string]$LocalFullPath
    )

    $expectedSha = [string](Get-SyncEntrySha256 -Entry $LocalEntry)
    if ([string]::IsNullOrEmpty($expectedSha)) {
        return
    }

    if (-not (Test-Path -LiteralPath $LocalFullPath -PathType Leaf)) {
        throw [System.InvalidOperationException]::new(
            "Local file for '$Path' disappeared after it was scanned. Aborting without writing."
        )
    }

    $actualSha = Get-FileSha256Hex -LiteralPath $LocalFullPath
    if (-not [string]::Equals($actualSha, $expectedSha, [System.StringComparison]::Ordinal)) {
        throw [System.InvalidOperationException]::new(
            "Local file for '$Path' changed since it was scanned. Aborting so the local edit is not overwritten."
        )
    }
}

function Invoke-RundotSyncPullApply {
    # Apply the selected actions. Backs up first, writes atomically, verifies
    # every written hash, and rolls the whole set back on any failure.
    #
    # -BackupSetPath applies to the whole run: either every action is backed up
    # into it, or none is. Tests may use an isolated path so they never depend
    # on the workspace backup root.
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Actions,
        $Local,
        $Remote,
        [string]$BackupRoot,
        [string]$BackupSetPath
    )

    $actionRows = @($Actions)
    if ($actionRows.Count -eq 0) {
        return [pscustomobject]@{
            Applied          = 0
            Overwritten      = 0
            Created          = 0
            Deleted          = 0
            BackupSet        = $null
            BackupSetPath    = $null
            AppliedPaths     = @()
            AppliedActions   = @()
            AppliedLocals    = @()
        }
    }

    if ([string]::IsNullOrEmpty($BackupRoot)) {
        $BackupRoot = Get-RundotSyncBackupRoot -WorkspaceRoot $WorkspaceRoot
    }

    $overwrites = @(Get-SyncPullOverwriteRows -Actions $actionRows)

    $backupSet = $null
    if (-not [string]::IsNullOrEmpty($BackupSetPath)) {
        New-Item -ItemType Directory -Force -Path $BackupSetPath | Out-Null
        $backupSet = [pscustomobject]@{
            Name      = Split-Path -Leaf $BackupSetPath
            Path      = $BackupSetPath
            Timestamp = [DateTime]::UtcNow
        }
    }
    elseif ($overwrites.Count -gt 0) {
        $backupSet = New-RundotSyncBackupSet -WorkspaceRoot $WorkspaceRoot
    }

    $applied = New-Object 'System.Collections.Generic.List[object]'
    $appliedPaths = New-Object 'System.Collections.Generic.List[string]'
    $appliedLocals = New-Object 'System.Collections.Generic.List[object]'
    $overwrittenCount = 0
    $createdCount = 0

    try {
        # Phase 1: verify every action before touching any file. A path that
        # drifted, cannot be represented, or has no staging source aborts here,
        # before a backup is even made.
        foreach ($action in $actionRows) {
            $path = [string]$action.Path
            Assert-SyncPathRepresentable -WorkspaceRoot $WorkspaceRoot -CanonicalPath $path

            $localFullPath = ConvertTo-LocalFullPath `
                -WorkspaceRoot $WorkspaceRoot `
                -CanonicalPath $path
            $localEntry = Get-SyncMapEntry -Map $Local -Path $path

            if ([bool]$action.IsOverwrite) {
                Assert-SyncPullLocalUnchanged `
                    -Path $path `
                    -LocalEntry $localEntry `
                    -LocalFullPath $localFullPath
            }

            $stagingSource = [string]$action.RemoteStagingPath
            if ([string]::IsNullOrEmpty($stagingSource) -or -not (Test-Path -LiteralPath $stagingSource -PathType Leaf)) {
                throw [System.InvalidOperationException]::new(
                    "No staged remote content is available for '$path'."
                )
            }
        }

        # Phase 2: back up every overwrite. If any backup fails, nothing has
        # been written yet, so abort with the tree untouched.
        if ($null -ne $backupSet) {
            foreach ($overwrite in $overwrites) {
                $path = [string]$overwrite.Path
                $localFullPath = ConvertTo-LocalFullPath `
                    -WorkspaceRoot $WorkspaceRoot `
                    -CanonicalPath $path

                if (-not (Test-Path -LiteralPath $localFullPath -PathType Leaf)) {
                    continue
                }

                $backupPath = Join-Path $backupSet.Path ($path.Replace('/', '\'))
                Copy-RundotSyncBackupFile `
                    -SourcePath $localFullPath `
                    -DestinationPath $backupPath | Out-Null
            }
        }

        # Phase 3: write and verify. Record enough to undo each one exactly.
        foreach ($action in $actionRows) {
            $path = [string]$action.Path
            $localFullPath = ConvertTo-LocalFullPath `
                -WorkspaceRoot $WorkspaceRoot `
                -CanonicalPath $path
            $localEntry = Get-SyncMapEntry -Map $Local -Path $path
            $isOverwrite = [bool]$action.IsOverwrite

            $createdDirectories = @()
            if (-not (Test-Path -LiteralPath $localFullPath)) {
                $createdDirectories = @(Get-SyncPullCreatedDirectories `
                    -WorkspaceRoot $WorkspaceRoot `
                    -LocalFullPath $localFullPath)
            }

            # Record the intended write BEFORE writing. A write or verify
            # failure still changed the destination, so rollback must know
            # about this path; recording it afterwards would leave a written
            # file behind on the failure path.
            $applied.Add([pscustomobject]@{
                Path               = $path
                LocalFullPath      = $localFullPath
                IsOverwrite        = [bool]$isOverwrite
                CreatedDirectories = $createdDirectories
            })

            $written = Invoke-RundotSyncPullWriteAction `
                -WorkspaceRoot $WorkspaceRoot `
                -LocalFullPath $localFullPath `
                -Action $action `
                -RemoteMap $Remote

            $identity = Get-LocalFileIdentity -LiteralPath $written

            [void]$appliedPaths.Add($path)
            [void]$appliedLocals.Add([pscustomobject]@{
                Path              = $path
                Sha256            = $identity.Sha256
                Size              = $identity.Size
                LocalDetectedKind = $identity.LocalDetectedKind
                LineEnding        = $identity.LineEnding
                HasBom            = $identity.HasBom
            })

            if ($isOverwrite) {
                $overwrittenCount++
            }
            else {
                $createdCount++
            }
        }
    }
    catch {
        $originalError = $_.Exception
        $rollbackError = $null

        try {
            Undo-RundotSyncPullApply `
                -WorkspaceRoot $WorkspaceRoot `
                -Applied $applied.ToArray() `
                -BackupSet $backupSet
        }
        catch {
            $rollbackError = $_.Exception
        }

        $suffix = ''
        if ($null -ne $rollbackError) {
            $suffix = "`nA rollback step also failed; inspect the backup set before re-running."
        }

        throw [System.InvalidOperationException]::new(
            ("Pull aborted: {0}{1}" -f [string]$originalError.Message, $suffix),
            $originalError
        )
    }

    return [pscustomobject]@{
        Applied        = $appliedPaths.Count
        Overwritten    = $overwrittenCount
        Created        = $createdCount
        Deleted        = 0
        BackupSet      = $backupSet
        BackupSetPath  = $(if ($null -ne $backupSet) { $backupSet.Path } else { $null })
        AppliedPaths   = @($appliedPaths.ToArray())
        AppliedActions = @($actionRows)
        AppliedLocals  = @($appliedLocals.ToArray())
    }
}
