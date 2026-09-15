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
# This file owns three layers:
#
#   1. selection     - which paths Pull may apply, and why the rest are not
#   2. apply/verify  - backed-up, atomic local writes with full rollback
#   3. BASE update   - additive, and only after every write is re-verified
#
# BASE is updated by Update-RundotSyncBaseAfterPull, never by the apply layer.
# The apply layer returns the re-hashed identities it verified, so BASE records
# bytes that were proven on disk rather than bytes that were merely intended.
#
# Callers must load Paths.ps1, Ignore.ps1, Hashing.ps1, Workspace.ps1,
# Manifest.ps1, Snapshot.ps1, Classifier.ps1, Plan.ps1, Backup.ps1, and
# Journal.ps1 first.


# ----------------------------------------------------------------------------
# Selection: the only automatic local write is a clean download
# ----------------------------------------------------------------------------

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


# ==========================================================================
# Apply, verify, and rollback
#
# Pull writes only when it can prove three things: the action is a clean
# download, the local file it replaces still matches the manifest captured
# this run, and the bytes it wrote hash to the remote identity. Every local
# write is backed up first, so any failure can be rolled back exactly.
#
# The apply layer never writes BASE. It returns the re-hashed local identities
# it verified; the caller decides whether to record them.
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

    # Atomic write: tmp in the destination directory, then rename over the
    # destination. A crash must never leave a truncated local file.
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
    #
    # Never writes BASE. On success it returns the verified on-disk identities
    # in -AppliedLocals, which Update-RundotSyncBaseAfterPull consumes.
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
            Applied        = 0
            Overwritten    = 0
            Created        = 0
            Deleted        = 0
            BackupSet      = $null
            BackupSetPath  = $null
            AppliedPaths   = @()
            AppliedActions = @()
            AppliedLocals  = @()
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


# ==========================================================================
# Verified BASE update
#
# BASE records the last verified shared state, so it moves only after the
# apply layer has proven every written byte. The update is additive: existing
# entries are preserved and only applied paths are overlaid, so a deletion
# candidate keeps its entry and no path silently drops out of BASE.
#
# If any required operation failed, the previous BASE remains authoritative:
# nothing here runs, and Save-BaseManifest is never reached.
# ==========================================================================

function New-RundotSyncPullBaseFiles {
    # Merge the re-verified applied identities over the existing BASE entries.
    # Additive on purpose: BASE is not a tombstone log, and Pull does not
    # delete, so an untouched entry must survive exactly as it was.
    param(
        $BaseFiles,
        [object[]]$AppliedLocals
    )

    $files = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)

    if ($BaseFiles -is [System.Collections.IDictionary]) {
        foreach ($key in @($BaseFiles.Keys)) {
            $files[[string]$key] = $BaseFiles[$key]
        }
    }
    elseif ($null -ne $BaseFiles) {
        foreach ($property in $BaseFiles.PSObject.Properties) {
            $files[[string]$property.Name] = $property.Value
        }
    }

    foreach ($applied in @($AppliedLocals)) {
        if ($null -eq $applied) {
            continue
        }

        $files[[string]$applied.Path] = [pscustomobject]@{
            Sha256            = [string]$applied.Sha256
            Size              = $applied.Size
            LocalDetectedKind = [string]$applied.LocalDetectedKind
            LineEnding        = $applied.LineEnding
            HasBom            = $applied.HasBom
        }
    }

    return $files
}

function Assert-SyncPullBaseUpdatePreconditions {
    # The gate in front of the BASE write. It re-reads LOCAL and requires every
    # applied path to still match REMOTE, so BASE can only ever describe bytes
    # that are present and verified right now.
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [object[]]$AppliedActions
    )

    $actionRows = @($AppliedActions | Where-Object { $null -ne $_ })

    foreach ($action in $actionRows) {
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
                -RightSha256 ([string]$action.RemoteSha256))) {
            throw [System.InvalidOperationException]::new(
                "Refusing to update BASE: '$path' no longer matches the remote snapshot."
            )
        }
    }
}

