# Push.Selection.ps1 - Default-push selection and policy.
#
# Part of the Push split (#70). Loaded by lib/Push.ps1; do not dot-source
# directly. Split the plan artifact into publishable text overwrites,
# applicable remote deletes, and everything else. Default Push throws when an
# applicable row is no longer the clean action it was planned as; the
# local-wins path lives in Push.LocalWinsSelection.ps1.

function Get-SyncPushExclusionReason {
    param($PlanOperation)

    $status = [string]$PlanOperation.status
    $reason = [string]$PlanOperation.reason

    if (-not [string]::IsNullOrEmpty($reason)) {
        return $reason
    }

    switch ($status) {
        $script:SyncStatusDownload {
            return 'REMOTE differs from BASE while LOCAL still matches BASE. Push never downloads remote content.'
        }
        $script:SyncStatusConflict {
            if ([bool]$PlanOperation.kindChange) {
                return $script:SyncKindChangeReason
            }

            return $script:SyncConflictReason
        }
        $script:SyncStatusDeleteLocalCandidate {
            return 'REMOTE no longer has this path while LOCAL still matches BASE. Push does not delete local content.'
        }
        $script:SyncStatusDeleteRemoteCandidate {
            return $script:SyncPlanDeleteRemoteRefusalReason
        }
        $script:SyncStatusIgnored {
            return $script:SyncIgnoredReason
        }
        $script:SyncStatusUnchanged {
            return 'BASE, LOCAL, and REMOTE all agree, so there is nothing to push.'
        }
        $script:SyncStatusUnverifiable {
            return 'REMOTE is over Studio''s read limit, so its bytes cannot be read or hashed. Push never rewrites an unverifiable path.'
        }
        $script:SyncStatusSynchronizedChange {
            return 'LOCAL and REMOTE already agree on the new content, so there is nothing to push.'
        }
        $script:SyncStatusSynchronizedAddition {
            return 'LOCAL and REMOTE already agree on this untracked path, so there is nothing to push.'
        }
        $script:SyncStatusSettledAbsent {
            return 'This path is absent from both LOCAL and REMOTE, so there is nothing to push.'
        }
    }

    return 'This path is not a publishable text overwrite, so Push does not apply it.'
}

function Add-SyncPushSelectionExcludedRow {
    param(
        $ExcludedList,
        $PlanOperation
    )

    [void]$ExcludedList.Add([pscustomobject]@{
        Path       = [string]$PlanOperation.path
        Status     = [string]$PlanOperation.status
        Reason     = Get-SyncPushExclusionReason -PlanOperation $PlanOperation
        Ignored    = [bool]$PlanOperation.ignored
        KindChange = [bool]$PlanOperation.kindChange
    })
}

function Add-SyncPushDeleteSelectionRow {
    param(
        $Operation,
        [string]$Path,
        [string]$Status,
        $BaseEntry,
        $LocalEntry,
        $RemoteEntry,
        [string]$LiveStatus,
        [object[]]$RemotePaths,
        $DeletesList
    )

    if ($LiveStatus -ne $script:SyncStatusDeleteRemoteCandidate) {
        throw [System.InvalidOperationException]::new(
            ("Refusing to push: '{0}' is no longer a remote delete candidate (now {1}). Re-run Plan." -f $Path, $LiveStatus)
        )
    }

    # LOCAL must still be genuinely absent, and REMOTE must still match
    # the verified BASE the plan was computed against. Otherwise the
    # delete would remove content nobody agreed to remove.
    if ($null -ne $LocalEntry) {
        throw [System.InvalidOperationException]::new(
            ("Refusing to push: LOCAL for '{0}' reappeared since this plan was created. Re-run Plan." -f $Path)
        )
    }

    $baseSha = [string](Get-SyncEntrySha256 -Entry $BaseEntry)
    $liveRemoteSha = [string](Get-SyncEntrySha256 -Entry $RemoteEntry)
    if (-not (Test-SyncHashEqual -LeftSha256 $baseSha -RightSha256 $liveRemoteSha)) {
        throw [System.InvalidOperationException]::new(
            ("Refusing to push: REMOTE for '{0}' no longer matches BASE. Re-run Plan." -f $Path)
        )
    }

    $expectedRemoteSha = [string]$Operation.expectedRemoteHash
    if ([string]::IsNullOrEmpty($expectedRemoteSha)) {
        throw [System.InvalidOperationException]::new(
            ("Refusing to push: '{0}' has no expectedRemoteHash to verify before DELETE." -f $Path)
        )
    }

    if (-not (Test-SyncHashEqual -LeftSha256 $expectedRemoteSha -RightSha256 $liveRemoteSha)) {
        throw [System.InvalidOperationException]::new(
            ("Refusing to push: REMOTE for '{0}' no longer matches expectedRemoteHash. Re-run Plan." -f $Path)
        )
    }

    # Defense in depth: the plan already refused a reserved or
    # directory-shaped path, and the engine refuses it again against
    # the live remote list rather than trusting the artifact.
    Assert-SyncDeletePathAllowed `
        -CanonicalPath $Path `
        -RemotePaths $RemotePaths

    [void]$DeletesList.Add([pscustomobject]@{
        Path               = $Path
        Status             = $Status
        ExpectedRemoteHash = $expectedRemoteSha
        RemoteSha256       = $liveRemoteSha
        RemotePaths        = @($RemotePaths)
    })
}

