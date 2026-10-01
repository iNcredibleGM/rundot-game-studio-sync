# Push.Apply.ps1 - Clean overwrite/create/binary/delete apply path.
#
# Part of the Push split (#70). Loaded by lib/Push.ps1; do not dot-source
# directly. Backs up every path first, then writes. No DELETE runs until every
# backup it depends on has verified, and any failure aborts the whole run.

function New-SyncPushApplyResult {
    param(
        [object[]]$AppliedActions = @(),
        [object[]]$AppliedLocals = @(),
        [object[]]$CreatedActions = @(),
        [object[]]$CreatedLocals = @(),
        [object[]]$BinaryActions = @(),
        [object[]]$BinaryLocals = @(),
        [object[]]$DeletedActions = @(),
        [int]$BinaryCreated = 0,
        [int]$BinaryReplaced = 0,
        $BackupSet = $null,
        [string]$BackupSetPath = $null
    )

    return [pscustomobject]@{
        AppliedActions = @($AppliedActions)
        AppliedLocals  = @($AppliedLocals)
        CreatedActions = @($CreatedActions)
        CreatedLocals  = @($CreatedLocals)
        BinaryActions  = @($BinaryActions)
        BinaryLocals   = @($BinaryLocals)
        DeletedActions = @($DeletedActions)
        Applied        = @($AppliedActions).Count + $BinaryReplaced
        Created        = @($CreatedActions).Count + $BinaryCreated
        BinaryCreated  = $BinaryCreated
        BinaryReplaced = $BinaryReplaced
        Deleted        = @($DeletedActions).Count
        BackupSet      = $BackupSet
        BackupSetPath  = $BackupSetPath
    }
}

