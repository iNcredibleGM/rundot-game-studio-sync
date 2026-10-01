# Push.Journal.ps1 - Apply-phase failure handling, verified BASE move, and journal.
#
# Part of the Push split (#70). Loaded by lib/Push.ps1; do not dot-source
# directly. The apply phase journals a failed write before rethrowing; the
# BASE/journal step moves BASE only for verified paths and records the run.

function Invoke-SyncPushApplyPhase {
    # Run the selected apply path. A failure journals what was written and
    # rethrows, so the caller never updates BASE after a partial write.
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        $Resolution,
        $Artifact,
        $Selection,
        [string]$PlanId,
        [string]$BackupSetPath,
        [string]$BackupSetName,
        $Actions,
        $CreateActions,
        $BinaryActions,
        $DeleteActions,
        [bool]$LocalWins,
        $LiveLocalManifest,
        [scriptblock]$GetRemoteFile = $null,
        [scriptblock]$PutRemoteFile = $null,
        [scriptblock]$DeleteRemoteFile = $null,
        [scriptblock]$GetRemoteFileList = $null
    )

    $refusedActions = @()
    $hadRefusals = $false

    try {
        if ($LocalWins) {
            $applyResult = Invoke-RundotSyncLocalWinsApply `
                -WorkspaceRoot $WorkspaceRoot `
                -Actions $Actions `
                -CreateActions $CreateActions `
                -BinaryActions $BinaryActions `
                -Artifact $Artifact `
                -Resolution $Resolution `
                -DeleteActions $DeleteActions `
                -StudioOrigin $StudioOrigin `
                -ProjectId $ProjectId `
                -Headers $Headers `
                -BackupSetPath $BackupSetPath `
                -GetRemoteFile $GetRemoteFile `
                -PutRemoteFile $PutRemoteFile `
                -DeleteRemoteFile $DeleteRemoteFile `
                -GetRemoteFileList $GetRemoteFileList `
                -LiveLocalManifest $LiveLocalManifest
            $refusedActions = @($applyResult.Refused)
            $hadRefusals = ($refusedActions.Count -gt 0)
        }
        else {
            $applyResult = Invoke-RundotSyncPushApply `
                -WorkspaceRoot $WorkspaceRoot `
                -Actions $Actions `
                -CreateActions $CreateActions `
                -BinaryActions $BinaryActions `
                -Artifact $Artifact `
                -Resolution $Resolution `
                -DeleteActions $DeleteActions `
                -StudioOrigin $StudioOrigin `
                -ProjectId $ProjectId `
                -Headers $Headers `
                -BackupSetPath $BackupSetPath `
                -GetRemoteFile $GetRemoteFile `
                -PutRemoteFile $PutRemoteFile `
                -DeleteRemoteFile $DeleteRemoteFile `
                -GetRemoteFileList $GetRemoteFileList `
                -LiveLocalManifest $LiveLocalManifest
        }
    }
    catch {
        $applyError = $_.Exception
        $appliedBeforeFailure = 0
        if ($applyError.Data.Contains('PushAppliedCount')) {
            $appliedBeforeFailure = [int]$applyError.Data['PushAppliedCount']
        }
        $deletedBeforeFailure = 0
        if ($applyError.Data.Contains('PushDeletedCount')) {
            $deletedBeforeFailure = [int]$applyError.Data['PushDeletedCount']
        }
        $createdBeforeFailure = 0
        if ($applyError.Data.Contains('PushCreatedCount')) {
            $createdBeforeFailure = [int]$applyError.Data['PushCreatedCount']
        }

        try {
            Add-RundotSyncJournalRecord `
                -WorkspaceRoot $WorkspaceRoot `
                -Event 'push' `
                -Record @{
                    status      = 'failed'
                    projectId   = $ProjectId
                    planId      = $PlanId
                    backupSet   = $BackupSetName
                    applied     = $appliedBeforeFailure
                    overwritten = $appliedBeforeFailure
                    created     = $createdBeforeFailure
                    deleted     = $deletedBeforeFailure
                    skipped     = @($Selection.Excluded).Count
                    baseUpdated = $false
                    reason      = 'Push failed while writing REMOTE. BASE was not updated. The backup set holds the previous remote bytes.'
                } | Out-Null
        }
        catch {
            # Best effort.
        }

        throw
    }

    return [pscustomobject]@{
        ApplyResult    = $applyResult
        RefusedActions = @($refusedActions)
        HadRefusals    = $hadRefusals
    }
}

function Update-SyncPushBase {
    # Move BASE only for the paths whose published bytes were verified.
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        $Resolution,
        $ApplyResult
    )

    $baseFiles = $null
    if ($Resolution.Base.PSObject.Properties['files']) {
        $baseFiles = $Resolution.Base.files
    }

    $deletedPaths = @($ApplyResult.DeletedActions | ForEach-Object { [string]$_.Path })

    $baseUpdateActions = @($ApplyResult.AppliedActions) + @($ApplyResult.CreatedActions) + @($ApplyResult.BinaryActions)
    $verifiedWriteCount = $ApplyResult.AppliedActions.Count `
        + $ApplyResult.CreatedActions.Count `
        + $ApplyResult.BinaryActions.Count `
        + $ApplyResult.DeletedActions.Count

    if ($verifiedWriteCount -le 0) {
        return $false
    }

    Update-RundotSyncBaseAfterPush `
        -WorkspaceRoot $WorkspaceRoot `
        -ProjectId $ProjectId `
        -AppliedActions $baseUpdateActions `
        -AppliedLocals $ApplyResult.AppliedLocals `
        -DeletedPaths $deletedPaths `
        -BaseFiles $baseFiles | Out-Null

    return $true
}

function Write-SyncPushJournalRecords {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [string]$PlanId,

        [Parameter(Mandatory)]
        [string]$BackupSetName,

        $Selection,
        $ApplyResult,
        [object[]]$RefusedActions,
        [bool]$HadRefusals,
        [bool]$BaseUpdated
    )

    $journalStatus = 'success'
    $journalReason = $null
    if ($HadRefusals) {
        $journalStatus = 'failed'
        if ($BaseUpdated) {
            $journalReason = (
                '{0} path(s) refused after confirmation; BASE updated only for verified paths.' -f $RefusedActions.Count
            )
        }
        else {
            $journalReason = (
                '{0} path(s) refused after confirmation; BASE was not updated.' -f $RefusedActions.Count
            )
        }
    }

    $journalRecord = @{
        status      = $journalStatus
        projectId   = $ProjectId
        planId      = $PlanId
        backupSet   = $BackupSetName
        applied     = $ApplyResult.Applied
        overwritten = $ApplyResult.Applied
        created     = $ApplyResult.Created
        deleted     = $ApplyResult.Deleted
        skipped     = @($Selection.Excluded).Count
        baseUpdated = $BaseUpdated
    }
    if (-not [string]::IsNullOrEmpty($journalReason)) {
        $journalRecord.reason = $journalReason
    }

    Add-RundotSyncJournalRecord `
        -WorkspaceRoot $WorkspaceRoot `
        -Event 'push' `
        -Record $journalRecord | Out-Null

    foreach ($action in @($ApplyResult.AppliedActions)) {
        Add-RundotSyncJournalRecord `
            -WorkspaceRoot $WorkspaceRoot `
            -Event 'push-backup' `
            -Record @{
                status    = 'success'
                projectId = $ProjectId
                planId    = $PlanId
                backupSet = $BackupSetName
                path      = [string]$action.Path
            } | Out-Null
    }

    foreach ($action in @($ApplyResult.CreatedActions)) {
        Add-RundotSyncJournalRecord `
            -WorkspaceRoot $WorkspaceRoot `
            -Event 'push-create' `
            -Record @{
                status    = 'success'
                projectId = $ProjectId
                planId    = $PlanId
                backupSet = $BackupSetName
                path      = [string]$action.Path
            } | Out-Null
    }

    foreach ($action in @($ApplyResult.BinaryActions | Where-Object { [string]$_.Mode -eq 'replace' })) {
        Add-RundotSyncJournalRecord `
            -WorkspaceRoot $WorkspaceRoot `
            -Event 'push-backup' `
            -Record @{
                status    = 'success'
                projectId = $ProjectId
                planId    = $PlanId
                backupSet = $BackupSetName
                path      = [string]$action.Path
            } | Out-Null
    }

    foreach ($action in @($ApplyResult.BinaryActions)) {
        Add-RundotSyncJournalRecord `
            -WorkspaceRoot $WorkspaceRoot `
            -Event 'push-binary' `
            -Record @{
                status    = 'success'
                projectId = $ProjectId
                planId    = $PlanId
                backupSet = $BackupSetName
                path      = [string]$action.Path
            } | Out-Null
    }

    foreach ($action in @($ApplyResult.DeletedActions)) {
        Add-RundotSyncJournalRecord `
            -WorkspaceRoot $WorkspaceRoot `
            -Event 'push-delete' `
            -Record @{
                status    = 'success'
                projectId = $ProjectId
                planId    = $PlanId
                backupSet = $BackupSetName
                path      = [string]$action.Path
            } | Out-Null
    }
}