function Add-SyncPushCreateSelectionRow {
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
            throw [System.InvalidOperationException]::new(
                ("Refusing to push: BASE for '{0}' appeared since this plan was created. Re-run Plan." -f $Path)
            )
        }

        if ($null -ne $RemoteEntry) {
            throw [System.InvalidOperationException]::new(
                ("Refusing to push: REMOTE for '{0}' appeared since this plan was created. Re-run Plan." -f $Path)
            )
        }

        if ($LocalSizeValue -le 0) {
            throw [System.InvalidOperationException]::new(
                ("Refusing to push: '{0}' is not a publishable binary create. {1}" -f $Path, $script:SyncPlanBinaryEmptyReason)
            )
        }

        # An oversize binary CREATE is publishable: the place sequence
        # verifies it from the upload ETag rather than a read-back
        # (#54). An oversize REPLACE is still refused below.

        $placeRefusal = Get-SyncBinaryPlacePathRefusalReason `
            -CanonicalPath $Path `
            -RemotePaths $RemotePaths
        if (-not [string]::IsNullOrEmpty($placeRefusal)) {
            throw [System.InvalidOperationException]::new(
                ("Refusing to push: '{0}' is no longer a publishable binary create. {1}" -f $Path, $placeRefusal)
            )
        }

        [void]$BinariesList.Add([pscustomobject]@{
            Path        = $Path
            Status      = $Status
            Kind        = $LocalKind
            Mode        = 'create'
            LocalSha256 = $PlanLocalSha
        })

        return
    }

    if ($LocalKind -ne 'utf8') {
        throw [System.InvalidOperationException]::new(
            ("Refusing to push: '{0}' is not a utf8 text create." -f $Path)
        )
    }

    if ($null -ne $BaseEntry) {
        throw [System.InvalidOperationException]::new(
            ("Refusing to push: BASE for '{0}' appeared since this plan was created. Re-run Plan." -f $Path)
        )
    }

    if ($null -ne $RemoteEntry) {
        throw [System.InvalidOperationException]::new(
            ("Refusing to push: REMOTE for '{0}' appeared since this plan was created. Re-run Plan." -f $Path)
        )
    }

    $createRefusal = Get-SyncTextCreatePathRefusalReason `
        -CanonicalPath $Path `
        -RemotePaths $RemotePaths
    if (-not [string]::IsNullOrEmpty($createRefusal)) {
        throw [System.InvalidOperationException]::new(
            ("Refusing to push: '{0}' is no longer a publishable text create. {1}" -f $Path, $createRefusal)
        )
    }

    [void]$CreatesList.Add([pscustomobject]@{
        Path        = $Path
        Status      = $Status
        Kind        = $LocalKind
        LocalSha256 = $PlanLocalSha
    })
}

