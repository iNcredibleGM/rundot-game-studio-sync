# Push.LocalWinsConflictRow.ps1 - Local-wins conflict/remote-only row classifier.
#
# Part of the Push split (#70). Loaded by lib/Push.ps1; do not dot-source
# directly. A conflict (or a remote-only path) is publishable under -LocalWins
# by replacing remote bytes with local bytes; an unsupported kind pairing is
# still refused with a reason string.

function Get-SyncPushLocalWinsConflictBothPresentRow {
    param(
        [string]$Path,
        [string]$Status,
        [string]$PlanLocalSha,
        [string]$ExpectedRemoteSha,
        $LocalEntry,
        $RemoteEntry,
        [object[]]$RemotePaths,
        $ActionsList,
        $BinariesList
    )

    $localKind = [string](Get-SyncEntryKind -Entry $LocalEntry)
    $remoteKind = [string](Get-SyncEntryKind -Entry $RemoteEntry)
    $liveRemoteSha = [string](Get-SyncEntrySha256 -Entry $RemoteEntry)

    if (-not [string]::IsNullOrEmpty($ExpectedRemoteSha)) {
        if (-not (Test-SyncHashEqual -LeftSha256 $ExpectedRemoteSha -RightSha256 $liveRemoteSha)) {
            return ("REMOTE for '{0}' no longer matches expectedRemoteHash. Re-run Plan." -f $Path)
        }
    }
    else {
        $ExpectedRemoteSha = $liveRemoteSha
    }

    if ($localKind -eq 'utf8' -and $remoteKind -eq 'utf8') {
        [void]$ActionsList.Add([pscustomobject]@{
            Path               = $Path
            Status             = $Status
            Kind               = $localKind
            LocalSha256        = $PlanLocalSha
            ExpectedRemoteHash = $ExpectedRemoteSha
            RemoteSha256       = $liveRemoteSha
        })

        return $null
    }

    if ($localKind -eq 'binary' -and $remoteKind -eq 'binary') {
        $localSize = Get-SyncEntryProperty -Entry $LocalEntry -Names @('Size', 'size')
        $localSizeValue = 0
        if ($null -ne $localSize) {
            $localSizeValue = [int64]$localSize
        }

        if ($localSizeValue -le 0) {
            return ("'{0}' is not a publishable binary replace. {1}" -f $Path, $script:SyncPlanBinaryEmptyReason)
        }

        if (Test-SyncOversizeSize -Size $localSizeValue) {
            return ("'{0}' is over Studio's read limit. {1}" -f $Path, (Get-SyncOversizeReplaceRefusalReason -Size $localSizeValue))
        }

        $placeRefusal = Get-SyncBinaryPlacePathRefusalReason `
            -CanonicalPath $Path `
            -RemotePaths $RemotePaths
        if (-not [string]::IsNullOrEmpty($placeRefusal)) {
            return ("'{0}' is not a publishable binary replace. {1}" -f $Path, $placeRefusal)
        }

        [void]$BinariesList.Add([pscustomobject]@{
            Path               = $Path
            Status             = $Status
            Kind               = $localKind
            Mode               = 'replace'
            LocalSha256        = $PlanLocalSha
            ExpectedRemoteHash = $ExpectedRemoteSha
            RemoteSha256       = $liveRemoteSha
        })

        return $null
    }

    return ("'{0}' is not a publishable local-wins overwrite (unsupported kind pairing)." -f $Path)
}

