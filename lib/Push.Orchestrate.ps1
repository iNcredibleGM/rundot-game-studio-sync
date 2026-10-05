# Push.Orchestrate.ps1 - Push entrypoint and orchestration.
#
# Part of the Push split (#70). Loaded by lib/Push.ps1; do not dot-source
# directly. Invoke-RundotSyncPush is the single entrypoint the CLI calls. It is
# the only layer that decides whether BASE moves, and the only layer that
# journals.

function Get-SyncPushSelectionForMode {
    param(
        [Parameter(Mandatory)]
        $Artifact,

        [Parameter(Mandatory)]
        $Resolution,

        $Local,

        $Remote,

        [bool]$LocalWins
    )

    $baseMap = Get-SyncPlanBaseMapFromResolution -Resolution $Resolution
    if ($LocalWins) {
        return (Get-SyncPushLocalWinsSelection `
            -Artifact $Artifact `
            -Base $baseMap `
            -Local $Local `
            -Remote $Remote)
    }

    return (Get-SyncPushSelection `
        -Artifact $Artifact `
        -Base $baseMap `
        -Local $Local `
        -Remote $Remote)
}

function New-SyncPushCancelledResult {
    param(
        $Selection,
        [string]$PlanId
    )

    return [pscustomobject]@{
        Applied        = 0
        Created        = 0
        Deleted        = 0
        Cancelled      = $true
        BaseUpdated    = $false
        PlanId         = $PlanId
        Selection      = $Selection
        AppliedActions = @()
        CreatedActions = @()
        DeletedActions = @()
        Report         = (Format-SyncPushReport `
            -Selection $Selection `
            -AppliedActions @() `
            -Cancelled $true `
            -PlanId $PlanId)
    }
}

function Assert-SyncPushConfirmations {
    # Confirmation before any write or delete. Every confirmation is collected
    # before the first backup, so a decline changes nothing at all. Returns
    # $true to proceed and $false when the user declined.
    param(
        [bool]$LocalWins,
        [bool]$Force,
        [int]$PublishCount,
        [object[]]$Actions,
        [object[]]$CreateActions,
        [object[]]$BinaryActions,
        [object[]]$DeleteActions,
        [scriptblock]$ConfirmLocalWins = $null,
        [scriptblock]$ConfirmOverwrite = $null,
        [scriptblock]$ConfirmCreate = $null,
        [scriptblock]$ConfirmBinary = $null,
        [scriptblock]$ConfirmDelete = $null
    )

    if ($LocalWins -and $PublishCount -gt 0 -and -not $Force) {
        if ($null -eq $ConfirmLocalWins) {
            throw [System.InvalidOperationException]::new(
                ("Refusing to push: {0} path(s) would be published with local-wins. " -f $PublishCount) +
                'Confirm with -LocalWins and type yes, or pass -ForcePush to proceed. ' +
                'Backups and live hash checks are never skipped.'
            )
        }

        $confirmed = [bool](& $ConfirmLocalWins $Actions $CreateActions $BinaryActions $DeleteActions)
        if (-not $confirmed) {
            return $false
        }
    }

    if (-not $LocalWins -and $Actions.Count -gt 0 -and -not $Force) {
        if ($null -eq $ConfirmOverwrite) {
            throw [System.InvalidOperationException]::new(
                ("Refusing to push: {0} remote text file(s) would be overwritten. " -f $Actions.Count) +
                'Confirm the overwrite, or pass -ForcePush to proceed. ' +
                'A backup of each remote original is always created first.'
            )
        }

        $confirmed = [bool](& $ConfirmOverwrite $Actions.Count @($Actions | ForEach-Object { [string]$_.Path }))
        if (-not $confirmed) {
            return $false
        }
    }

    if (-not $LocalWins -and $CreateActions.Count -gt 0 -and -not $Force) {
        if ($null -eq $ConfirmCreate) {
            throw [System.InvalidOperationException]::new(
                ("Refusing to push: {0} remote text file(s) would be created. " -f $CreateActions.Count) +
                'Confirm the create, or pass -ForcePush to proceed.'
            )
        }

        $confirmed = [bool](& $ConfirmCreate $CreateActions.Count @($CreateActions | ForEach-Object { [string]$_.Path }))
        if (-not $confirmed) {
            return $false
        }
    }

    if (-not $LocalWins -and $BinaryActions.Count -gt 0 -and -not $Force) {
        if ($null -eq $ConfirmBinary) {
            throw [System.InvalidOperationException]::new(
                ("Refusing to push: {0} remote binary file(s) would be created or replaced. " -f $BinaryActions.Count) +
                'Confirm the binary place, or pass -ForcePush to proceed. ' +
                'A backup of each remote original is always created before a replacement.'
            )
        }

        $binaryPathLabels = @($BinaryActions | ForEach-Object {
            ('{0} ({1})' -f [string]$_.Path, [string]$_.Mode)
        })
        $confirmed = [bool](& $ConfirmBinary $BinaryActions.Count @binaryPathLabels)
        if (-not $confirmed) {
            return $false
        }
    }

    # A delete is unrecoverable from Studio, so it gets its own confirmation
    # even when the overwrite half was accepted.
    if (-not $LocalWins -and $DeleteActions.Count -gt 0 -and -not $Force) {
        if ($null -eq $ConfirmDelete) {
            throw [System.InvalidOperationException]::new(
                ("Refusing to push: {0} remote file(s) would be deleted. " -f $DeleteActions.Count) +
                'Confirm the delete, or pass -ForcePush to proceed. ' +
                'A backup of each remote original is always created first.'
            )
        }

        $confirmed = [bool](& $ConfirmDelete $DeleteActions.Count @($DeleteActions | ForEach-Object { [string]$_.Path }))
        if (-not $confirmed) {
            return $false
        }
    }

    return $true
}

