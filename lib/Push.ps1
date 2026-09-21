# Safe Push: publish clean local text overwrites to Studio.
#
# Push applies exactly one classification from a verified plan artifact: a clean
# text overwrite (BASE=A LOCAL=B REMOTE=A, utf8 kind, expectedRemoteHash set).
# Creates, binaries, conflicts, kind mismatches, and deletes are refused.
#
# This file owns three layers:
#
#   1. validation   - plan artifact fingerprints and live state gates
#   2. selection    - which plan rows Push may apply, and why the rest are not
#   3. apply/BASE   - per-file GET+PUT with echo verification, then additive BASE
#
# Callers must load Paths.ps1, Ignore.ps1, Hashing.ps1, Workspace.ps1,
# Manifest.ps1, Snapshot.ps1, Classifier.ps1, Plan.ps1, RemoteApi.ps1,
# RemoteWrite.ps1, and Push.ps1 first.


# ----------------------------------------------------------------------------
# Plan artifact gates
# ----------------------------------------------------------------------------

function Assert-RundotSyncPushPlanArtifact {
    param(
        [AllowNull()]
        $Artifact,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        $Resolution,

        [Parameter(Mandatory)]
        $Local,

        [Parameter(Mandatory)]
        $Snapshot
    )

    if ($null -eq $Artifact) {
        throw [System.InvalidOperationException]::new(
            'No plan artifact found. Run Plan before Push.'
        )
    }

    Assert-PlanArtifactShape -Artifact $Artifact

    if (-not [string]::Equals([string]$Artifact.projectId, $ProjectId, [System.StringComparison]::Ordinal)) {
        throw [System.InvalidOperationException]::new(
            'Refusing to push: plan projectId does not match this command.'
        )
    }

    $expectedFingerprint = Get-LocalRootFingerprint -WorkspaceRoot $WorkspaceRoot
    if (
        -not [string]::Equals(
            [string]$Artifact.localRootFingerprint,
            $expectedFingerprint,
            [System.StringComparison]::Ordinal
        )
    ) {
        throw [System.InvalidOperationException]::new(
            'Refusing to push: plan localRootFingerprint does not match this workspace folder.'
        )
    }

    if (-not [bool]$Artifact.basePresent -or [bool]$Artifact.untrusted) {
        throw [System.InvalidOperationException]::new(
            'Refusing to push: the plan was built without a verified BASE.'
        )
    }

    if ($null -eq $Resolution -or $null -eq $Resolution.Base) {
        throw [System.InvalidOperationException]::new(
            'Refusing to push: BASE is missing.'
        )
    }

    $baseCapturedAt = $null
    $capturedProperty = $Resolution.Base.PSObject.Properties['capturedAt']
    if ($null -ne $capturedProperty) {
        $baseCapturedAt = [string]$capturedProperty.Value
    }

    if (-not [string]::Equals([string]$Artifact.baseCapturedAt, $baseCapturedAt, [System.StringComparison]::Ordinal)) {
        throw [System.InvalidOperationException]::new(
            'Refusing to push: BASE changed since this plan was created. Re-run Plan.'
        )
    }

    $expiresAt = [System.DateTime]::Parse(
        [string]$Artifact.expiresAt,
        $null,
        [System.Globalization.DateTimeStyles]::RoundtripKind
    )
    if ($expiresAt.Kind -eq [System.DateTimeKind]::Unspecified) {
        $expiresAt = [System.DateTime]::SpecifyKind($expiresAt, [System.DateTimeKind]::Utc)
    }
    elseif ($expiresAt.Kind -eq [System.DateTimeKind]::Local) {
        $expiresAt = $expiresAt.ToUniversalTime()
    }

    if ([DateTime]::UtcNow -ge $expiresAt) {
        throw [System.InvalidOperationException]::new(
            'Refusing to push: this plan has expired. Re-run Plan.'
        )
    }

    $liveLocalHash = Get-SyncLocalManifestFingerprint -Local $Local
    if (
        -not [string]::Equals(
            [string]$Artifact.localManifestHash,
            $liveLocalHash,
            [System.StringComparison]::Ordinal
        )
    ) {
        throw [System.InvalidOperationException]::new(
            'Refusing to push: LOCAL changed since this plan was created. Re-run Plan.'
        )
    }

    if (
        -not [string]::Equals(
            [string]$Artifact.remoteManifestHashBefore,
            [string]$Snapshot.RemoteManifestHashBefore,
            [System.StringComparison]::Ordinal
        )
    ) {
        throw [System.InvalidOperationException]::new(
            'Refusing to push: REMOTE changed since this plan was created. Re-run Plan.'
        )
    }

    if (
        -not [string]::Equals(
            [string]$Artifact.remoteManifestHashAfter,
            [string]$Snapshot.RemoteManifestHashAfter,
            [System.StringComparison]::Ordinal
        )
    ) {
        throw [System.InvalidOperationException]::new(
            'Refusing to push: REMOTE changed since this plan was created. Re-run Plan.'
        )
    }
}


