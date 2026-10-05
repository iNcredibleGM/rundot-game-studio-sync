# Push.ApplySupport.ps1 - Shared apply primitives (read, verify, backup).
#
# Part of the Push split (#70). Loaded by lib/Push.ps1; do not dot-source
# directly. The read/verify/backup primitives are unchanged from the original
# lib/Push.ps1; the two gates and the partial-count helper are shared by both
# apply paths. The write loop lives in Push.WriteDispatch.ps1.

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

function Get-SyncPushVerifiedBinaryRemoteResponse {
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

    return Get-RemoteBinaryPlaceVerifiedRemoteResponse `
        -Path $Path `
        -ExpectedRemoteHash $ExpectedRemoteHash `
        -StudioOrigin $StudioOrigin `
        -ProjectId $ProjectId `
        -Headers $Headers `
        -GetRemoteFile $GetRemoteFile
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
    $kind = [string]$Action.Kind
    if ([string]::IsNullOrEmpty($kind)) {
        $kind = 'utf8'
    }

    if ($kind -eq 'binary') {
        $remoteResponse = Get-SyncPushVerifiedBinaryRemoteResponse `
            -Path $path `
            -ExpectedRemoteHash ([string]$Action.ExpectedRemoteHash) `
            -StudioOrigin $StudioOrigin `
            -ProjectId $ProjectId `
            -Headers $Headers `
            -GetRemoteFile $GetRemoteFile
    }
    else {
        $remoteResponse = Get-SyncPushVerifiedRemoteResponse `
            -Path $path `
            -ExpectedRemoteHash ([string]$Action.ExpectedRemoteHash) `
            -StudioOrigin $StudioOrigin `
            -ProjectId $ProjectId `
            -Headers $Headers `
            -GetRemoteFile $GetRemoteFile
    }

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

function Assert-SyncPushApplyLocalUnchanged {
    # Pre-write guard shared by both apply paths: every planned local path must
    # still be representable and still match the hash it was selected with.
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [AllowEmptyCollection()]
        [object[]]$Actions
    )

    foreach ($action in @($Actions)) {
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
}

function Get-SyncPushApplyRemotePaths {
    # The live remote list is carried on the delete rows so the delete action
    # never has to re-fetch it. Representability is still asserted for each
    # delete row even when no row carries a list.
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [AllowEmptyCollection()]
        [object[]]$DeleteActions
    )

    $remotePaths = @()
    foreach ($action in @($DeleteActions)) {
        $path = [string]$action.Path
        Assert-SyncPathRepresentable -WorkspaceRoot $WorkspaceRoot -CanonicalPath $path

        if ($null -ne $action.PSObject.Properties['RemotePaths'] -and $null -ne $action.RemotePaths) {
            $remotePaths = @($action.RemotePaths)
            break
        }
    }

    return $remotePaths
}

function New-SyncPushApplyFailure {
    # Wrap an apply-phase failure and carry forward how many paths succeeded
    # before it. The write loop stamps those counts on the exception; a
    # backup-phase failure stamps nothing, so nothing was written.
    param(
        $Exception
    )

    $wrapper = [System.InvalidOperationException]::new(
        ("Push aborted: {0}" -f [string]$Exception.Message),
        $Exception
    )

    $applied = 0
    $created = 0
    $binary = 0
    $deleted = 0
    if ($Exception.Data.Contains('PushAppliedCount')) {
        $applied = [int]$Exception.Data['PushAppliedCount']
    }
    if ($Exception.Data.Contains('PushCreatedCount')) {
        $created = [int]$Exception.Data['PushCreatedCount']
    }
    if ($Exception.Data.Contains('PushBinaryCount')) {
        $binary = [int]$Exception.Data['PushBinaryCount']
    }
    if ($Exception.Data.Contains('PushDeletedCount')) {
        $deleted = [int]$Exception.Data['PushDeletedCount']
    }

    $wrapper.Data['PushAppliedCount'] = $applied
    $wrapper.Data['PushCreatedCount'] = $created
    $wrapper.Data['PushBinaryCount'] = $binary
    $wrapper.Data['PushDeletedCount'] = $deleted

    return $wrapper
}

function Set-SyncPushPartialCounts {
    # A clean-path write failure must still journal what succeeded before it.
    # The counts ride on the exception so the outer apply wrapper can copy them
    # onto the failure record without reaching into the write phase.
    param(
        $Exception,
        [int]$Applied = 0,
        [int]$Created = 0,
        [int]$Binary = 0,
        [int]$Deleted = 0
    )

    if ($null -eq $Exception) {
        return
    }

    $Exception.Data['PushAppliedCount'] = $Applied
    $Exception.Data['PushCreatedCount'] = $Created
    $Exception.Data['PushBinaryCount'] = $Binary
    $Exception.Data['PushDeletedCount'] = $Deleted
}

function Get-SyncPushBinaryCounts {
    param(
        [object[]]$BinaryActions
    )

    $created = 0
    $replaced = 0
    foreach ($action in @($BinaryActions)) {
        if ([string]$action.Mode -eq 'create') {
            $created++
        }
        else {
            $replaced++
        }
    }

    return [pscustomobject]@{ Created = $created; Replaced = $replaced }
}

function Merge-SyncPushAppliedLocals {
    param(
        [object[]]$AppliedLocals,
        [object[]]$CreatedLocals,
        [object[]]$BinaryLocals
    )

    $all = New-Object 'System.Collections.Generic.List[object]'
    foreach ($local in @($AppliedLocals)) { [void]$all.Add($local) }
    foreach ($local in @($CreatedLocals)) { [void]$all.Add($local) }
    foreach ($local in @($BinaryLocals)) { [void]$all.Add($local) }

    return $all
}

function New-SyncPushBackupSet {
    # Reuse the caller's set path when given, otherwise create a fresh set.
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [string]$BackupSetPath
    )

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
    }

    return [pscustomobject]@{
        BackupSet     = $backupSet
        BackupSetPath = [string]$backupSet.Path
    }
}
