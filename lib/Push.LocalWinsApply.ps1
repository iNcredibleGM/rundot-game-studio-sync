# Push.LocalWinsApply.ps1 - Local-wins apply path (refuse-and-continue).
#
# Part of the Push split (#70). Loaded by lib/Push.ps1; do not dot-source
# directly. Same backup-all-first contract as default Push, but a per-path
# write or drift failure is recorded and the run continues with the remaining
# paths.

function Add-SyncPushLocalWinsRefusedRow {
    param(
        $RefusedList,
        $Action,
        [string]$Reason
    )

    $status = 'upload'
    if ($null -ne $Action -and $null -ne $Action.PSObject.Properties['Status']) {
        $status = [string]$Action.Status
    }

    $path = [string]$Action.Path
    [void]$RefusedList.Add([pscustomobject]@{
        Path   = $path
        Status = $status
        Reason = $Reason
    })
}

function New-SyncPushLocalWinsResult {
    param(
        [object[]]$AppliedActions = @(),
        [object[]]$AppliedLocals = @(),
        [object[]]$CreatedActions = @(),
        [object[]]$CreatedLocals = @(),
        [object[]]$BinaryActions = @(),
        [object[]]$BinaryLocals = @(),
        [object[]]$DeletedActions = @(),
        [object[]]$Refused = @(),
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
        Refused        = @($Refused)
        Applied        = @($AppliedActions).Count + $BinaryReplaced
        Created        = @($CreatedActions).Count + $BinaryCreated
        BinaryCreated  = $BinaryCreated
        BinaryReplaced = $BinaryReplaced
        Deleted        = @($DeletedActions).Count
        BackupSet      = $BackupSet
        BackupSetPath  = $BackupSetPath
    }
}

function Invoke-RundotSyncLocalWinsApply {
    # Same backup-all-first contract as default Push, but a per-path write or
    # drift failure is recorded and the run continues with the remaining paths.
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
        return (New-SyncPushLocalWinsResult)
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

    # Progress counts are separate per phase so each line reports applied
    # versus remaining for the work it belongs to. LocalWins continues after a
    # refusal, so the write counter advances on the attempt, not the success.
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
        -LiveLocalManifest $LiveLocalManifest `
        -ContinueOnRefusal

    $counts = Get-SyncPushBinaryCounts -BinaryActions $written.BinaryActions
    $allAppliedLocals = Merge-SyncPushAppliedLocals `
        -AppliedLocals $written.AppliedLocals `
        -CreatedLocals $written.CreatedLocals `
        -BinaryLocals $written.BinaryLocals

    return (New-SyncPushLocalWinsResult `
        -AppliedActions $written.AppliedActions `
        -AppliedLocals $allAppliedLocals `
        -CreatedActions $written.CreatedActions `
        -CreatedLocals $written.CreatedLocals `
        -BinaryActions $written.BinaryActions `
        -BinaryLocals $written.BinaryLocals `
        -DeletedActions $written.DeletedActions `
        -Refused $written.Refused `
        -BinaryCreated $counts.Created `
        -BinaryReplaced $counts.Replaced `
        -BackupSet $backupSet `
        -BackupSetPath $BackupSetPath)
}