function New-SyncPushNothingToPushResult {
    param(
        $Selection,
        [string]$PlanId
    )

    return [pscustomobject]@{
        Applied        = 0
        Created        = 0
        Deleted        = 0
        Cancelled      = $false
        BaseUpdated    = $false
        HadRefusals    = $false
        PlanId         = $PlanId
        Selection      = $Selection
        AppliedActions = @()
        CreatedActions = @()
        DeletedActions = @()
        RefusedActions = @()
        Report         = (Format-SyncPushReport `
            -Selection $Selection `
            -AppliedActions @() `
            -PlanId $PlanId)
    }
}

function New-SyncPushResult {
    param(
        $Selection,
        $ApplyResult,
        [object[]]$RefusedActions,
        [bool]$HadRefusals,
        [bool]$BaseUpdated,
        [string]$PlanId,
        $BackupSet,
        [string]$BackupRoot
    )

    return [pscustomobject]@{
        Applied        = [int]$ApplyResult.Applied
        Created        = [int]$ApplyResult.Created
        Deleted        = [int]$ApplyResult.Deleted
        Cancelled      = $false
        BaseUpdated    = $BaseUpdated
        HadRefusals    = $HadRefusals
        PlanId         = $PlanId
        Selection      = $Selection
        AppliedActions = @($ApplyResult.AppliedActions)
        CreatedActions = @($ApplyResult.CreatedActions)
        DeletedActions = @($ApplyResult.DeletedActions)
        RefusedActions = @($RefusedActions)
        BackupSet      = $BackupSet
        BackupSetPath  = [string]$BackupSet.Path
        BackupSetName  = [string]$BackupSet.Name
        BackupRoot     = $BackupRoot
        Report         = (Format-SyncPushReport `
            -Selection $Selection `
            -AppliedActions $ApplyResult.AppliedActions `
            -Applied $ApplyResult.Applied `
            -CreatedActions $ApplyResult.CreatedActions `
            -Created $ApplyResult.Created `
            -DeletedActions $ApplyResult.DeletedActions `
            -Deleted $ApplyResult.Deleted `
            -BinaryActions $ApplyResult.BinaryActions `
            -Refused $RefusedActions `
            -BaseUpdated $BaseUpdated `
            -PlanId $PlanId `
            -BackupRoot $BackupRoot `
            -BackupSetPath ([string]$BackupSet.Path))
    }
}