function Get-SyncPushLocalWinsConflictLocalOnlyRow {
    param(
        [string]$Path,
        [string]$Status,
        [string]$PlanLocalSha,
        $LocalEntry,
        [object[]]$RemotePaths,
        $CreatesList,
        $BinariesList
    )

    $localKind = [string](Get-SyncEntryKind -Entry $LocalEntry)
    $localSize = Get-SyncEntryProperty -Entry $LocalEntry -Names @('Size', 'size')
    $localSizeValue = 0
    if ($null -ne $localSize) {
        $localSizeValue = [int64]$localSize
    }

    if ($localKind -eq 'utf8') {
        $createRefusal = Get-SyncTextCreatePathRefusalReason `
            -CanonicalPath $Path `
            -RemotePaths $RemotePaths
        if (-not [string]::IsNullOrEmpty($createRefusal)) {
            return ("'{0}' is not a publishable text create. {1}" -f $Path, $createRefusal)
        }

        [void]$CreatesList.Add([pscustomobject]@{
            Path        = $Path
            Status      = $Status
            Kind        = $localKind
            LocalSha256 = $PlanLocalSha
        })

        return $null
    }

    if ($localKind -eq 'binary') {
        if ($localSizeValue -le 0) {
            return ("'{0}' is not a publishable binary create. {1}" -f $Path, $script:SyncPlanBinaryEmptyReason)
        }

        # An oversize binary CREATE is publishable: the place sequence
        # verifies it from the upload ETag rather than a read-back (#54).

        $placeRefusal = Get-SyncBinaryPlacePathRefusalReason `
            -CanonicalPath $Path `
            -RemotePaths $RemotePaths
        if (-not [string]::IsNullOrEmpty($placeRefusal)) {
            return ("'{0}' is not a publishable binary create. {1}" -f $Path, $placeRefusal)
        }

        [void]$BinariesList.Add([pscustomobject]@{
            Path        = $Path
            Status      = $Status
            Kind        = $localKind
            Mode        = 'create'
            LocalSha256 = $PlanLocalSha
        })

        return $null
    }

    return ("'{0}' is not a publishable local-wins create." -f $Path)
}

function Get-SyncPushLocalWinsConflictRemoteOnlyRow {
    param(
        [string]$Path,
        [string]$Status,
        [string]$ExpectedRemoteSha,
        $RemoteEntry,
        [object[]]$RemotePaths,
        $DeletesList
    )

    $liveRemoteSha = [string](Get-SyncEntrySha256 -Entry $RemoteEntry)
    if ([string]::IsNullOrEmpty($ExpectedRemoteSha)) {
        $ExpectedRemoteSha = $liveRemoteSha
    }

    return (Add-SyncPushLocalWinsDeleteAction `
        -DeletesList $DeletesList `
        -Path $Path `
        -Status $Status `
        -ExpectedRemoteSha $ExpectedRemoteSha `
        -LiveRemoteSha $liveRemoteSha `
        -RemotePaths $RemotePaths)
}

function Get-SyncPushLocalWinsConflictRow {
    param(
        $Operation,
        $BaseEntry,
        $LocalEntry,
        $RemoteEntry,
        $Change,
        [object[]]$RemotePaths,
        $ActionsList,
        $CreatesList,
        $BinariesList,
        $DeletesList
    )

    $path = [string]$Operation.path
    $status = [string]$Operation.status
    $planLocalSha = [string]$Operation.localSha256
    $expectedRemoteSha = [string]$Operation.expectedRemoteHash

    if ([bool]$Operation.kindChange -or [bool]$Change.KindChange) {
        return $script:SyncKindChangeReason
    }

    $liveLocalSha = [string](Get-SyncEntrySha256 -Entry $LocalEntry)
    if (-not [string]::IsNullOrEmpty($planLocalSha) -and $null -ne $LocalEntry) {
        if (-not (Test-SyncHashEqual -LeftSha256 $planLocalSha -RightSha256 $liveLocalSha)) {
            return ("LOCAL for '{0}' changed since this plan was created. Re-run Plan." -f $path)
        }
    }

    $hasLocal = ($null -ne $LocalEntry)
    $hasRemote = ($null -ne $RemoteEntry)

    if ($hasLocal -and $hasRemote) {
        return (Get-SyncPushLocalWinsConflictBothPresentRow `
            -Path $path `
            -Status $status `
            -PlanLocalSha $planLocalSha `
            -ExpectedRemoteSha $expectedRemoteSha `
            -LocalEntry $LocalEntry `
            -RemoteEntry $RemoteEntry `
            -RemotePaths $RemotePaths `
            -ActionsList $ActionsList `
            -BinariesList $BinariesList)
    }

    if ($hasLocal -and -not $hasRemote) {
        return (Get-SyncPushLocalWinsConflictLocalOnlyRow `
            -Path $path `
            -Status $status `
            -PlanLocalSha $planLocalSha `
            -LocalEntry $LocalEntry `
            -RemotePaths $RemotePaths `
            -CreatesList $CreatesList `
            -BinariesList $BinariesList)
    }

    if (-not $hasLocal -and $hasRemote) {
        return (Get-SyncPushLocalWinsConflictRemoteOnlyRow `
            -Path $path `
            -Status $status `
            -ExpectedRemoteSha $expectedRemoteSha `
            -RemoteEntry $RemoteEntry `
            -RemotePaths $RemotePaths `
            -DeletesList $DeletesList)
    }

    return $script:SyncConflictReason
}
