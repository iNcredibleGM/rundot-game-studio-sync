# Safe Push: publish clean local text overwrites and confirmed remote deletes.
#
# Push applies two classifications from a verified plan artifact: a clean text
# overwrite (BASE=A LOCAL=B REMOTE=A, utf8 kind, expectedRemoteHash set) and a
# remote delete (BASE=A LOCAL=- REMOTE=A, expectedRemoteHash set, path not
# reserved and not directory-shaped). Creates, binaries, conflicts, and kind
# mismatches are refused.
#
# A delete cannot be made conditional: Studio exposes no ETag or version and
# ignores If-Match (docs/delete-rename-protocol.md), so the guard is a client
# re-read of the remote bytes immediately before the request, plus a backup of
# those bytes first. A 404 after a 200 means the path is already absent, and
# absence is proven from GET /files rather than from a status code.
#
# This file owns three layers:
#
#   1. validation   - plan artifact fingerprints and live state gates
#   2. selection    - which plan rows Push may apply, and why the rest are not
#   3. apply/BASE   - remote backup, per-file GET+PUT with echo verify, DELETE
#                     with absence verify, and the verified BASE update
#
# Callers must load Paths.ps1, Ignore.ps1, Hashing.ps1, Workspace.ps1,
# Manifest.ps1, Snapshot.ps1, Classifier.ps1, Plan.ps1, Backup.ps1, Journal.ps1,
# RemoteApi.ps1, RemoteWrite.ps1, RemoteDelete.ps1, and Push.ps1 first.


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
            return $script:SyncPlanDeleteRemoteRefusalReason
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
            $excluded.Add([pscustomobject]@{
                Path       = $path
                Status     = $status
                Reason     = Get-SyncPushExclusionReason -PlanOperation $operation
                Ignored    = [bool]$operation.ignored
                KindChange = [bool]$operation.kindChange
            })

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
            if ($liveStatus -ne $script:SyncStatusDeleteRemoteCandidate) {
                throw [System.InvalidOperationException]::new(
                    ("Refusing to push: '{0}' is no longer a remote delete candidate (now {1}). Re-run Plan." -f $path, $liveStatus)
                )
            }

            # LOCAL must still be genuinely absent, and REMOTE must still match
            # the verified BASE the plan was computed against. Otherwise the
            # delete would remove content nobody agreed to remove.
            if ($null -ne $localEntry) {
                throw [System.InvalidOperationException]::new(
                    ("Refusing to push: LOCAL for '{0}' reappeared since this plan was created. Re-run Plan." -f $path)
                )
            }

            $baseSha = [string](Get-SyncEntrySha256 -Entry $baseEntry)
            $liveRemoteSha = [string](Get-SyncEntrySha256 -Entry $remoteEntry)
            if (-not (Test-SyncHashEqual -LeftSha256 $baseSha -RightSha256 $liveRemoteSha)) {
                throw [System.InvalidOperationException]::new(
                    ("Refusing to push: REMOTE for '{0}' no longer matches BASE. Re-run Plan." -f $path)
                )
            }

            $expectedRemoteSha = [string]$operation.expectedRemoteHash
            if ([string]::IsNullOrEmpty($expectedRemoteSha)) {
                throw [System.InvalidOperationException]::new(
                    ("Refusing to push: '{0}' has no expectedRemoteHash to verify before DELETE." -f $path)
                )
            }

            if (-not (Test-SyncHashEqual -LeftSha256 $expectedRemoteSha -RightSha256 $liveRemoteSha)) {
                throw [System.InvalidOperationException]::new(
                    ("Refusing to push: REMOTE for '{0}' no longer matches expectedRemoteHash. Re-run Plan." -f $path)
                )
            }

            # Defense in depth: the plan already refused a reserved or
            # directory-shaped path, and the engine refuses it again against
            # the live remote list rather than trusting the artifact.
            Assert-SyncDeletePathAllowed `
                -CanonicalPath $path `
                -RemotePaths $remotePaths

            $deletes.Add([pscustomobject]@{
                Path               = $path
                Status             = $status
                ExpectedRemoteHash = $expectedRemoteSha
                RemoteSha256       = $liveRemoteSha
                RemotePaths        = @($remotePaths)
            })

            continue
        }

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

    $deleteRows = @()
    if ($deletes.Count -gt 0) {
        $deleteRows = $deletes.ToArray()
    }

    $excludedRows = @()
    if ($excluded.Count -gt 0) {
        $excludedRows = $excluded.ToArray()
    }

    return [pscustomobject]@{
        Actions       = $actionRows
        DeleteActions = $deleteRows
        Excluded      = $excludedRows
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

function Get-SyncPushDefaultRemoteFileReader {
    # The real GET used when a caller injects no reader. Shared so the read
    # route cannot drift between the overwrite and delete paths.
    return {
        param($Origin, $Id, $ApiPath, $Hdr)
        Get-RemoteProjectFile `
            -StudioOrigin $Origin `
            -ProjectId $Id `
            -Path $ApiPath `
            -Headers $Hdr
    }
}

function Get-SyncPushVerifiedRemoteResponse {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$ExpectedRemoteHash,

        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [scriptblock]$GetRemoteFile = $null
    )

    $absolutePath = ConvertTo-StudioAbsoluteApiPath -CanonicalPath $Path

    if ($null -eq $GetRemoteFile) {
        $GetRemoteFile = Get-SyncPushDefaultRemoteFileReader
    }

    try {
        $remoteResponse = & $GetRemoteFile $StudioOrigin $ProjectId $absolutePath $Headers
    }
    catch {
        if (Test-RemoteNotFoundException -Exception $_.Exception) {
            throw [System.InvalidOperationException]::new(
                ("Refusing to push '{0}': the remote file is gone (404)." -f $Path),
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
            ("Refusing to push '{0}': remote content is not utf8." -f $Path)
        )
    }

    $remoteSha = Get-RemoteFileContentSha256 -Response $remoteResponse
    if (-not (Test-SyncHashEqual `
            -LeftSha256 $remoteSha `
            -RightSha256 $ExpectedRemoteHash)) {
        throw [System.InvalidOperationException]::new(
            ("Refusing to push '{0}': REMOTE no longer matches expectedRemoteHash." -f $Path)
        )
    }

    return $remoteResponse
}

function Save-RundotSyncPushRemoteBackup {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$BackupSetPath,

        [Parameter(Mandatory)]
        $Action,

        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [scriptblock]$GetRemoteFile = $null,

        [scriptblock]$CopyBackupFile = $null
    )

    $path = [string]$Action.Path
    $remoteResponse = Get-SyncPushVerifiedRemoteResponse `
        -Path $path `
        -ExpectedRemoteHash ([string]$Action.ExpectedRemoteHash) `
        -StudioOrigin $StudioOrigin `
        -ProjectId $ProjectId `
        -Headers $Headers `
        -GetRemoteFile $GetRemoteFile

    $bytes = ConvertFrom-RemoteFileContent -Response $remoteResponse
    $tempRoot = Join-Path (Get-RundotSyncRoot -WorkspaceRoot $WorkspaceRoot) 'temp'
    if (-not (Test-Path -LiteralPath $tempRoot -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
    }

    $tempPath = Join-Path $tempRoot ('push-backup-' + [Guid]::NewGuid().ToString('N') + '.tmp')

    if ($null -eq $CopyBackupFile) {
        $CopyBackupFile = {
            param($SourcePath, $DestinationPath)
            Copy-RundotSyncBackupFile `
                -SourcePath $SourcePath `
                -DestinationPath $DestinationPath
        }
    }

    try {
        [System.IO.File]::WriteAllBytes($tempPath, $bytes)

        $backupPath = Join-Path $BackupSetPath ($path.Replace('/', '\'))
        & $CopyBackupFile $tempPath $backupPath | Out-Null

        $backupSha = Get-FileSha256Hex -LiteralPath $backupPath
        if (-not (Test-SyncHashEqual `
                -LeftSha256 $backupSha `
                -RightSha256 ([string]$Action.ExpectedRemoteHash))) {
            throw [System.InvalidOperationException]::new(
                ("Backup verification failed for '{0}'." -f $path)
            )
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }

    return $backupPath
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

    if ($null -eq $GetRemoteFile) {
        $GetRemoteFile = Get-SyncPushDefaultRemoteFileReader
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

    $null = Get-SyncPushVerifiedRemoteResponse `
        -Path $path `
        -ExpectedRemoteHash ([string]$Action.ExpectedRemoteHash) `
        -StudioOrigin $StudioOrigin `
        -ProjectId $ProjectId `
        -Headers $Headers `
        -GetRemoteFile $GetRemoteFile

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

function Invoke-RundotSyncDeleteAction {
    # Remove exactly one remote file. The order matters and cannot be
    # rearranged: the route is unversioned, so the remote bytes are re-read and
    # compared to expectedRemoteHash immediately before DELETE, and the proof
    # that the file is gone is that GET /files stops listing it.
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

        [AllowNull()]
        [string[]]$RemotePaths,

        [scriptblock]$GetRemoteFile = $null,

        [scriptblock]$DeleteRemoteFile = $null,

        [scriptblock]$GetRemoteFileList = $null
    )

    $path = [string]$Action.Path
    Assert-SyncPathRepresentable -WorkspaceRoot $WorkspaceRoot -CanonicalPath $path

    # Resolve the live remote list when the caller did not supply one, so the
    # directory-shape refusal is never skipped rather than silently passing.
    if ($null -eq $RemotePaths) {
        $RemotePaths = @(Get-RemoteListedFilePaths `
            -StudioOrigin $StudioOrigin `
            -ProjectId $ProjectId `
            -Headers $Headers `
            -GetRemoteFileList $GetRemoteFileList)
    }

    Assert-SyncDeletePathAllowed -CanonicalPath $path -RemotePaths $RemotePaths

    # Re-read the remote bytes and compare to expectedRemoteHash immediately
    # before the request. This is the only guard a delete can have: If-Match is
    # ignored, so the server cannot refuse a stale delete for us.
    $null = Get-SyncPushVerifiedRemoteResponse `
        -Path $path `
        -ExpectedRemoteHash ([string]$Action.ExpectedRemoteHash) `
        -StudioOrigin $StudioOrigin `
        -ProjectId $ProjectId `
        -Headers $Headers `
        -GetRemoteFile $GetRemoteFile

    if ($null -eq $DeleteRemoteFile) {
        $DeleteRemoteFile = {
            param($Origin, $Id, $Canonical, $Hdr)
            Invoke-RemoteDeleteFile `
                -StudioOrigin $Origin `
                -ProjectId $Id `
                -CanonicalPath $Canonical `
                -Headers $Hdr
        }
    }

    try {
        $null = & $DeleteRemoteFile $StudioOrigin $ProjectId $path $Headers
    }
    catch {
        # A 404 after an ambiguous failure means the postcondition already
        # holds. Treat it as already-deleted only when GET /files agrees.
        if (Test-RemoteNotFoundException -Exception $_.Exception) {
            Assert-RemotePathAbsent `
                -StudioOrigin $StudioOrigin `
                -ProjectId $ProjectId `
                -Headers $Headers `
                -CanonicalPath $path `
                -GetRemoteFileList $GetRemoteFileList

            return [pscustomobject]@{
                Path          = $path
                AlreadyAbsent = $true
            }
        }

        throw
    }

    # A 200 is not the proof. Confirm the path is gone from the file list.
    Assert-RemotePathAbsent `
        -StudioOrigin $StudioOrigin `
        -ProjectId $ProjectId `
        -Headers $Headers `
        -CanonicalPath $path `
        -GetRemoteFileList $GetRemoteFileList

    return [pscustomobject]@{
        Path          = $path
        AlreadyAbsent = $false
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

        [scriptblock]$GetRemoteFile = $null,

        [scriptblock]$PutRemoteFile = $null,

        [scriptblock]$DeleteRemoteFile = $null,

        [scriptblock]$GetRemoteFileList = $null,

        [scriptblock]$CopyBackupFile = $null
    )

    $actionRows = @($Actions)
    $deleteRows = @($DeleteActions)

    if ($actionRows.Count -eq 0 -and $deleteRows.Count -eq 0) {
        return [pscustomobject]@{
            AppliedActions = @()
            AppliedLocals  = @()
            DeletedActions = @()
            Applied        = 0
            Deleted        = 0
            BackupSet      = $null
            BackupSetPath  = $null
        }
    }

    $backupSet = $null
    if (-not [string]::IsNullOrEmpty($BackupSetPath)) {
        New-Item -ItemType Directory -Force -Path $BackupSetPath | Out-Null
        $backupSet = [pscustomobject]@{
            Name      = Split-Path -Leaf $BackupSetPath
            Path      = $BackupSetPath
            Timestamp = [DateTime]::UtcNow
        }
    }
    else {
        $backupSet = New-RundotSyncBackupSet -WorkspaceRoot $WorkspaceRoot
        $BackupSetPath = [string]$backupSet.Path
    }

    foreach ($action in $actionRows) {
        $path = [string]$action.Path
        Assert-SyncPathRepresentable -WorkspaceRoot $WorkspaceRoot -CanonicalPath $path

        $localFullPath = ConvertTo-LocalFullPath `
            -WorkspaceRoot $WorkspaceRoot `
            -CanonicalPath $path

        Assert-SyncPushLocalUnchanged `
            -Path $path `
            -ExpectedSha256 ([string]$action.LocalSha256) `
            -LocalFullPath $localFullPath
    }

    $remotePaths = @()
    foreach ($action in $deleteRows) {
        $path = [string]$action.Path
        Assert-SyncPathRepresentable -WorkspaceRoot $WorkspaceRoot -CanonicalPath $path

        if ($null -ne $action.PSObject.Properties['RemotePaths'] -and $null -ne $action.RemotePaths) {
            $remotePaths = @($action.RemotePaths)
            break
        }
    }

    $appliedActions = New-Object 'System.Collections.Generic.List[object]'
    $appliedLocals = New-Object 'System.Collections.Generic.List[object]'
    $deletedActions = New-Object 'System.Collections.Generic.List[object]'

    try {
        # Back up every path first, writes and deletes alike. No DELETE runs
        # until every backup it depends on has verified.
        foreach ($action in $actionRows) {
            Save-RundotSyncPushRemoteBackup `
                -WorkspaceRoot $WorkspaceRoot `
                -BackupSetPath $BackupSetPath `
                -Action $action `
                -StudioOrigin $StudioOrigin `
                -ProjectId $ProjectId `
                -Headers $Headers `
                -GetRemoteFile $GetRemoteFile `
                -CopyBackupFile $CopyBackupFile | Out-Null
        }

        foreach ($action in $deleteRows) {
            Save-RundotSyncPushRemoteBackup `
                -WorkspaceRoot $WorkspaceRoot `
                -BackupSetPath $BackupSetPath `
                -Action $action `
                -StudioOrigin $StudioOrigin `
                -ProjectId $ProjectId `
                -Headers $Headers `
                -GetRemoteFile $GetRemoteFile `
                -CopyBackupFile $CopyBackupFile | Out-Null
        }

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

        foreach ($action in $deleteRows) {
            $deleted = Invoke-RundotSyncDeleteAction `
                -WorkspaceRoot $WorkspaceRoot `
                -Action $action `
                -StudioOrigin $StudioOrigin `
                -ProjectId $ProjectId `
                -Headers $Headers `
                -RemotePaths $remotePaths `
                -GetRemoteFile $GetRemoteFile `
                -DeleteRemoteFile $DeleteRemoteFile `
                -GetRemoteFileList $GetRemoteFileList

            [void]$deletedActions.Add($deleted)
        }
    }
    catch {
        $originalError = $_.Exception
        $wrapper = [System.InvalidOperationException]::new(
            ("Push aborted: {0}" -f [string]$originalError.Message),
            $originalError
        )
        $wrapper.Data['PushAppliedCount'] = $appliedActions.Count
        $wrapper.Data['PushDeletedCount'] = $deletedActions.Count
        throw $wrapper
    }

    return [pscustomobject]@{
        AppliedActions = @($appliedActions.ToArray())
        AppliedLocals  = @($appliedLocals.ToArray())
        DeletedActions = @($deletedActions.ToArray())
        Applied        = $appliedActions.Count
        Deleted        = $deletedActions.Count
        BackupSet      = $backupSet
        BackupSetPath  = $BackupSetPath
    }
}


# ----------------------------------------------------------------------------
# Verified BASE update
# ----------------------------------------------------------------------------

function New-RundotSyncPushBaseFiles {
    param(
        $BaseFiles,
        [object[]]$AppliedLocals,

        [AllowNull()]
        [string[]]$DeletedPaths
    )

    $files = Copy-SyncMapToHashtable -Map $BaseFiles

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

    # A deleted path is dropped from BASE, not tombstoned. The path is now gone
    # from both LOCAL and REMOTE, so a later identical re-create in Studio
    # classifies as a download rather than another delete candidate.
    foreach ($deletedPath in @($DeletedPaths)) {
        if ([string]::IsNullOrEmpty([string]$deletedPath)) {
            continue
        }

        if ($files.ContainsKey([string]$deletedPath)) {
            [void]$files.Remove([string]$deletedPath)
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

        [AllowNull()]
        [string[]]$DeletedPaths,

        $BaseFiles
    )

    Assert-SyncPushBaseUpdatePreconditions `
        -WorkspaceRoot $WorkspaceRoot `
        -AppliedActions $AppliedActions

    $files = New-RundotSyncPushBaseFiles `
        -BaseFiles $BaseFiles `
        -AppliedLocals $AppliedLocals `
        -DeletedPaths $DeletedPaths

    Save-BaseManifest `
        -WorkspaceRoot $WorkspaceRoot `
        -ProjectId $ProjectId `
        -Files $files

    return $files
}


# ----------------------------------------------------------------------------
# Report and orchestration
#
# Invoke-RundotSyncPush is the single entrypoint the CLI calls. It is the only
# layer that decides whether BASE moves, and the only layer that journals.
# ----------------------------------------------------------------------------

function Format-SyncPushReport {
    param(
        $Selection,

        [object[]]$AppliedActions,

        [int]$Applied = 0,

        [object[]]$DeletedActions = $null,

        [int]$Deleted = 0,

        [object[]]$Skipped = $null,

        [bool]$Cancelled = $false,

        [bool]$BaseUpdated = $false,

        [string]$PlanId = $null,

        [string]$BackupRoot = $null,

        [string]$BackupSetPath = $null
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
    $deletedRows = @($DeletedActions)
    $skippedRows = @($Skipped)
    if ($null -eq $Skipped -and $null -ne $Selection) {
        $skippedRows = @($Selection.Excluded)
    }

    if ($actionRows.Count -eq 0 -and $deletedRows.Count -eq 0) {
        [void]$lines.Add('')
        [void]$lines.Add('Nothing to push: no publishable overwrite or confirmed delete remains in this plan.')
        [void]$lines.Add('BASE was not updated.')
    }
    else {
        if ($actionRows.Count -gt 0) {
            [void]$lines.Add('')
            [void]$lines.Add('APPLIED')
            foreach ($action in $actionRows) {
                [void]$lines.Add(('  {0}  (overwrite)' -f [string]$action.Path))
            }
        }

        if ($deletedRows.Count -gt 0) {
            [void]$lines.Add('')
            [void]$lines.Add('DELETED')
            foreach ($action in $deletedRows) {
                [void]$lines.Add(('  {0}  (delete)' -f [string]$action.Path))
            }
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
    [void]$lines.Add(('  deleted:      {0}' -f $Deleted))
    [void]$lines.Add(('  skipped:      {0}' -f $skippedRows.Count))
    [void]$lines.Add(('  BASE updated: {0}' -f ([bool]$BaseUpdated).ToString().ToLowerInvariant()))

    if (-not [string]::IsNullOrEmpty($BackupRoot)) {
        [void]$lines.Add('')
        [void]$lines.Add('BACKUPS')
        [void]$lines.Add(('  backup root: {0}' -f $BackupRoot))
        if (-not [string]::IsNullOrEmpty($BackupSetPath)) {
            [void]$lines.Add(('  this run:    {0}' -f $BackupSetPath))
        }
        [void]$lines.Add('  Restore the previous remote bytes by copying them back from the backup set.')
    }

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

        [scriptblock]$ConfirmOverwrite = $null,

        [scriptblock]$ConfirmDelete = $null,

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

    $baseMap = Get-SyncPlanBaseMapFromResolution -Resolution $Resolution
    $selection = Get-SyncPushSelection `
        -Artifact $Artifact `
        -Base $baseMap `
        -Local $Local `
        -Remote $Remote

    $actions = @($selection.Actions)
    $deleteActions = @($selection.DeleteActions)
    $planId = [string]$Artifact.planId
    $backupRoot = Get-RundotSyncBackupRoot -WorkspaceRoot $WorkspaceRoot

    $cancelledResult = {
        return [pscustomobject]@{
            Applied        = 0
            Deleted        = 0
            Cancelled      = $true
            BaseUpdated    = $false
            PlanId         = $planId
            Selection      = $selection
            AppliedActions = @()
            DeletedActions = @()
            Report         = (Format-SyncPushReport `
                -Selection $selection `
                -AppliedActions @() `
                -Cancelled $true `
                -PlanId $planId)
        }
    }

    # Confirmation before any write or delete. Every confirmation is collected
    # before the first backup, so a decline changes nothing at all.
    if ($actions.Count -gt 0 -and -not $Force) {
        if ($null -eq $ConfirmOverwrite) {
            throw [System.InvalidOperationException]::new(
                ("Refusing to push: {0} remote text file(s) would be overwritten. " -f $actions.Count) +
                'Confirm the overwrite, or pass -ForcePush to proceed. ' +
                'A backup of each remote original is always created first.'
            )
        }

        $confirmed = [bool](& $ConfirmOverwrite $actions.Count @($actions | ForEach-Object { [string]$_.Path }))
        if (-not $confirmed) {
            return (& $cancelledResult)
        }
    }

    # A delete is unrecoverable from Studio, so it gets its own confirmation
    # even when the overwrite half was accepted.
    if ($deleteActions.Count -gt 0 -and -not $Force) {
        if ($null -eq $ConfirmDelete) {
            throw [System.InvalidOperationException]::new(
                ("Refusing to push: {0} remote file(s) would be deleted. " -f $deleteActions.Count) +
                'Confirm the delete, or pass -ForcePush to proceed. ' +
                'A backup of each remote original is always created first.'
            )
        }

        $confirmed = [bool](& $ConfirmDelete $deleteActions.Count @($deleteActions | ForEach-Object { [string]$_.Path }))
        if (-not $confirmed) {
            return (& $cancelledResult)
        }
    }

    if ($actions.Count -eq 0 -and $deleteActions.Count -eq 0) {
        return [pscustomobject]@{
            Applied        = 0
            Deleted        = 0
            Cancelled      = $false
            BaseUpdated    = $false
            PlanId         = $planId
            Selection      = $selection
            AppliedActions = @()
            DeletedActions = @()
            Report         = (Format-SyncPushReport `
                -Selection $selection `
                -AppliedActions @() `
                -PlanId $planId)
        }
    }

    $backupSet = New-RundotSyncBackupSet -WorkspaceRoot $WorkspaceRoot

    try {
        $applyResult = Invoke-RundotSyncPushApply `
            -WorkspaceRoot $WorkspaceRoot `
            -Actions $actions `
            -DeleteActions $deleteActions `
            -StudioOrigin $StudioOrigin `
            -ProjectId $ProjectId `
            -Headers $Headers `
            -BackupSetPath ([string]$backupSet.Path) `
            -GetRemoteFile $GetRemoteFile `
            -PutRemoteFile $PutRemoteFile `
            -DeleteRemoteFile $DeleteRemoteFile `
            -GetRemoteFileList $GetRemoteFileList
    }
    catch {
        $applyError = $_.Exception
        $appliedBeforeFailure = 0
        $deletedBeforeFailure = 0
        if ($applyError.Data.Contains('PushAppliedCount')) {
            $appliedBeforeFailure = [int]$applyError.Data['PushAppliedCount']
        }
        if ($applyError.Data.Contains('PushDeletedCount')) {
            $deletedBeforeFailure = [int]$applyError.Data['PushDeletedCount']
        }

        try {
            Add-RundotSyncJournalRecord `
                -WorkspaceRoot $WorkspaceRoot `
                -Event 'push' `
                -Record @{
                    status      = 'failed'
                    projectId   = $ProjectId
                    planId      = $planId
                    backupSet   = [string]$backupSet.Name
                    applied     = $appliedBeforeFailure
                    overwritten = $appliedBeforeFailure
                    deleted     = $deletedBeforeFailure
                    skipped     = @($selection.Excluded).Count
                    baseUpdated = $false
                    reason      = 'Push failed while writing REMOTE. BASE was not updated. The backup set holds the previous remote bytes.'
                } | Out-Null
        }
        catch {
            # Best effort.
        }

        throw
    }

    $baseFiles = $null
    if ($Resolution.Base.PSObject.Properties['files']) {
        $baseFiles = $Resolution.Base.files
    }

    $deletedPaths = @($applyResult.DeletedActions | ForEach-Object { [string]$_.Path })

    try {
        Update-RundotSyncBaseAfterPush `
            -WorkspaceRoot $WorkspaceRoot `
            -ProjectId $ProjectId `
            -AppliedActions $applyResult.AppliedActions `
            -AppliedLocals $applyResult.AppliedLocals `
            -DeletedPaths $deletedPaths `
            -BaseFiles $baseFiles | Out-Null

        Add-RundotSyncJournalRecord `
            -WorkspaceRoot $WorkspaceRoot `
            -Event 'push' `
            -Record @{
                status      = 'success'
                projectId   = $ProjectId
                planId      = $planId
                backupSet   = [string]$backupSet.Name
                applied     = $applyResult.Applied
                overwritten = $applyResult.Applied
                deleted     = $applyResult.Deleted
                skipped     = @($selection.Excluded).Count
                baseUpdated = $true
            } | Out-Null

        foreach ($action in @($applyResult.AppliedActions)) {
            Add-RundotSyncJournalRecord `
                -WorkspaceRoot $WorkspaceRoot `
                -Event 'push-backup' `
                -Record @{
                    status    = 'success'
                    projectId = $ProjectId
                    planId    = $planId
                    backupSet = [string]$backupSet.Name
                    path      = [string]$action.Path
                } | Out-Null
        }

        foreach ($action in @($applyResult.DeletedActions)) {
            Add-RundotSyncJournalRecord `
                -WorkspaceRoot $WorkspaceRoot `
                -Event 'push-delete' `
                -Record @{
                    status    = 'success'
                    projectId = $ProjectId
                    planId    = $planId
                    backupSet = [string]$backupSet.Name
                    path      = [string]$action.Path
                } | Out-Null
        }
    }
    catch {
        try {
            Add-RundotSyncJournalRecord `
                -WorkspaceRoot $WorkspaceRoot `
                -Event 'push' `
                -Record @{
                    status      = 'failed'
                    projectId   = $ProjectId
                    planId      = $planId
                    backupSet   = [string]$backupSet.Name
                    applied     = $applyResult.Applied
                    overwritten = $applyResult.Applied
                    deleted     = $applyResult.Deleted
                    skipped     = @($selection.Excluded).Count
                    baseUpdated = $false
                    reason      = 'Push applied remote writes, but the verified BASE update did not complete. The previous BASE remains authoritative.'
                } | Out-Null
        }
        catch {
            # Journaling a failure must never mask the failure itself.
        }

        throw
    }

    try {
        [void](Remove-RundotSyncExpiredBackupSets `
            -WorkspaceRoot $WorkspaceRoot `
            -KeepName ([string]$backupSet.Name))
    }
    catch {
        # Retention is best effort.
    }

    return [pscustomobject]@{
        Applied        = [int]$applyResult.Applied
        Deleted        = [int]$applyResult.Deleted
        Cancelled      = $false
        BaseUpdated    = $true
        PlanId         = $planId
        Selection      = $selection
        AppliedActions = @($applyResult.AppliedActions)
        DeletedActions = @($applyResult.DeletedActions)
        BackupSet      = $backupSet
        BackupSetPath  = [string]$backupSet.Path
        BackupSetName  = [string]$backupSet.Name
        BackupRoot     = $backupRoot
        Report         = (Format-SyncPushReport `
            -Selection $selection `
            -AppliedActions $applyResult.AppliedActions `
            -Applied $applyResult.Applied `
            -DeletedActions $applyResult.DeletedActions `
            -Deleted $applyResult.Deleted `
            -BaseUpdated $true `
            -PlanId $planId `
            -BackupRoot $backupRoot `
            -BackupSetPath ([string]$backupSet.Path))
    }
}