function Invoke-RundotSyncPush {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        $Resolution,

        [AllowNull()]
        $Artifact,

        $Local,

        $Remote,

        [Parameter(Mandatory)]
        $Snapshot,

        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [scriptblock]$ConfirmOverwrite = $null,

        [scriptblock]$ConfirmDelete = $null,

        [scriptblock]$ConfirmCreate = $null,

        [scriptblock]$ConfirmBinary = $null,

        [scriptblock]$ConfirmLocalWins = $null,

        [switch]$LocalWins,

        [switch]$Force,

        [scriptblock]$GetRemoteFile = $null,

        [scriptblock]$PutRemoteFile = $null,

        [scriptblock]$DeleteRemoteFile = $null,

        [scriptblock]$GetRemoteFileList = $null
    )

    Assert-RundotSyncPushPlanArtifact `
        -Artifact $Artifact `
        -ProjectId $ProjectId `
        -WorkspaceRoot $WorkspaceRoot `
        -Resolution $Resolution `
        -Local $Local `
        -Snapshot $Snapshot

    $selection = Get-SyncPushSelectionForMode `
        -Artifact $Artifact `
        -Resolution $Resolution `
        -Local $Local `
        -Remote $Remote `
        -LocalWins ([bool]$LocalWins)

    $actions = @($selection.Actions)
    $createActions = @($selection.CreateActions)
    $binaryActions = @($selection.BinaryActions)
    $deleteActions = @($selection.DeleteActions)
    $planId = [string]$Artifact.planId
    $backupRoot = Get-RundotSyncBackupRoot -WorkspaceRoot $WorkspaceRoot

    $publishCount = $actions.Count + $createActions.Count + $binaryActions.Count + $deleteActions.Count

    $confirmed = Assert-SyncPushConfirmations `
        -LocalWins ([bool]$LocalWins) `
        -Force ([bool]$Force) `
        -PublishCount $publishCount `
        -Actions $actions `
        -CreateActions $createActions `
        -BinaryActions $binaryActions `
        -DeleteActions $deleteActions `
        -ConfirmLocalWins $ConfirmLocalWins `
        -ConfirmOverwrite $ConfirmOverwrite `
        -ConfirmCreate $ConfirmCreate `
        -ConfirmBinary $ConfirmBinary `
        -ConfirmDelete $ConfirmDelete
    if (-not $confirmed) {
        return (New-SyncPushCancelledResult -Selection $selection -PlanId $planId)
    }

    if ($publishCount -eq 0) {
        return (New-SyncPushNothingToPushResult -Selection $selection -PlanId $planId)
    }

    $publish = Invoke-SyncPushPublishPhase `
        -WorkspaceRoot $WorkspaceRoot `
        -ProjectId $ProjectId `
        -StudioOrigin $StudioOrigin `
        -Headers $Headers `
        -Resolution $Resolution `
        -Artifact $Artifact `
        -Selection $selection `
        -PlanId $planId `
        -Actions $actions `
        -CreateActions $createActions `
        -BinaryActions $binaryActions `
        -DeleteActions $deleteActions `
        -LocalWins ([bool]$LocalWins) `
        -LiveLocalManifest $Local `
        -GetRemoteFile $GetRemoteFile `
        -PutRemoteFile $PutRemoteFile `
        -DeleteRemoteFile $DeleteRemoteFile `
        -GetRemoteFileList $GetRemoteFileList

    return (New-SyncPushResult `
        -Selection $selection `
        -ApplyResult $publish.ApplyResult `
        -RefusedActions $publish.RefusedActions `
        -HadRefusals $publish.HadRefusals `
        -BaseUpdated $publish.BaseUpdated `
        -PlanId $planId `
        -BackupSet $publish.BackupSet `
        -BackupRoot $backupRoot)
}