function Invoke-SyncPushPublishPhase {
    # Create the backup set, run the selected apply path, move BASE for
    # verified paths, journal, and prune expired backup sets.
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        $Resolution,
        $Artifact,
        $Selection,
        [string]$PlanId,
        $Actions,
        $CreateActions,
        $BinaryActions,
        $DeleteActions,
        [bool]$LocalWins,
        $LiveLocalManifest,
        [scriptblock]$GetRemoteFile = $null,
        [scriptblock]$PutRemoteFile = $null,
        [scriptblock]$DeleteRemoteFile = $null,
        [scriptblock]$GetRemoteFileList = $null
    )

    $backupSet = New-RundotSyncBackupSet -WorkspaceRoot $WorkspaceRoot

    $applyPhase = Invoke-SyncPushApplyPhase `
        -WorkspaceRoot $WorkspaceRoot `
        -ProjectId $ProjectId `
        -StudioOrigin $StudioOrigin `
        -Headers $Headers `
        -Resolution $Resolution `
        -Artifact $Artifact `
        -Selection $Selection `
        -PlanId $PlanId `
        -BackupSetPath ([string]$backupSet.Path) `
        -BackupSetName ([string]$backupSet.Name) `
        -Actions $Actions `
        -CreateActions $CreateActions `
        -BinaryActions $BinaryActions `
        -DeleteActions $DeleteActions `
        -LocalWins $LocalWins `
        -LiveLocalManifest $LiveLocalManifest `
        -GetRemoteFile $GetRemoteFile `
        -PutRemoteFile $PutRemoteFile `
        -DeleteRemoteFile $DeleteRemoteFile `
        -GetRemoteFileList $GetRemoteFileList

    $applyResult = $applyPhase.ApplyResult
    $refusedActions = @($applyPhase.RefusedActions)
    $hadRefusals = [bool]$applyPhase.HadRefusals

    $baseUpdated = Update-SyncPushBaseAndJournal `
        -WorkspaceRoot $WorkspaceRoot `
        -ProjectId $ProjectId `
        -PlanId $PlanId `
        -BackupSetName ([string]$backupSet.Name) `
        -Resolution $Resolution `
        -Selection $Selection `
        -ApplyResult $applyResult `
        -RefusedActions $refusedActions `
        -HadRefusals $hadRefusals

    try {
        [void](Remove-RundotSyncExpiredBackupSets `
            -WorkspaceRoot $WorkspaceRoot `
            -KeepName ([string]$backupSet.Name))
    }
    catch {
        # Retention is best effort.
    }

    return [pscustomobject]@{
        BackupSet      = $backupSet
        ApplyResult    = $applyResult
        RefusedActions = @($refusedActions)
        HadRefusals    = $hadRefusals
        BaseUpdated    = $baseUpdated
    }
}

function Update-SyncPushBaseAndJournal {
    # Move BASE for verified paths, then journal the run. A failure here
    # journals the applied-but-unverified state and rethrows.
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [string]$PlanId,

        [Parameter(Mandatory)]
        [string]$BackupSetName,

        $Resolution,
        $Selection,
        $ApplyResult,
        [object[]]$RefusedActions,
        [bool]$HadRefusals
    )

    try {
        $baseUpdated = Update-SyncPushBase `
            -WorkspaceRoot $WorkspaceRoot `
            -ProjectId $ProjectId `
            -Resolution $Resolution `
            -ApplyResult $ApplyResult

        Write-SyncPushJournalRecords `
            -WorkspaceRoot $WorkspaceRoot `
            -ProjectId $ProjectId `
            -PlanId $PlanId `
            -BackupSetName $BackupSetName `
            -Selection $Selection `
            -ApplyResult $ApplyResult `
            -RefusedActions $RefusedActions `
            -HadRefusals $HadRefusals `
            -BaseUpdated $baseUpdated
    }
    catch {
        try {
            Add-RundotSyncJournalRecord `
                -WorkspaceRoot $WorkspaceRoot `
                -Event 'push' `
                -Record @{
                    status      = 'failed'
                    projectId   = $ProjectId
                    planId      = $PlanId
                    backupSet   = $BackupSetName
                    applied     = $ApplyResult.Applied
                    overwritten = $ApplyResult.Applied
                    created     = $ApplyResult.Created
                    deleted     = $ApplyResult.Deleted
                    skipped     = @($Selection.Excluded).Count
                    baseUpdated = $false
                    reason      = 'Push applied remote writes, but the verified BASE update did not complete. The previous BASE remains authoritative.'
                } | Out-Null
        }
        catch {
            # Journaling a failure must never mask the failure itself.
        }

        throw
    }

    return $baseUpdated
}