# ----------------------------------------------------------------------------
# Selection
# ----------------------------------------------------------------------------

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
            return $script:SyncPlanDeleteRemoteBlockedReason
        }
        $script:SyncStatusIgnored {
            return $script:SyncIgnoredReason
        }
        $script:SyncStatusUnchanged {
            return 'BASE, LOCAL, and REMOTE all agree, so there is nothing to push.'
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

function Get-SyncPushSelection {
    # Split the plan artifact into publishable text overwrites and everything
    # else. Pure over the supplied maps except for the hard refusal when a row
    # the plan marked applicable is no longer a clean upload.
    param(
        [Parameter(Mandatory)]
        $Artifact,

        $Base,
        $Local,
        $Remote
    )

    $actions = New-Object 'System.Collections.Generic.List[object]'
    $excluded = New-Object 'System.Collections.Generic.List[object]'

    foreach ($operation in @($Artifact.operations)) {
        $path = [string]$operation.path
        $status = [string]$operation.status
        $applicable = [bool]$operation.applicable

        if ($status -ne $script:SyncStatusUpload -or -not $applicable) {
            $excluded.Add([pscustomobject]@{
                Path       = $path
                Status     = $status
                Reason     = Get-SyncPushExclusionReason -PlanOperation $operation
                Ignored    = [bool]$operation.ignored
                KindChange = [bool]$operation.kindChange
            })

            continue
        }

        $change = Get-SyncPlanChange `
            -Path $path `
            -Base (Get-SyncMapEntry -Map $Base -Path $path) `
            -Local (Get-SyncMapEntry -Map $Local -Path $path) `
            -Remote (Get-SyncMapEntry -Map $Remote -Path $path)
        $liveStatus = [string]$change.Status

        if ($liveStatus -ne $script:SyncStatusUpload) {
            throw [System.InvalidOperationException]::new(
                ("Refusing to push: '{0}' is no longer an upload candidate (now {1}). Re-run Plan." -f $path, $liveStatus)
            )
        }

        if ([bool]$change.KindChange) {
            throw [System.InvalidOperationException]::new(
                ("Refusing to push: '{0}' has an unsupported kind change. Re-run Plan." -f $path)
            )
        }

        $localEntry = Get-SyncMapEntry -Map $Local -Path $path
        $remoteEntry = Get-SyncMapEntry -Map $Remote -Path $path
        $localKind = [string](Get-SyncEntryKind -Entry $localEntry)
        $remoteKind = [string](Get-SyncEntryKind -Entry $remoteEntry)

        if ($localKind -ne 'utf8' -or $remoteKind -ne 'utf8') {
            throw [System.InvalidOperationException]::new(
                ("Refusing to push: '{0}' is not a utf8 text overwrite." -f $path)
            )
        }

        $planLocalSha = [string]$operation.localSha256
        $liveLocalSha = [string](Get-SyncEntrySha256 -Entry $localEntry)
        if (-not (Test-SyncHashEqual -LeftSha256 $planLocalSha -RightSha256 $liveLocalSha)) {
            throw [System.InvalidOperationException]::new(
                ("Refusing to push: LOCAL for '{0}' changed since this plan was created. Re-run Plan." -f $path)
            )
        }

        $expectedRemoteSha = [string]$operation.expectedRemoteHash
        $liveRemoteSha = [string](Get-SyncEntrySha256 -Entry $remoteEntry)
        if ([string]::IsNullOrEmpty($expectedRemoteSha)) {
            throw [System.InvalidOperationException]::new(
                ("Refusing to push: '{0}' has no expectedRemoteHash to verify." -f $path)
            )
        }

        if (-not (Test-SyncHashEqual -LeftSha256 $expectedRemoteSha -RightSha256 $liveRemoteSha)) {
            throw [System.InvalidOperationException]::new(
                ("Refusing to push: REMOTE for '{0}' no longer matches expectedRemoteHash. Re-run Plan." -f $path)
            )
        }

        $actions.Add([pscustomobject]@{
            Path               = $path
            Status             = $status
            Kind               = $localKind
            LocalSha256        = $planLocalSha
            ExpectedRemoteHash = $expectedRemoteSha
            RemoteSha256       = $liveRemoteSha
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
        Actions  = $actionRows
        Excluded = $excludedRows
    }
}


# ----------------------------------------------------------------------------
# Apply one text overwrite
# ----------------------------------------------------------------------------

function Get-LocalUtf8TextForPush {
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath
    )

    $bytes = [System.IO.File]::ReadAllBytes($LiteralPath)
    $utf8 = New-Object System.Text.UTF8Encoding $false
    return $utf8.GetString($bytes)
}

function Get-RemoteFileContentSha256 {
    param(
        [Parameter(Mandatory)]
        $Response
    )

    $bytes = ConvertFrom-RemoteFileContent -Response $Response
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }

    return [System.BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
}

function Assert-SyncPushLocalUnchanged {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$ExpectedSha256,

        [Parameter(Mandatory)]
        [string]$LocalFullPath
    )

    if (-not (Test-Path -LiteralPath $LocalFullPath -PathType Leaf)) {
        throw [System.InvalidOperationException]::new(
            "Local file for '$Path' disappeared after it was scanned. Aborting without writing."
        )
    }

    $actualSha = Get-FileSha256Hex -LiteralPath $LocalFullPath
    if (-not (Test-SyncHashEqual -LeftSha256 $actualSha -RightSha256 $ExpectedSha256)) {
        throw [System.InvalidOperationException]::new(
            "Local file for '$Path' changed since it was scanned. Aborting so the local edit is not published against stale evidence."
        )
    }
}

function Invoke-RundotSyncPushWriteAction {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        $Action,

        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [scriptblock]$GetRemoteFile = $null,

        [scriptblock]$PutRemoteFile = $null
    )

    $path = [string]$Action.Path
    Assert-SyncPathRepresentable -WorkspaceRoot $WorkspaceRoot -CanonicalPath $path

    $localFullPath = ConvertTo-LocalFullPath `
        -WorkspaceRoot $WorkspaceRoot `
        -CanonicalPath $path

    Assert-SyncPushLocalUnchanged `
        -Path $path `
        -ExpectedSha256 ([string]$Action.LocalSha256) `
        -LocalFullPath $localFullPath

    $text = Get-LocalUtf8TextForPush -LiteralPath $localFullPath
    $absolutePath = ConvertTo-StudioAbsoluteApiPath -CanonicalPath $path

    if ($null -eq $GetRemoteFile) {
        $GetRemoteFile = {
            param($Origin, $Id, $ApiPath, $Hdr)
            Get-RemoteProjectFile `
                -StudioOrigin $Origin `
                -ProjectId $Id `
                -Path $ApiPath `
                -Headers $Hdr
        }
    }

    if ($null -eq $PutRemoteFile) {
        $PutRemoteFile = {
            param($Origin, $Id, $Canonical, $BodyText, $Hdr)
            Invoke-RemoteTextPut `
                -StudioOrigin $Origin `
                -ProjectId $Id `
                -CanonicalPath $Canonical `
                -Text $BodyText `
                -Headers $Hdr
        }
    }

    try {
        $remoteResponse = & $GetRemoteFile $StudioOrigin $ProjectId $absolutePath $Headers
    }
    catch {
        if (Test-RemoteNotFoundException -Exception $_.Exception) {
            throw [System.InvalidOperationException]::new(
                ("Refusing to push '{0}': the remote file is gone (404)." -f $path),
                $_.Exception
            )
        }

        throw
    }

    $remoteEncoding = [string](Get-SyncEntryProperty `
        -Entry $remoteResponse `
        -Names @('encoding', 'Encoding'))
    if ($remoteEncoding -ne 'utf8') {
        throw [System.InvalidOperationException]::new(
            ("Refusing to push '{0}': remote content is not utf8." -f $path)
        )
    }

    $remoteSha = Get-RemoteFileContentSha256 -Response $remoteResponse
    if (-not (Test-SyncHashEqual `
            -LeftSha256 $remoteSha `
            -RightSha256 ([string]$Action.ExpectedRemoteHash))) {
        throw [System.InvalidOperationException]::new(
            ("Refusing to push '{0}': REMOTE no longer matches expectedRemoteHash." -f $path)
        )
    }

    $putResponse = & $PutRemoteFile $StudioOrigin $ProjectId $path $text $Headers
    Assert-RemoteTextPutEcho `
        -Response $putResponse `
        -ExpectedSha256 ([string]$Action.LocalSha256)

    $identity = Get-LocalFileIdentity -LiteralPath $localFullPath

    return [pscustomobject]@{
        Path              = $path
        Sha256            = $identity.Sha256
        Size              = $identity.Size
        LocalDetectedKind = $identity.LocalDetectedKind
        LineEnding        = $identity.LineEnding
        HasBom            = $identity.HasBom
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

        [scriptblock]$GetRemoteFile = $null,

        [scriptblock]$PutRemoteFile = $null
    )

    $actionRows = @($Actions)
    $appliedActions = New-Object 'System.Collections.Generic.List[object]'
    $appliedLocals = New-Object 'System.Collections.Generic.List[object]'

    foreach ($action in $actionRows) {
        $appliedLocal = Invoke-RundotSyncPushWriteAction `
            -WorkspaceRoot $WorkspaceRoot `
            -Action $action `
            -StudioOrigin $StudioOrigin `
            -ProjectId $ProjectId `
            -Headers $Headers `
            -GetRemoteFile $GetRemoteFile `
            -PutRemoteFile $PutRemoteFile

        [void]$appliedActions.Add($action)
        [void]$appliedLocals.Add($appliedLocal)
    }

    return [pscustomobject]@{
        AppliedActions = @($appliedActions.ToArray())
        AppliedLocals  = @($appliedLocals.ToArray())
        Applied        = $appliedActions.Count
    }
}


# ----------------------------------------------------------------------------
# Verified BASE update
# ----------------------------------------------------------------------------

function New-RundotSyncPushBaseFiles {
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
            HasBom            = [bool]$applied.HasBom
        }
    }

    return $files
}

function Assert-SyncPushBaseUpdatePreconditions {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [object[]]$AppliedActions
    )

    foreach ($action in @($AppliedActions | Where-Object { $null -ne $_ })) {
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
                -RightSha256 ([string]$action.LocalSha256))) {
            throw [System.InvalidOperationException]::new(
                "Refusing to update BASE: '$path' no longer matches the published content hash."
            )
        }
    }
}

function Update-RundotSyncBaseAfterPush {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [object[]]$AppliedActions,

        [object[]]$AppliedLocals,

        $BaseFiles
    )

    Assert-SyncPushBaseUpdatePreconditions `
        -WorkspaceRoot $WorkspaceRoot `
        -AppliedActions $AppliedActions

    $files = New-RundotSyncPushBaseFiles `
        -BaseFiles $BaseFiles `
        -AppliedLocals $AppliedLocals

    Save-BaseManifest `
        -WorkspaceRoot $WorkspaceRoot `
        -ProjectId $ProjectId `
        -Files $files

    return $files
}


