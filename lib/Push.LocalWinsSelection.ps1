# Push.LocalWinsSelection.ps1 - Local-wins selection and policy.
#
# Part of the Push split (#70). Loaded by lib/Push.ps1; do not dot-source
# directly. Function bodies are unchanged from the original lib/Push.ps1.

function Add-SyncPushLocalWinsExcludedRow {
    param(
        $ExcludedList,

        [string]$Path,
        [string]$Status,
        [string]$Reason,

        [bool]$Ignored = $false,
        [bool]$KindChange = $false
    )

    [void]$ExcludedList.Add([pscustomobject]@{
        Path       = $Path
        Status     = $Status
        Reason     = $Reason
        Ignored    = $Ignored
        KindChange = $KindChange
    })
}

function Get-SyncPushLocalWinsPlanDriftReason {
    param(
        [string]$PlanStatus,
        [string]$LiveStatus
    )

    if ([string]::Equals($PlanStatus, $LiveStatus, [System.StringComparison]::Ordinal)) {
        return $null
    }

    return ("Path no longer matches plan status (now {0}). Re-run Plan." -f $LiveStatus)
}

function Add-SyncPushLocalWinsDeleteAction {
    param(
        $DeletesList,
        [string]$Path,
        [string]$Status,
        [string]$ExpectedRemoteSha,
        [string]$LiveRemoteSha,
        [object[]]$RemotePaths
    )

    $refusal = Get-SyncDeletePathRefusalReason `
        -CanonicalPath $Path `
        -RemotePaths $RemotePaths
    if (-not [string]::IsNullOrEmpty($refusal)) {
        return $refusal
    }

    if ([string]::IsNullOrEmpty($ExpectedRemoteSha)) {
        return ("'{0}' has no expectedRemoteHash to verify before DELETE." -f $Path)
    }

    if (-not (Test-SyncHashEqual -LeftSha256 $ExpectedRemoteSha -RightSha256 $LiveRemoteSha)) {
        return ("REMOTE for '{0}' no longer matches expectedRemoteHash. Re-run Plan." -f $Path)
    }

    [void]$DeletesList.Add([pscustomobject]@{
        Path               = $Path
        Status             = $Status
        ExpectedRemoteHash = $ExpectedRemoteSha
        RemoteSha256       = $LiveRemoteSha
        RemotePaths        = @($RemotePaths)
    })

    return $null
}

function Get-SyncPushLocalWinsRemoteOnlyDownloadRow {
    param(
        $Operation,
        $LocalEntry,
        $RemoteEntry,
        [object[]]$RemotePaths,
        $DeletesList
    )

    $path = [string]$Operation.path
    $status = [string]$Operation.status

    if ($null -ne $localEntry) {
        return 'REMOTE differs from BASE while LOCAL still matches BASE. Push never downloads remote content.'
    }

    if ($null -eq $remoteEntry) {
        return ("REMOTE for '{0}' is absent. Re-run Plan." -f $path)
    }

    $expectedRemoteSha = [string]$Operation.expectedRemoteHash
    $liveRemoteSha = [string](Get-SyncEntrySha256 -Entry $remoteEntry)
    if ([string]::IsNullOrEmpty($expectedRemoteSha)) {
        $expectedRemoteSha = $liveRemoteSha
    }

    return (Add-SyncPushLocalWinsDeleteAction `
        -DeletesList $DeletesList `
        -Path $path `
        -Status $status `
        -ExpectedRemoteSha $expectedRemoteSha `
        -LiveRemoteSha $liveRemoteSha `
        -RemotePaths $RemotePaths)
}