function Invoke-SyncPushApplyBackupPhase {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [AllowEmptyCollection()]
        [object[]]$ActionRows,

        [AllowEmptyCollection()]
        [object[]]$BinaryRows,

        [AllowEmptyCollection()]
        [object[]]$DeleteRows,

        [Parameter(Mandatory)]
        [string]$BackupSetPath,

        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [scriptblock]$GetRemoteFile = $null,

        [scriptblock]$CopyBackupFile = $null
    )

    $replaceRows = @($BinaryRows | Where-Object { [string]$_.Mode -eq 'replace' })
    $backupTotal = $ActionRows.Count + $replaceRows.Count + $DeleteRows.Count
    $backupDone = 0

    $backupLists = @($ActionRows, $replaceRows, $DeleteRows)
    foreach ($list in $backupLists) {
        foreach ($action in $list) {
            Write-RundotSyncPublishProgress `
                -Phase 'backup' `
                -Path ([string]$action.Path) `
                -Index ($backupDone + 1) `
                -Total $backupTotal `
                -Applied $backupDone

            Save-RundotSyncPushRemoteBackup `
                -WorkspaceRoot $WorkspaceRoot `
                -BackupSetPath $BackupSetPath `
                -Action $action `
                -StudioOrigin $StudioOrigin `
                -ProjectId $ProjectId `
                -Headers $Headers `
                -GetRemoteFile $GetRemoteFile `
                -CopyBackupFile $CopyBackupFile | Out-Null
            $backupDone++
        }
    }
}

function Invoke-RundotSyncPushApply {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Actions,

        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [string]$BackupSetPath,

        [AllowEmptyCollection()]
        [object[]]$DeleteActions = @(),

        [AllowEmptyCollection()]
        [object[]]$CreateActions = @(),

        [AllowEmptyCollection()]
        [object[]]$BinaryActions = @(),

        [AllowNull()]
        $Artifact = $null,

        [AllowNull()]
        $Resolution = $null,

        [scriptblock]$GetRemoteFile = $null,

        [scriptblock]$PutRemoteFile = $null,

        [scriptblock]$DeleteRemoteFile = $null,

        [scriptblock]$GetRemoteFileList = $null,

        [scriptblock]$CopyBackupFile = $null,

        [scriptblock]$InvokeTextCreate = $null,

        [scriptblock]$InvokeBinaryPlace = $null,

        [AllowNull()]
        $LiveLocalManifest = $null
    )

    $actionRows = @($Actions)
    $createRows = @($CreateActions)
    $binaryRows = @($BinaryActions)
    $deleteRows = @($DeleteActions)

    if ($actionRows.Count -eq 0 -and $createRows.Count -eq 0 -and $binaryRows.Count -eq 0 -and $deleteRows.Count -eq 0) {
        return (New-SyncPushApplyResult)
    }

    $backup = New-SyncPushBackupSet -WorkspaceRoot $WorkspaceRoot -BackupSetPath $BackupSetPath
    $backupSet = $backup.BackupSet
    $BackupSetPath = $backup.BackupSetPath

    Assert-SyncPushApplyLocalUnchanged -WorkspaceRoot $WorkspaceRoot -Actions $actionRows
    Assert-SyncPushApplyLocalUnchanged -WorkspaceRoot $WorkspaceRoot -Actions $createRows
    Assert-SyncPushApplyLocalUnchanged -WorkspaceRoot $WorkspaceRoot -Actions $binaryRows

    $remotePaths = Get-SyncPushApplyRemotePaths `
        -WorkspaceRoot $WorkspaceRoot `
        -DeleteActions $deleteRows

    $written = $null
    try {
        # Back up every path first, writes and deletes alike. No DELETE runs
        # until every backup it depends on has verified.
        Invoke-SyncPushApplyBackupPhase `
            -WorkspaceRoot $WorkspaceRoot `
            -ActionRows $actionRows `
            -BinaryRows $binaryRows `
            -DeleteRows $deleteRows `
            -BackupSetPath $BackupSetPath `
            -StudioOrigin $StudioOrigin `
            -ProjectId $ProjectId `
            -Headers $Headers `
            -GetRemoteFile $GetRemoteFile `
            -CopyBackupFile $CopyBackupFile

        $written = Invoke-SyncPushWriteDispatch `
            -WorkspaceRoot $WorkspaceRoot `
            -ActionRows $actionRows `
            -CreateRows $createRows `
            -BinaryRows $binaryRows `
            -DeleteRows $deleteRows `
            -Artifact $Artifact `
            -Resolution $Resolution `
            -StudioOrigin $StudioOrigin `
            -ProjectId $ProjectId `
            -Headers $Headers `
            -RemotePaths $remotePaths `
            -GetRemoteFile $GetRemoteFile `
            -PutRemoteFile $PutRemoteFile `
            -DeleteRemoteFile $DeleteRemoteFile `
            -GetRemoteFileList $GetRemoteFileList `
            -InvokeTextCreate $InvokeTextCreate `
            -InvokeBinaryPlace $InvokeBinaryPlace `
            -LiveLocalManifest $LiveLocalManifest
    }
    catch {
        throw (New-SyncPushApplyFailure -Exception $_.Exception)
    }

    $counts = Get-SyncPushBinaryCounts -BinaryActions $written.BinaryActions
    $allAppliedLocals = Merge-SyncPushAppliedLocals `
        -AppliedLocals $written.AppliedLocals `
        -CreatedLocals $written.CreatedLocals `
        -BinaryLocals $written.BinaryLocals

    return (New-SyncPushApplyResult `
        -AppliedActions $written.AppliedActions `
        -AppliedLocals $allAppliedLocals `
        -CreatedActions $written.CreatedActions `
        -CreatedLocals $written.CreatedLocals `
        -BinaryActions $written.BinaryActions `
        -BinaryLocals $written.BinaryLocals `
        -DeletedActions $written.DeletedActions `
        -BinaryCreated $counts.Created `
        -BinaryReplaced $counts.Replaced `
        -BackupSet $backupSet `
        -BackupSetPath $BackupSetPath)
}
