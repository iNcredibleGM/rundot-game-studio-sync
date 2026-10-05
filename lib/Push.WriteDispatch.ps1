# Push.WriteDispatch.ps1 - The write loop both apply paths share.
#
# Part of the Push split (#70). Loaded by lib/Push.ps1; do not dot-source
# directly. Writes overwrites, creates, binaries, and deletes in the original
# order. A per-path failure rethrows on the clean path and is recorded as a
# refusal on the local-wins path. The running counts ride in the shared $State
# hashtable so a mid-run failure can journal exactly what succeeded first.

function Invoke-SyncPushWriteOverwriteRows {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [AllowEmptyCollection()]
        [object[]]$Rows,

        [int]$WriteTotal = 0,

        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [scriptblock]$GetRemoteFile = $null,

        [scriptblock]$PutRemoteFile = $null,

        [switch]$ContinueOnRefusal
    )

    foreach ($action in @($Rows)) {
        Write-RundotSyncPublishProgress `
            -Phase 'write' `
            -Path ([string]$action.Path) `
            -Index ($State.Done + 1) `
            -Total $WriteTotal `
            -Applied $State.Done

        try {
            $appliedLocal = Invoke-RundotSyncPushWriteAction `
                -WorkspaceRoot $WorkspaceRoot `
                -Action $action `
                -StudioOrigin $StudioOrigin `
                -ProjectId $ProjectId `
                -Headers $Headers `
                -GetRemoteFile $GetRemoteFile `
                -PutRemoteFile $PutRemoteFile

            [void]$State.AppliedActions.Add($action)
            [void]$State.AppliedLocals.Add($appliedLocal)
            $State.Applied++
        }
        catch {
            if (-not $ContinueOnRefusal) {
                Set-SyncPushPartialCounts `
                    -Exception $_.Exception `
                    -Applied $State.Applied `
                    -Created $State.Created `
                    -Binary $State.Binary `
                    -Deleted $State.Deleted
                throw
            }

            Add-SyncPushLocalWinsRefusedRow `
                -RefusedList $State.Refused `
                -Action $action `
                -Reason ([string]$_.Exception.Message)
        }
        $State.Done++
    }
}