function Add-SyncPushReplaceSelectionRow {
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
            throw [System.InvalidOperationException]::new(
                ("Refusing to push: '{0}' is not a binary replace." -f $Path)
            )
        }

        if ($LocalSizeValue -le 0) {
            throw [System.InvalidOperationException]::new(
                ("Refusing to push: '{0}' is not a publishable binary replace. {1}" -f $Path, $script:SyncPlanBinaryEmptyReason)
            )
        }

        if (Test-SyncOversizeSize -Size $LocalSizeValue) {
            throw [System.InvalidOperationException]::new(
                ("Refusing to push: '{0}' is over Studio's read limit. {1}" -f $Path, (Get-SyncOversizeReplaceRefusalReason -Size $LocalSizeValue))
            )
        }

        $placeRefusal = Get-SyncBinaryPlacePathRefusalReason `
            -CanonicalPath $Path `
            -RemotePaths $RemotePaths
        if (-not [string]::IsNullOrEmpty($placeRefusal)) {
            throw [System.InvalidOperationException]::new(
                ("Refusing to push: '{0}' is no longer a publishable binary replace. {1}" -f $Path, $placeRefusal)
            )
        }

        $liveRemoteSha = [string](Get-SyncEntrySha256 -Entry $RemoteEntry)
        if (-not (Test-SyncHashEqual -LeftSha256 $ExpectedRemoteSha -RightSha256 $liveRemoteSha)) {
            throw [System.InvalidOperationException]::new(
                ("Refusing to push: REMOTE for '{0}' no longer matches expectedRemoteHash. Re-run Plan." -f $Path)
            )
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

        return
    }

    if ($LocalKind -ne 'utf8' -or $remoteKind -ne 'utf8') {
        throw [System.InvalidOperationException]::new(
            ("Refusing to push: '{0}' is not a utf8 text overwrite." -f $Path)
        )
    }

    $liveRemoteSha = [string](Get-SyncEntrySha256 -Entry $RemoteEntry)
    if (-not (Test-SyncHashEqual -LeftSha256 $ExpectedRemoteSha -RightSha256 $liveRemoteSha)) {
        throw [System.InvalidOperationException]::new(
            ("Refusing to push: REMOTE for '{0}' no longer matches expectedRemoteHash. Re-run Plan." -f $Path)
        )
    }

    [void]$ActionsList.Add([pscustomobject]@{
        Path               = $Path
        Status             = $Status
        Kind               = $LocalKind
        LocalSha256        = $PlanLocalSha
        ExpectedRemoteHash = $ExpectedRemoteSha
        RemoteSha256       = $liveRemoteSha
    })
}

function Add-SyncPushUploadSelectionRow {
    param(
        $Operation,
        [string]$Path,
        [string]$Status,
        $BaseEntry,
        $LocalEntry,
        $RemoteEntry,
        $Change,
        [string]$LiveStatus,
        [object[]]$RemotePaths,
        $ActionsList,
        $CreatesList,
        $BinariesList
    )

    if ($LiveStatus -ne $script:SyncStatusUpload) {
        throw [System.InvalidOperationException]::new(
            ("Refusing to push: '{0}' is no longer an upload candidate (now {1}). Re-run Plan." -f $Path, $LiveStatus)
        )
    }

    if ([bool]$Change.KindChange) {
        throw [System.InvalidOperationException]::new(
            ("Refusing to push: '{0}' has an unsupported kind change. Re-run Plan." -f $Path)
        )
    }

    $localKind = [string](Get-SyncEntryKind -Entry $LocalEntry)
    $planLocalSha = [string]$Operation.localSha256
    $liveLocalSha = [string](Get-SyncEntrySha256 -Entry $LocalEntry)
    if (-not (Test-SyncHashEqual -LeftSha256 $planLocalSha -RightSha256 $liveLocalSha)) {
        throw [System.InvalidOperationException]::new(
            ("Refusing to push: LOCAL for '{0}' changed since this plan was created. Re-run Plan." -f $Path)
        )
    }

    $expectedRemoteSha = [string]$Operation.expectedRemoteHash
    $localSize = Get-SyncEntryProperty -Entry $LocalEntry -Names @('Size', 'size')
    $localSizeValue = 0
    if ($null -ne $localSize) {
        $localSizeValue = [int64]$localSize
    }

    if ([string]::IsNullOrEmpty($expectedRemoteSha)) {
        Add-SyncPushCreateSelectionRow `
            -Path $Path `
            -Status $Status `
            -LocalKind $localKind `
            -PlanLocalSha $planLocalSha `
            -LocalSizeValue $localSizeValue `
            -BaseEntry $BaseEntry `
            -RemoteEntry $RemoteEntry `
            -RemotePaths $RemotePaths `
            -CreatesList $CreatesList `
            -BinariesList $BinariesList

        return
    }

    Add-SyncPushReplaceSelectionRow `
        -Path $Path `
        -Status $Status `
        -LocalKind $localKind `
        -PlanLocalSha $planLocalSha `
        -ExpectedRemoteSha $expectedRemoteSha `
        -LocalSizeValue $localSizeValue `
        -RemoteEntry $RemoteEntry `
        -RemotePaths $RemotePaths `
        -ActionsList $ActionsList `
        -BinariesList $BinariesList
}

