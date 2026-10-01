# Push.LocalWinsRow.ps1 - Local-wins standard (non-conflict) row classifier.
#
# Part of the Push split (#70). Loaded by lib/Push.ps1; do not dot-source
# directly. Same publish rules as default Push, but drift becomes an exclusion
# reason (a returned string) instead of aborting the whole run.

function Get-SyncPushLocalWinsStandardDeleteRow {
    param(
        [string]$Path,
        [string]$Status,
        [string]$ExpectedRemoteSha,
        $BaseEntry,
        $LocalEntry,
        $RemoteEntry,
        [string]$LiveStatus,
        [object[]]$RemotePaths,
        $DeletesList
    )

    if ($LiveStatus -ne $script:SyncStatusDeleteRemoteCandidate) {
        return ("'{0}' is no longer a remote delete candidate (now {1}). Re-run Plan." -f $Path, $LiveStatus)
    }

    if ($null -ne $LocalEntry) {
        return ("LOCAL for '{0}' reappeared since this plan was created. Re-run Plan." -f $Path)
    }

    $baseSha = [string](Get-SyncEntrySha256 -Entry $BaseEntry)
    $liveRemoteSha = [string](Get-SyncEntrySha256 -Entry $RemoteEntry)
    if (-not (Test-SyncHashEqual -LeftSha256 $baseSha -RightSha256 $liveRemoteSha)) {
        return ("REMOTE for '{0}' no longer matches BASE. Re-run Plan." -f $Path)
    }

    return (Add-SyncPushLocalWinsDeleteAction `
        -DeletesList $DeletesList `
        -Path $Path `
        -Status $Status `
        -ExpectedRemoteSha $ExpectedRemoteSha `
        -LiveRemoteSha $liveRemoteSha `
        -RemotePaths $RemotePaths)
}

function Get-SyncPushLocalWinsStandardCreateRow {
    param(
        [string]$Path,
        [string]$Status,
        [string]$LocalKind,
        [string]$PlanLocalSha,
        [int64]$LocalSizeValue,
        $BaseEntry,
        $RemoteEntry,
        [object[]]$RemotePaths,
        $CreatesList,
        $BinariesList
    )

    if ($LocalKind -eq 'binary') {
        if ($null -ne $BaseEntry) {
            return ("BASE for '{0}' appeared since this plan was created. Re-run Plan." -f $Path)
        }

        if ($null -ne $RemoteEntry) {
            return ("REMOTE for '{0}' appeared since this plan was created. Re-run Plan." -f $Path)
        }

        if ($LocalSizeValue -le 0) {
            return ("'{0}' is not a publishable binary create. {1}" -f $Path, $script:SyncPlanBinaryEmptyReason)
        }

        # An oversize binary CREATE is publishable: the place sequence
        # verifies it from the upload ETag rather than a read-back (#54).

        $placeRefusal = Get-SyncBinaryPlacePathRefusalReason `
            -CanonicalPath $Path `
            -RemotePaths $RemotePaths
        if (-not [string]::IsNullOrEmpty($placeRefusal)) {
            return ("'{0}' is no longer a publishable binary create. {1}" -f $Path, $placeRefusal)
        }

        [void]$BinariesList.Add([pscustomobject]@{
            Path        = $Path
            Status      = $Status
            Kind        = $LocalKind
            Mode        = 'create'
            LocalSha256 = $PlanLocalSha
        })

        return $null
    }

    if ($LocalKind -ne 'utf8') {
        return ("'{0}' is not a utf8 text create." -f $Path)
    }

    if ($null -ne $BaseEntry) {
        return ("BASE for '{0}' appeared since this plan was created. Re-run Plan." -f $Path)
    }

    if ($null -ne $RemoteEntry) {
        return ("REMOTE for '{0}' appeared since this plan was created. Re-run Plan." -f $Path)
    }

    $createRefusal = Get-SyncTextCreatePathRefusalReason `
        -CanonicalPath $Path `
        -RemotePaths $RemotePaths
    if (-not [string]::IsNullOrEmpty($createRefusal)) {
        return ("'{0}' is no longer a publishable text create. {1}" -f $Path, $createRefusal)
    }

    [void]$CreatesList.Add([pscustomobject]@{
        Path        = $Path
        Status      = $Status
        Kind        = $LocalKind
        LocalSha256 = $PlanLocalSha
    })

    return $null
}