# ----------------------------------------------------------------------------
# Report and orchestration
# ----------------------------------------------------------------------------

function Format-SyncPushReport {
    param(
        $Selection,

        [object[]]$AppliedActions,

        [int]$Applied = 0,

        [object[]]$Skipped = $null,

        [bool]$Cancelled = $false,

        [bool]$BaseUpdated = $false,

        [string]$PlanId = $null
    )

    $lines = New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add('RUN Game Studio Sync - Push')

    if (-not [string]::IsNullOrEmpty($PlanId)) {
        [void]$lines.Add(('planId: {0}' -f $PlanId))
    }

    if ($Cancelled) {
        [void]$lines.Add('')
        [void]$lines.Add('Push cancelled. No remote files were changed and BASE was not updated.')
        return ([string]::Join("`n", $lines.ToArray()))
    }

    $actionRows = @($AppliedActions)
    $skippedRows = @($Skipped)
    if ($null -eq $Skipped -and $null -ne $Selection) {
        $skippedRows = @($Selection.Excluded)
    }

    if ($actionRows.Count -eq 0) {
        [void]$lines.Add('')
        [void]$lines.Add('Nothing to push: no publishable text overwrite remains in this plan.')
        [void]$lines.Add('BASE was not updated.')
    }
    else {
        [void]$lines.Add('')
        [void]$lines.Add('APPLIED')
        foreach ($action in $actionRows) {
            [void]$lines.Add(('  {0}  (overwrite)' -f [string]$action.Path))
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
    [void]$lines.Add(('  applied:      {0}' -f $Applied))
    [void]$lines.Add(('  skipped:      {0}' -f $skippedRows.Count))
    [void]$lines.Add(('  BASE updated: {0}' -f ([bool]$BaseUpdated).ToString().ToLowerInvariant()))

    [void]$lines.Add('')
    [void]$lines.Add('Push writes REMOTE only. It never changes LOCAL files.')
    [void]$lines.Add('WARNING: This tool uses unofficial remote API routes that may change.')

    return ([string]::Join("`n", $lines.ToArray()))
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

        [switch]$ConfirmPush,

        [scriptblock]$GetRemoteFile = $null,

        [scriptblock]$PutRemoteFile = $null
    )

    Assert-RundotSyncPushPlanArtifact `
        -Artifact $Artifact `
        -ProjectId $ProjectId `
        -WorkspaceRoot $WorkspaceRoot `
        -Resolution $Resolution `
        -Local $Local `
        -Snapshot $Snapshot

    $baseMap = Get-SyncPlanBaseMapFromResolution -Resolution $Resolution
    $selection = Get-SyncPushSelection `
        -Artifact $Artifact `
        -Base $baseMap `
        -Local $Local `
        -Remote $Remote

    $actions = @($selection.Actions)
    $planId = [string]$Artifact.planId

    if ($actions.Count -gt 0 -and -not $ConfirmPush) {
        throw [System.InvalidOperationException]::new(
            ("Refusing to push: {0} remote text file(s) would be overwritten. Pass -ConfirmPush to proceed." -f $actions.Count)
        )
    }

    if ($actions.Count -eq 0) {
        return [pscustomobject]@{
            Applied        = 0
            Cancelled      = $false
            BaseUpdated    = $false
            PlanId         = $planId
            Selection      = $selection
            AppliedActions = @()
            Report         = (Format-SyncPushReport `
                -Selection $selection `
                -AppliedActions @() `
                -PlanId $planId)
        }
    }

    $applyResult = Invoke-RundotSyncPushApply `
        -WorkspaceRoot $WorkspaceRoot `
        -Actions $actions `
        -StudioOrigin $StudioOrigin `
        -ProjectId $ProjectId `
        -Headers $Headers `
        -GetRemoteFile $GetRemoteFile `
        -PutRemoteFile $PutRemoteFile

    $baseFiles = $null
    if ($Resolution.Base.PSObject.Properties['files']) {
        $baseFiles = $Resolution.Base.files
    }

    Update-RundotSyncBaseAfterPush `
        -WorkspaceRoot $WorkspaceRoot `
        -ProjectId $ProjectId `
        -AppliedActions $applyResult.AppliedActions `
        -AppliedLocals $applyResult.AppliedLocals `
        -BaseFiles $baseFiles | Out-Null

    return [pscustomobject]@{
        Applied        = [int]$applyResult.Applied
        Cancelled      = $false
        BaseUpdated    = $true
        PlanId         = $planId
        Selection      = $selection
        AppliedActions = @($applyResult.AppliedActions)
        Report         = (Format-SyncPushReport `
            -Selection $selection `
            -AppliedActions $applyResult.AppliedActions `
            -Applied $applyResult.Applied `
            -BaseUpdated $true `
            -PlanId $planId)
    }
}