function Update-RundotSyncBaseAfterPull {
    # The only BASE writer for Pull. Call it after a successful apply. It
    # re-verifies every applied path against REMOTE, merges additively, and
    # then replaces BASE atomically. It throws rather than writing a BASE it
    # could not prove, so the previous BASE stays authoritative.
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [object[]]$AppliedActions,

        [object[]]$AppliedLocals,

        $BaseFiles
    )

    Assert-SyncPullBaseUpdatePreconditions `
        -WorkspaceRoot $WorkspaceRoot `
        -AppliedActions $AppliedActions

    $files = New-RundotSyncPullBaseFiles `
        -BaseFiles $BaseFiles `
        -AppliedLocals $AppliedLocals

    Save-BaseManifest `
        -WorkspaceRoot $WorkspaceRoot `
        -ProjectId $ProjectId `
        -Files $files

    return $files
}


# ==========================================================================
# Report and orchestration
#
# Invoke-RundotSyncPull is the single entrypoint the CLI calls. It is the only
# layer that decides whether BASE moves, and the only layer that journals.
#
# Order matters and is the safety property:
#
#   1. select actions from the three-way classification
#   2. confirm overwrites (fail closed when there is no way to ask)
#   3. apply, backing up first and rolling back on any failure
#   4. re-verify, then replace BASE
#   5. journal, then prune old backups (best effort)
#
# A no-op run does none of 2-5: it writes no backup set, no BASE, and no
# journal record, so an up-to-date workspace stays byte-identical.
# ==========================================================================

function Format-SyncPullReport {
    # The human report. One string, no tokens, no file contents.
    param(
        $Selection,

        [object[]]$AppliedActions,

        [int]$Applied = 0,

        [int]$Overwritten = 0,

        [int]$Created = 0,

        [object[]]$Skipped = $null,

        [bool]$Cancelled = $false,

        [bool]$BaseUpdated = $false,

        [string]$BackupRoot = $null,

        [string]$BackupSetPath = $null
    )

    $lines = New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add('RUN Game Studio Sync - Pull')

    if ($Cancelled) {
        [void]$lines.Add('')
        [void]$lines.Add('Pull cancelled. No local files were changed and BASE was not updated.')
        return ([string]::Join("`n", $lines.ToArray()))
    }

    $actionRows = @($AppliedActions)
    $skippedRows = @($Skipped)
    if ($null -eq $Skipped -and $null -ne $Selection) {
        $skippedRows = @($Selection.Excluded)
    }

    if ($actionRows.Count -eq 0) {
        [void]$lines.Add('')
        [void]$lines.Add('Nothing to pull: LOCAL already matches REMOTE for every remote-only change.')
        [void]$lines.Add('BASE was not updated.')
    }
    else {
        [void]$lines.Add('')
        [void]$lines.Add('APPLIED')
        foreach ($action in $actionRows) {
            $kind = 'create'
            if ([bool]$action.IsOverwrite) {
                $kind = 'overwrite'
            }

            [void]$lines.Add(('  {0}  ({1})' -f [string]$action.Path, $kind))
        }
    }

    if ($skippedRows.Count -gt 0) {
        [void]$lines.Add('')
        [void]$lines.Add('SKIPPED')
        foreach ($row in $skippedRows) {
            $reason = ([string]$row.Reason).Replace("`r", ' ').Replace("`n", ' ')
            [void]$lines.Add(('  {0}  [{1}]  {2}' -f [string]$row.Path, [string]$row.Status, $reason))
        }
    }

    [void]$lines.Add('')
    [void]$lines.Add('SUMMARY')
    [void]$lines.Add(('  applied:     {0}' -f $Applied))
    [void]$lines.Add(('  overwritten: {0}' -f $Overwritten))
    [void]$lines.Add(('  created:     {0}' -f $Created))
    [void]$lines.Add(('  skipped:     {0}' -f $skippedRows.Count))
    [void]$lines.Add(('  BASE updated: {0}' -f ([bool]$BaseUpdated).ToString().ToLowerInvariant()))

    if (-not [string]::IsNullOrEmpty($BackupRoot)) {
        [void]$lines.Add('')
        [void]$lines.Add('BACKUPS')
        [void]$lines.Add(('  backup root: {0}' -f $BackupRoot))
        if (-not [string]::IsNullOrEmpty($BackupSetPath)) {
            [void]$lines.Add(('  this run:    {0}' -f $BackupSetPath))
        }
        [void]$lines.Add('  Restore any overwritten file by copying it back from the backup set.')
    }

    [void]$lines.Add('')
    [void]$lines.Add('Pull writes LOCAL only. It never mutates Studio.')
    [void]$lines.Add('WARNING: This tool uses unofficial remote API routes that may change.')

    return ([string]::Join("`n", $lines.ToArray()))
}