function Invoke-SyncPushWriteCreateRows {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [AllowEmptyCollection()]
        [object[]]$Rows,

        [int]$WriteTotal = 0,

        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [scriptblock]$GetRemoteFile = $null,

        [scriptblock]$PutRemoteFile = $null,

        [scriptblock]$InvokeTextCreate = $null,

        [switch]$ContinueOnRefusal
    )

    foreach ($action in @($Rows)) {
        Write-RundotSyncPublishProgress `
            -Phase 'write' `
            -Path ([string]$action.Path) `
            -Index ($State.Done + 1) `
            -Total $WriteTotal `
            -Applied $State.Done

        try {
            $createdLocal = Invoke-RundotSyncPushCreateAction `
                -WorkspaceRoot $WorkspaceRoot `
                -Action $action `
                -StudioOrigin $StudioOrigin `
                -ProjectId $ProjectId `
                -Headers $Headers `
                -GetRemoteFile $GetRemoteFile `
                -PutRemoteFile $PutRemoteFile `
                -InvokeTextCreate $InvokeTextCreate

            [void]$State.CreatedActions.Add($action)
            [void]$State.CreatedLocals.Add($createdLocal)
            $State.Created++
        }
        catch {
            if (-not $ContinueOnRefusal) {
                Set-SyncPushPartialCounts `
                    -Exception $_.Exception `
                    -Applied $State.Applied `
                    -Created $State.Created `
                    -Binary $State.Binary `
                    -Deleted $State.Deleted
                throw
            }

            Add-SyncPushLocalWinsRefusedRow `
                -RefusedList $State.Refused `
                -Action $action `
                -Reason ([string]$_.Exception.Message)
        }
        $State.Done++
    }
}

function Invoke-SyncPushWriteBinaryRows {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [AllowEmptyCollection()]
        [object[]]$Rows,

        [int]$WriteTotal = 0,

        [Parameter(Mandatory)]
        [hashtable]$State,

        [AllowNull()]
        $Artifact,

        [AllowNull()]
        $Resolution,

        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [scriptblock]$GetRemoteFile = $null,

        [scriptblock]$GetRemoteFileList = $null,

        [scriptblock]$InvokeBinaryPlace = $null,

        [AllowNull()]
        $LiveLocalManifest = $null,

        [switch]$ContinueOnRefusal
    )

    foreach ($action in @($Rows)) {
        Write-RundotSyncPublishProgress `
            -Phase 'write' `
            -Path ([string]$action.Path) `
            -Index ($State.Done + 1) `
            -Total $WriteTotal `
            -Applied $State.Done

        try {
            $binaryLocal = Invoke-RundotSyncPushBinaryAction `
                -WorkspaceRoot $WorkspaceRoot `
                -Action $action `
                -Artifact $Artifact `
                -Resolution $Resolution `
                -ProjectId $ProjectId `
                -StudioOrigin $StudioOrigin `
                -Headers $Headers `
                -GetRemoteFile $GetRemoteFile `
                -GetRemoteFileList $GetRemoteFileList `
                -InvokeBinaryPlace $InvokeBinaryPlace `
                -LiveLocalManifest $LiveLocalManifest

            [void]$State.BinaryActions.Add($action)
            [void]$State.BinaryLocals.Add($binaryLocal)
            $State.Binary++
        }
        catch {
            if (-not $ContinueOnRefusal) {
                Set-SyncPushPartialCounts `
                    -Exception $_.Exception `
                    -Applied $State.Applied `
                    -Created $State.Created `
                    -Binary $State.Binary `
                    -Deleted $State.Deleted
                throw
            }

            Add-SyncPushLocalWinsRefusedRow `
                -RefusedList $State.Refused `
                -Action $action `
                -Reason ([string]$_.Exception.Message)
        }
        $State.Done++
    }
}

function Invoke-SyncPushWriteDeleteRows {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [AllowEmptyCollection()]
        [object[]]$Rows,

        [int]$WriteTotal = 0,

        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [AllowNull()]
        [string[]]$RemotePaths,

        [scriptblock]$GetRemoteFile = $null,

        [scriptblock]$DeleteRemoteFile = $null,

        [scriptblock]$GetRemoteFileList = $null,

        [switch]$ContinueOnRefusal
    )

    foreach ($action in @($Rows)) {
        Write-RundotSyncPublishProgress `
            -Phase 'write' `
            -Path ([string]$action.Path) `
            -Index ($State.Done + 1) `
            -Total $WriteTotal `
            -Applied $State.Done

        try {
            $deleted = Invoke-RundotSyncDeleteAction `
                -WorkspaceRoot $WorkspaceRoot `
                -Action $action `
                -StudioOrigin $StudioOrigin `
                -ProjectId $ProjectId `
                -Headers $Headers `
                -RemotePaths $RemotePaths `
                -GetRemoteFile $GetRemoteFile `
                -DeleteRemoteFile $DeleteRemoteFile `
                -GetRemoteFileList $GetRemoteFileList

            [void]$State.DeletedActions.Add($deleted)
            $State.Deleted++
        }
        catch {
            if (-not $ContinueOnRefusal) {
                Set-SyncPushPartialCounts `
                    -Exception $_.Exception `
                    -Applied $State.Applied `
                    -Created $State.Created `
                    -Binary $State.Binary `
                    -Deleted $State.Deleted
                throw
            }

            Add-SyncPushLocalWinsRefusedRow `
                -RefusedList $State.Refused `
                -Action $action `
                -Reason ([string]$_.Exception.Message)
        }
        $State.Done++
    }
}

function New-SyncPushWriteState {
    return @{
        AppliedActions = New-Object 'System.Collections.Generic.List[object]'
        AppliedLocals  = New-Object 'System.Collections.Generic.List[object]'
        CreatedActions = New-Object 'System.Collections.Generic.List[object]'
        CreatedLocals  = New-Object 'System.Collections.Generic.List[object]'
        BinaryActions  = New-Object 'System.Collections.Generic.List[object]'
        BinaryLocals   = New-Object 'System.Collections.Generic.List[object]'
        DeletedActions = New-Object 'System.Collections.Generic.List[object]'
        Refused        = New-Object 'System.Collections.Generic.List[object]'
        Applied        = 0
        Created        = 0
        Binary         = 0
        Deleted        = 0
        Done           = 0
    }
}

function Invoke-SyncPushWriteDispatch {
    # The write loop shared by both apply paths, in the original order:
    # overwrites, creates, binaries, deletes. A per-path failure rethrows on
    # the clean path and is recorded as a refusal on the local-wins path.
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [AllowEmptyCollection()]
        [object[]]$ActionRows,

        [AllowEmptyCollection()]
        [object[]]$CreateRows,

        [AllowEmptyCollection()]
        [object[]]$BinaryRows,

        [AllowEmptyCollection()]
        [object[]]$DeleteRows,

        [AllowNull()]
        $Artifact,

        [AllowNull()]
        $Resolution,

        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [AllowNull()]
        [string[]]$RemotePaths,

        [scriptblock]$GetRemoteFile = $null,

        [scriptblock]$PutRemoteFile = $null,

        [scriptblock]$DeleteRemoteFile = $null,

        [scriptblock]$GetRemoteFileList = $null,

        [scriptblock]$InvokeTextCreate = $null,

        [scriptblock]$InvokeBinaryPlace = $null,

        [AllowNull()]
        $LiveLocalManifest = $null,

        [switch]$ContinueOnRefusal
    )

    $writeTotal = $ActionRows.Count + $CreateRows.Count + $BinaryRows.Count + $DeleteRows.Count
    $state = New-SyncPushWriteState

    Invoke-SyncPushWriteOverwriteRows `
        -WorkspaceRoot $WorkspaceRoot `
        -Rows $ActionRows `
        -WriteTotal $writeTotal `
        -State $state `
        -StudioOrigin $StudioOrigin `
        -ProjectId $ProjectId `
        -Headers $Headers `
        -GetRemoteFile $GetRemoteFile `
        -PutRemoteFile $PutRemoteFile `
        -ContinueOnRefusal:$ContinueOnRefusal

    Invoke-SyncPushWriteCreateRows `
        -WorkspaceRoot $WorkspaceRoot `
        -Rows $CreateRows `
        -WriteTotal $writeTotal `
        -State $state `
        -StudioOrigin $StudioOrigin `
        -ProjectId $ProjectId `
        -Headers $Headers `
        -GetRemoteFile $GetRemoteFile `
        -PutRemoteFile $PutRemoteFile `
        -InvokeTextCreate $InvokeTextCreate `
        -ContinueOnRefusal:$ContinueOnRefusal

    Invoke-SyncPushWriteBinaryRows `
        -WorkspaceRoot $WorkspaceRoot `
        -Rows $BinaryRows `
        -WriteTotal $writeTotal `
        -State $state `
        -Artifact $Artifact `
        -Resolution $Resolution `
        -StudioOrigin $StudioOrigin `
        -ProjectId $ProjectId `
        -Headers $Headers `
        -GetRemoteFile $GetRemoteFile `
        -GetRemoteFileList $GetRemoteFileList `
        -InvokeBinaryPlace $InvokeBinaryPlace `
        -LiveLocalManifest $LiveLocalManifest `
        -ContinueOnRefusal:$ContinueOnRefusal

    Invoke-SyncPushWriteDeleteRows `
        -WorkspaceRoot $WorkspaceRoot `
        -Rows $DeleteRows `
        -WriteTotal $writeTotal `
        -State $state `
        -StudioOrigin $StudioOrigin `
        -ProjectId $ProjectId `
        -Headers $Headers `
        -RemotePaths $RemotePaths `
        -GetRemoteFile $GetRemoteFile `
        -DeleteRemoteFile $DeleteRemoteFile `
        -GetRemoteFileList $GetRemoteFileList `
        -ContinueOnRefusal:$ContinueOnRefusal

    return [pscustomobject]@{
        AppliedActions = $state.AppliedActions
        AppliedLocals  = $state.AppliedLocals
        CreatedActions = $state.CreatedActions
        CreatedLocals  = $state.CreatedLocals
        BinaryActions  = $state.BinaryActions
        BinaryLocals   = $state.BinaryLocals
        DeletedActions = $state.DeletedActions
        Refused        = $state.Refused
    }
}