function Get-SyncPushSelection {
    # Split the plan artifact into publishable text overwrites, applicable
    # remote deletes, and everything else. Pure over the supplied maps except
    # for the hard refusal when a row the plan marked applicable is no longer
    # the clean action it was planned as.
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
        $status = [string]$operation.status
        $applicable = [bool]$operation.applicable

        $isUploadRow = ($status -eq $script:SyncStatusUpload -and $applicable)
        $isDeleteRow = ($status -eq $script:SyncStatusDeleteRemoteCandidate -and $applicable)

        if (-not $isUploadRow -and -not $isDeleteRow) {
            Add-SyncPushSelectionExcludedRow -ExcludedList $excluded -PlanOperation $operation

            continue
        }

        $baseEntry = Get-SyncMapEntry -Map $Base -Path $path
        $localEntry = Get-SyncMapEntry -Map $Local -Path $path
        $remoteEntry = Get-SyncMapEntry -Map $Remote -Path $path

        $change = Get-SyncPlanChange `
            -Path $path `
            -Base $baseEntry `
            -Local $localEntry `
            -Remote $remoteEntry
        $liveStatus = [string]$change.Status

        if ($isDeleteRow) {
            Add-SyncPushDeleteSelectionRow `
                -Operation $operation `
                -Path $path `
                -Status $status `
                -BaseEntry $baseEntry `
                -LocalEntry $localEntry `
                -RemoteEntry $remoteEntry `
                -LiveStatus $liveStatus `
                -RemotePaths $remotePaths `
                -DeletesList $deletes

            continue
        }

        Add-SyncPushUploadSelectionRow `
            -Operation $operation `
            -Path $path `
            -Status $status `
            -BaseEntry $baseEntry `
            -LocalEntry $localEntry `
            -RemoteEntry $remoteEntry `
            -Change $change `
            -LiveStatus $liveStatus `
            -RemotePaths $remotePaths `
            -ActionsList $actions `
            -CreatesList $creates `
            -BinariesList $binaries
    }

    $actionRows = @()
    if ($actions.Count -gt 0) {
        $actionRows = $actions.ToArray()
    }

    $createRows = @()
    if ($creates.Count -gt 0) {
        $createRows = $creates.ToArray()
    }

    $deleteRows = @()
    if ($deletes.Count -gt 0) {
        $deleteRows = $deletes.ToArray()
    }

    $binaryRows = @()
    if ($binaries.Count -gt 0) {
        $binaryRows = $binaries.ToArray()
    }

    $excludedRows = @()
    if ($excluded.Count -gt 0) {
        $excludedRows = $excluded.ToArray()
    }

    return [pscustomobject]@{
        Actions       = $actionRows
        CreateActions = $createRows
        BinaryActions = $binaryRows
        DeleteActions = $deleteRows
        Excluded      = $excludedRows
    }
}