function Get-SyncPushLocalWinsSelection {
    # Local-wins publish: default applicable rows plus conflicts (not kind
    # change) and remote-only downloads, with drift as per-path exclusion.
    param(
        [Parameter(Mandatory)]
        $Artifact,

        $Base,
        $Local,
        $Remote
    )

    $actions = New-Object 'System.Collections.Generic.List[object]'
    $creates = New-Object 'System.Collections.Generic.List[object]'
    $binaries = New-Object 'System.Collections.Generic.List[object]'
    $deletes = New-Object 'System.Collections.Generic.List[object]'
    $excluded = New-Object 'System.Collections.Generic.List[object]'
    $remotePaths = @(Get-SyncPlanRemotePaths -Remote $Remote)

    foreach ($operation in @($Artifact.operations)) {
        $path = [string]$operation.path
        $planStatus = [string]$operation.status

        $baseEntry = Get-SyncMapEntry -Map $Base -Path $path
        $localEntry = Get-SyncMapEntry -Map $Local -Path $path
        $remoteEntry = Get-SyncMapEntry -Map $Remote -Path $path

        $change = Get-SyncPlanChange `
            -Path $path `
            -Base $baseEntry `
            -Local $localEntry `
            -Remote $remoteEntry
        $liveStatus = [string]$change.Status

        $driftReason = Get-SyncPushLocalWinsPlanDriftReason `
            -PlanStatus $planStatus `
            -LiveStatus $liveStatus
        if (-not [string]::IsNullOrEmpty($driftReason)) {
            Add-SyncPushLocalWinsExcludedRow `
                -ExcludedList $excluded `
                -Path $path `
                -Status $planStatus `
                -Reason $driftReason `
                -Ignored ([bool]$operation.ignored) `
                -KindChange ([bool]$operation.kindChange)
            continue
        }

        $standardOutcome = Get-SyncPushLocalWinsStandardRow `
            -Operation $operation `
            -BaseEntry $baseEntry `
            -LocalEntry $localEntry `
            -RemoteEntry $remoteEntry `
            -Change $change `
            -RemotePaths $remotePaths `
            -ActionsList $actions `
            -CreatesList $creates `
            -BinariesList $binaries `
            -DeletesList $deletes
        if ($standardOutcome -is [string] -and -not [string]::IsNullOrEmpty($standardOutcome)) {
            Add-SyncPushLocalWinsExcludedRow `
                -ExcludedList $excluded `
                -Path $path `
                -Status $planStatus `
                -Reason $standardOutcome `
                -Ignored ([bool]$operation.ignored) `
                -KindChange ([bool]$operation.kindChange)
            continue
        }

        if ($standardOutcome -eq $null) {
            continue
        }

        if ($liveStatus -eq $script:SyncStatusConflict) {
            $rowReason = Get-SyncPushLocalWinsConflictRow `
                -Operation $operation `
                -BaseEntry $baseEntry `
                -LocalEntry $localEntry `
                -RemoteEntry $remoteEntry `
                -Change $change `
                -RemotePaths $remotePaths `
                -ActionsList $actions `
                -CreatesList $creates `
                -BinariesList $binaries `
                -DeletesList $deletes
            if ($null -ne $rowReason) {
                Add-SyncPushLocalWinsExcludedRow `
                    -ExcludedList $excluded `
                    -Path $path `
                    -Status $planStatus `
                    -Reason $rowReason `
                    -Ignored ([bool]$operation.ignored) `
                    -KindChange ([bool]$operation.kindChange)
            }
            continue
        }

        if ($liveStatus -eq $script:SyncStatusDownload) {
            $rowReason = Get-SyncPushLocalWinsRemoteOnlyDownloadRow `
                -Operation $operation `
                -LocalEntry $localEntry `
                -RemoteEntry $remoteEntry `
                -RemotePaths $remotePaths `
                -DeletesList $deletes
            if ($null -ne $rowReason) {
                Add-SyncPushLocalWinsExcludedRow `
                    -ExcludedList $excluded `
                    -Path $path `
                    -Status $planStatus `
                    -Reason $rowReason `
                    -Ignored ([bool]$operation.ignored) `
                    -KindChange ([bool]$operation.kindChange)
            }
            continue
        }

        Add-SyncPushLocalWinsExcludedRow `
            -ExcludedList $excluded `
            -Path $path `
            -Status $planStatus `
            -Reason (Get-SyncPushExclusionReason -PlanOperation $operation) `
            -Ignored ([bool]$operation.ignored) `
            -KindChange ([bool]$operation.kindChange)
    }

    return [pscustomobject]@{
        Actions       = @($actions.ToArray())
        CreateActions = @($creates.ToArray())
        BinaryActions = @($binaries.ToArray())
        DeleteActions = @($deletes.ToArray())
        Excluded      = @($excluded.ToArray())
        LocalWins     = $true
    }
}