function Invoke-RundotSyncPull {
    # Pull entrypoint. Selects clean downloads, confirms any overwrite, applies
    # them with backups, verifies the result, and only then updates BASE.
    #
    # -ConfirmOverwrite is called with the overwrite count and paths and must
    # return $true to proceed. -Force skips that call but never the backup.
    # With overwrites to make and neither -Force nor a confirm callback, this
    # fails closed: it aborts rather than writing without consent.
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        $Resolution,

        $Local,

        $Remote,

        $Snapshot,

        [scriptblock]$ConfirmOverwrite = $null,

        [switch]$Force,

        [string]$BackupSetPath
    )

    $selection = Get-SyncPullSelection `
        -Base (Get-SyncPlanBaseMapFromResolution -Resolution $Resolution) `
        -Local $Local `
        -Remote $Remote

    $actions = @($selection.Actions)
    $overwrites = @(Get-SyncPullOverwriteRows -Actions $actions)
    $backupRoot = Get-RundotSyncBackupRoot -WorkspaceRoot $WorkspaceRoot
    $planId = [string][Guid]::NewGuid()

    # Confirmation before any write. A declined overwrite changes nothing, so
    # it is not journaled as a run.
    if ($overwrites.Count -gt 0 -and -not $Force) {
        if ($null -eq $ConfirmOverwrite) {
            throw [System.InvalidOperationException]::new(
                ("Refusing to pull: {0} existing local file(s) would be overwritten. " -f $overwrites.Count) +
                'Confirm the overwrite, or pass -ForcePull to proceed. ' +
                'A backup is always created first.'
            )
        }

        $confirmed = [bool](& $ConfirmOverwrite $overwrites.Count @($overwrites | ForEach-Object { [string]$_.Path }))
        if (-not $confirmed) {
            return [pscustomobject]@{
                Applied        = 0
                Overwritten    = 0
                Created        = 0
                Deleted        = 0
                Cancelled      = $true
                BaseUpdated    = $false
                BackupSet      = $null
                BackupSetPath  = $null
                BackupSetName  = $null
                BackupRoot     = $null
                Selection      = $selection
                ActionCount    = $actions.Count
                OverwriteCount = $overwrites.Count
                PlanId         = $planId
                Report         = (Format-SyncPullReport `
                    -Selection $selection `
                    -AppliedActions @() `
                    -Cancelled $true)
            }
        }
    }

    # Apply. Any failure rolls back and re-throws, so BASE is never reached.
    try {
        $applyResult = Invoke-RundotSyncPullApply `
            -WorkspaceRoot $WorkspaceRoot `
            -Actions $actions `
            -Local $Local `
            -Remote $Remote `
            -BackupRoot $backupRoot `
            -BackupSetPath $BackupSetPath
    }
    catch {
        $applyError = $_.Exception

        # A failed pull still gets an audit record. It is best effort: a
        # journaling failure must never mask the failure that caused it.
        try {
            Add-RundotSyncJournalRecord `
                -WorkspaceRoot $WorkspaceRoot `
                -Event 'pull' `
                -Record @{
                    status      = 'failed'
                    projectId   = $ProjectId
                    planId      = $planId
                    applied     = 0
                    overwritten = 0
                    created     = 0
                    skipped     = @($selection.Excluded).Count
                    baseUpdated = $false
                    reason      = 'Pull failed while writing LOCAL. Any partial write was rolled back and BASE was not updated.'
                } | Out-Null
        }
        catch {
            # Best effort.
        }

        throw
    }

    $backupSet = $applyResult.BackupSet
    $appliedLocals = @($applyResult.AppliedLocals)
    $appliedActions = @($applyResult.AppliedActions)

    if ($applyResult.Applied -eq 0) {
        # Nothing was written, so nothing is recorded and BASE does not move.
        return [pscustomobject]@{
            Applied        = 0
            Overwritten    = 0
            Created        = 0
            Deleted        = 0
            Cancelled      = $false
            BaseUpdated    = $false
            BackupSet      = $null
            BackupSetPath  = $null
            BackupSetName  = $null
            BackupRoot     = $null
            Selection      = $selection
            ActionCount    = 0
            OverwriteCount = 0
            PlanId         = $planId
            Report         = (Format-SyncPullReport `
                -Selection $selection `
                -AppliedActions @())
        }
    }

    try {
        # Verify and then replace BASE. A failure here is journaled as failed
        # and the previous BASE stays authoritative.
        $liveBase = Read-BaseManifest -WorkspaceRoot $WorkspaceRoot
        $existingBaseFiles = $null
        if ($null -ne $liveBase) {
            $existingBaseFiles = $liveBase.files
        }

        [void](Update-RundotSyncBaseAfterPull `
            -WorkspaceRoot $WorkspaceRoot `
            -ProjectId $ProjectId `
            -AppliedActions $appliedActions `
            -AppliedLocals $appliedLocals `
            -BaseFiles $existingBaseFiles)

        Add-RundotSyncJournalRecord `
            -WorkspaceRoot $WorkspaceRoot `
            -Event 'pull' `
            -Record @{
                status      = 'success'
                projectId   = $ProjectId
                planId      = $planId
                backupSet   = $(if ($null -ne $backupSet) { [string]$backupSet.Name } else { $null })
                applied     = $applyResult.Applied
                overwritten = $applyResult.Overwritten
                created     = $applyResult.Created
                skipped     = @($selection.Excluded).Count
                baseUpdated = $true
            } | Out-Null

        if ($null -ne $backupSet) {
            foreach ($overwrite in $overwrites) {
                Add-RundotSyncJournalRecord `
                    -WorkspaceRoot $WorkspaceRoot `
                    -Event 'pull-backup' `
                    -Record @{
                        status    = 'success'
                        projectId = $ProjectId
                        planId    = $planId
                        backupSet = [string]$backupSet.Name
                        path      = [string]$overwrite.Path
                    } | Out-Null
            }
        }
    }
    catch {
        $baseError = $_.Exception

        try {
            Add-RundotSyncJournalRecord `
                -WorkspaceRoot $WorkspaceRoot `
                -Event 'pull' `
                -Record @{
                    status      = 'failed'
                    projectId   = $ProjectId
                    planId      = $planId
                    applied     = $applyResult.Applied
                    overwritten = $applyResult.Overwritten
                    created     = $applyResult.Created
                    baseUpdated = $false
                    reason      = 'Pull applied local writes, but the verified BASE update did not complete. The previous BASE remains authoritative.'
                } | Out-Null
        }
        catch {
            # Journaling a failure must never mask the failure itself.
        }

        throw
    }

    # Retention is best effort and must never remove the set this run made.
    $retentionError = $null
    try {
        if ($null -ne $backupSet) {
            [void](Remove-RundotSyncExpiredBackupSets `
                -WorkspaceRoot $WorkspaceRoot `
                -KeepName ([string]$backupSet.Name))
        }
    }
    catch {
        $retentionError = $_.Exception
    }

    $report = Format-SyncPullReport `
        -Selection $selection `
        -AppliedActions $appliedActions `
        -Applied $applyResult.Applied `
        -Overwritten $applyResult.Overwritten `
        -Created $applyResult.Created `
        -Skipped @($selection.Excluded) `
        -BaseUpdated $true `
        -BackupRoot $backupRoot `
        -BackupSetPath $applyResult.BackupSetPath

    return [pscustomobject]@{
        Applied        = $applyResult.Applied
        Overwritten    = $applyResult.Overwritten
        Created        = $applyResult.Created
        Deleted        = $applyResult.Deleted
        Cancelled      = $false
        BaseUpdated    = $true
        BackupSet      = $backupSet
        BackupSetPath  = $applyResult.BackupSetPath
        BackupSetName  = $(if ($null -ne $backupSet) { [string]$backupSet.Name } else { $null })
        BackupRoot     = $(if ($null -ne $backupSet) { $backupRoot } else { $null })
        Selection      = $selection
        ActionCount    = $actions.Count
        OverwriteCount = $overwrites.Count
        PlanId         = $planId
        RetentionError = $retentionError
        Report         = $report
    }
}