function Get-SyncPushLocalWinsStandardReplaceRow {
    param(
        [string]$Path,
        [string]$Status,
        [string]$LocalKind,
        [string]$PlanLocalSha,
        [string]$ExpectedRemoteSha,
        [int64]$LocalSizeValue,
        $RemoteEntry,
        [object[]]$RemotePaths,
        $ActionsList,
        $BinariesList
    )

    $remoteKind = [string](Get-SyncEntryKind -Entry $RemoteEntry)

    if ($LocalKind -eq 'binary') {
        if ($remoteKind -ne 'binary') {
            return ("'{0}' is not a binary replace." -f $Path)
        }

        if ($LocalSizeValue -le 0) {
            return ("'{0}' is not a publishable binary replace. {1}" -f $Path, $script:SyncPlanBinaryEmptyReason)
        }

        if (Test-SyncOversizeSize -Size $LocalSizeValue) {
            return ("'{0}' is over Studio's read limit. {1}" -f $Path, (Get-SyncOversizeReplaceRefusalReason -Size $LocalSizeValue))
        }

        $placeRefusal = Get-SyncBinaryPlacePathRefusalReason `
            -CanonicalPath $Path `
            -RemotePaths $RemotePaths
        if (-not [string]::IsNullOrEmpty($placeRefusal)) {
            return ("'{0}' is no longer a publishable binary replace. {1}" -f $Path, $placeRefusal)
        }

        $liveRemoteSha = [string](Get-SyncEntrySha256 -Entry $RemoteEntry)
        if (-not (Test-SyncHashEqual -LeftSha256 $ExpectedRemoteSha -RightSha256 $liveRemoteSha)) {
            return ("REMOTE for '{0}' no longer matches expectedRemoteHash. Re-run Plan." -f $Path)
        }

        [void]$BinariesList.Add([pscustomobject]@{
            Path               = $Path
            Status             = $Status
            Kind               = $LocalKind
            Mode               = 'replace'
            LocalSha256        = $PlanLocalSha
            ExpectedRemoteHash = $ExpectedRemoteSha
            RemoteSha256       = $liveRemoteSha
        })

        return $null
    }

    if ($LocalKind -ne 'utf8' -or $remoteKind -ne 'utf8') {
        return ("'{0}' is not a utf8 text overwrite." -f $Path)
    }

    $liveRemoteSha = [string](Get-SyncEntrySha256 -Entry $RemoteEntry)
    if (-not (Test-SyncHashEqual -LeftSha256 $ExpectedRemoteSha -RightSha256 $liveRemoteSha)) {
        return ("REMOTE for '{0}' no longer matches expectedRemoteHash. Re-run Plan." -f $Path)
    }

    [void]$ActionsList.Add([pscustomobject]@{
        Path               = $Path
        Status             = $Status
        Kind               = $LocalKind
        LocalSha256        = $PlanLocalSha
        ExpectedRemoteHash = $ExpectedRemoteSha
        RemoteSha256       = $liveRemoteSha
    })

    return $null
}

function Get-SyncPushLocalWinsStandardRow {
    # Same publish rules as default Push, but drift becomes an exclusion reason
    # instead of aborting the whole run.
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
    $liveStatus = [string]$Change.Status
    $applicable = [bool]$Operation.applicable

    $isUploadRow = ($status -eq $script:SyncStatusUpload -and $applicable)
    $isDeleteRow = ($status -eq $script:SyncStatusDeleteRemoteCandidate -and $applicable)

    if (-not $isUploadRow -and -not $isDeleteRow) {
        return ''
    }

    if ($isDeleteRow) {
        return (Get-SyncPushLocalWinsStandardDeleteRow `
            -Path $path `
            -Status $status `
            -ExpectedRemoteSha ([string]$Operation.expectedRemoteHash) `
            -BaseEntry $BaseEntry `
            -LocalEntry $LocalEntry `
            -RemoteEntry $RemoteEntry `
            -LiveStatus $liveStatus `
            -RemotePaths $RemotePaths `
            -DeletesList $DeletesList)
    }

    if ($liveStatus -ne $script:SyncStatusUpload) {
        return ("'{0}' is no longer an upload candidate (now {1}). Re-run Plan." -f $path, $liveStatus)
    }

    if ([bool]$Change.KindChange) {
        return ("'{0}' has an unsupported kind change. Re-run Plan." -f $path)
    }

    $localKind = [string](Get-SyncEntryKind -Entry $LocalEntry)
    $planLocalSha = [string]$Operation.localSha256
    $liveLocalSha = [string](Get-SyncEntrySha256 -Entry $LocalEntry)
    if (-not (Test-SyncHashEqual -LeftSha256 $planLocalSha -RightSha256 $liveLocalSha)) {
        return ("LOCAL for '{0}' changed since this plan was created. Re-run Plan." -f $path)
    }

    $expectedRemoteSha = [string]$Operation.expectedRemoteHash
    $localSize = Get-SyncEntryProperty -Entry $LocalEntry -Names @('Size', 'size')
    $localSizeValue = 0
    if ($null -ne $localSize) {
        $localSizeValue = [int64]$localSize
    }

    if ([string]::IsNullOrEmpty($expectedRemoteSha)) {
        return (Get-SyncPushLocalWinsStandardCreateRow `
            -Path $path `
            -Status $status `
            -LocalKind $localKind `
            -PlanLocalSha $planLocalSha `
            -LocalSizeValue $localSizeValue `
            -BaseEntry $BaseEntry `
            -RemoteEntry $RemoteEntry `
            -RemotePaths $RemotePaths `
            -CreatesList $CreatesList `
            -BinariesList $BinariesList)
    }

    return (Get-SyncPushLocalWinsStandardReplaceRow `
        -Path $path `
        -Status $status `
        -LocalKind $localKind `
        -PlanLocalSha $planLocalSha `
        -ExpectedRemoteSha $expectedRemoteSha `
        -LocalSizeValue $localSizeValue `
        -RemoteEntry $RemoteEntry `
        -RemotePaths $RemotePaths `
        -ActionsList $ActionsList `
        -BinariesList $BinariesList)
}
