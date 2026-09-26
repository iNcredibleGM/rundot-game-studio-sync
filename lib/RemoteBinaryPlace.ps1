# Binary place: staging upload, documented move onto the planned path (#38 / #41).
#
# Evidence: docs/binary-place-protocol.md. Do not PUT /file for binaries.
#
# Callers must load Paths.ps1, Hashing.ps1, Workspace.ps1, Manifest.ps1, Plan.ps1,
# RemoteApi.ps1, Snapshot.ps1, RemoteWrite.ps1, RemoteUpload.ps1, RemoteMove.ps1,
# RemoteDelete.ps1, and Push.ps1 first.

$script:RemoteBinaryPlaceStagingPathPattern = '^/uploads/rundot-sync-[0-9a-f]{32}(?:-\d+)?\.bin$'

function Test-RemoteBinaryPlaceStagingAbsolutePath {
    param(
        [Parameter(Mandatory)]
        [string]$AbsolutePath
    )

    return [bool]([regex]::IsMatch($AbsolutePath, $script:RemoteBinaryPlaceStagingPathPattern))
}

function New-RemoteBinaryPlaceStagingBasename {
    $guid = [Guid]::NewGuid().ToString('N')
    return "rundot-sync-$guid.bin"
}

function Get-RemoteBinaryPlaceExpectedStagingAbsolutePath {
    param(
        [Parameter(Mandatory)]
        [string]$StagingBasename
    )

    return '/uploads/' + $StagingBasename
}

function Assert-RemoteBinaryPlaceDestinationAbsent {
    param(
        [Parameter(Mandatory)]
        [string]$CanonicalPath,

        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [scriptblock]$GetRemoteFile = $null
    )

    $absolutePath = ConvertTo-StudioAbsoluteApiPath -CanonicalPath $CanonicalPath

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

    try {
        $null = & $GetRemoteFile $StudioOrigin $ProjectId $absolutePath $Headers
    }
    catch {
        if (Test-RemoteNotFoundException -Exception $_.Exception) {
            return
        }

        throw
    }

    throw [System.InvalidOperationException]::new(
        ("Refusing to place binary at '{0}': the remote path is occupied. Re-run Plan." -f $CanonicalPath)
    )
}

function Get-RemoteBinaryPlaceVerifiedRemoteResponse {
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
        $GetRemoteFile = {
            param($Origin, $Id, $ApiPath, $Hdr)
            Get-RemoteProjectFile `
                -StudioOrigin $Origin `
                -ProjectId $Id `
                -Path $ApiPath `
                -Headers $Hdr
        }
    }

    try {
        $remoteResponse = & $GetRemoteFile $StudioOrigin $ProjectId $absolutePath $Headers
    }
    catch {
        if (Test-RemoteNotFoundException -Exception $_.Exception) {
            throw [System.InvalidOperationException]::new(
                ("Refusing to replace '{0}': the remote file is gone (404)." -f $Path),
                $_.Exception
            )
        }

        throw
    }

    $remoteEncoding = [string](Get-SyncEntryProperty `
        -Entry $remoteResponse `
        -Names @('encoding', 'Encoding'))
    if ($remoteEncoding -ne 'base64') {
        throw [System.InvalidOperationException]::new(
            ("Refusing to replace '{0}': remote content is not binary (base64)." -f $Path)
        )
    }

    $remoteSha = Get-RemoteFileContentSha256 -Response $remoteResponse
    if (-not (Test-SyncHashEqual `
            -LeftSha256 $remoteSha `
            -RightSha256 $ExpectedRemoteHash)) {
        throw [System.InvalidOperationException]::new(
            ("Refusing to replace '{0}': REMOTE no longer matches expectedRemoteHash." -f $Path)
        )
    }

    return $remoteResponse
}

function Assert-RemoteBinaryPlaceStepGate {
    param(
        [Parameter(Mandatory)]
        $Artifact,

        [Parameter(Mandatory)]
        $Resolution,

        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [string]$CanonicalPath,

        [Parameter(Mandatory)]
        [string]$LocalSha256,

        [Parameter(Mandatory)]
        [ValidateSet('create', 'replaceBeforeDelete', 'replaceAfterDelete')]
        [string]$RemoteCheck,

        [string]$ExpectedRemoteHash = $null,

        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [string]$ProjectIdForRemote,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [scriptblock]$GetRemoteFile = $null
    )

    if ($null -eq $Artifact) {
        throw [System.InvalidOperationException]::new(
            'Refusing to place binary: plan artifact is missing.'
        )
    }

    if (-not [string]::Equals([string]$Artifact.projectId, $ProjectId, [System.StringComparison]::Ordinal)) {
        throw [System.InvalidOperationException]::new(
            'Refusing to place binary: plan projectId does not match this command.'
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
            'Refusing to place binary: plan localRootFingerprint does not match this workspace folder. Re-run Plan.'
        )
    }

    if ($null -eq $Resolution -or $null -eq $Resolution.Base) {
        throw [System.InvalidOperationException]::new(
            'Refusing to place binary: BASE is missing.'
        )
    }

    $baseCapturedAt = $null
    $capturedProperty = $Resolution.Base.PSObject.Properties['capturedAt']
    if ($null -ne $capturedProperty) {
        $baseCapturedAt = [string]$capturedProperty.Value
    }

    if (-not [string]::Equals([string]$Artifact.baseCapturedAt, $baseCapturedAt, [System.StringComparison]::Ordinal)) {
        throw [System.InvalidOperationException]::new(
            'Refusing to place binary: BASE changed since this plan was created. Re-run Plan.'
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
            'Refusing to place binary: this plan has expired. Re-run Plan.'
        )
    }

    $liveLocal = Get-LocalManifest -WorkspaceRoot $WorkspaceRoot
    $liveLocalHash = Get-SyncLocalManifestFingerprint -Local $liveLocal
    if (
        -not [string]::Equals(
            [string]$Artifact.localManifestHash,
            $liveLocalHash,
            [System.StringComparison]::Ordinal
        )
    ) {
        throw [System.InvalidOperationException]::new(
            'Refusing to place binary: LOCAL changed since this plan was created. Re-run Plan.'
        )
    }

    $localFullPath = ConvertTo-LocalFullPath `
        -WorkspaceRoot $WorkspaceRoot `
        -CanonicalPath $CanonicalPath

    Assert-SyncPushLocalUnchanged `
        -Path $CanonicalPath `
        -ExpectedSha256 $LocalSha256 `
        -LocalFullPath $localFullPath

    if ($RemoteCheck -eq 'create' -or $RemoteCheck -eq 'replaceAfterDelete') {
        Assert-RemoteBinaryPlaceDestinationAbsent `
            -CanonicalPath $CanonicalPath `
            -StudioOrigin $StudioOrigin `
            -ProjectId $ProjectIdForRemote `
            -Headers $Headers `
            -GetRemoteFile $GetRemoteFile
    }
    elseif ($RemoteCheck -eq 'replaceBeforeDelete') {
        $null = Get-RemoteBinaryPlaceVerifiedRemoteResponse `
            -Path $CanonicalPath `
            -ExpectedRemoteHash $ExpectedRemoteHash `
            -StudioOrigin $StudioOrigin `
            -ProjectId $ProjectIdForRemote `
            -Headers $Headers `
            -GetRemoteFile $GetRemoteFile
    }
}

function Get-RemoteMoveResponseToAbsolute {
    param(
        [Parameter(Mandatory)]
        $Response
    )

    if ($null -eq $Response) {
        throw [System.InvalidOperationException]::new(
            'Move response was empty.'
        )
    }

    $dataProperty = $Response.PSObject.Properties['data']
    if ($null -ne $dataProperty -and $null -ne $dataProperty.Value) {
        $toProperty = $dataProperty.Value.PSObject.Properties['to']
        if ($null -ne $toProperty -and -not [string]::IsNullOrWhiteSpace([string]$toProperty.Value)) {
            return [string]$toProperty.Value
        }
    }

    $topTo = $Response.PSObject.Properties['to']
    if ($null -ne $topTo -and -not [string]::IsNullOrWhiteSpace([string]$topTo.Value)) {
        return [string]$topTo.Value
    }

    throw [System.InvalidOperationException]::new(
        'Move response did not include a destination path.'
    )
}

function Remove-RemoteBinaryPlaceStagingIfAllowed {
    param(
        [Parameter(Mandatory)]
        [string]$StagingAbsolutePath,

        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    if (-not (Test-RemoteBinaryPlaceStagingAbsolutePath -AbsolutePath $StagingAbsolutePath)) {
        return
    }

    $canonical = $StagingAbsolutePath.TrimStart('/')

    try {
        Invoke-RemoteDeleteFile `
            -StudioOrigin $StudioOrigin `
            -ProjectId $ProjectId `
            -CanonicalPath $canonical `
            -Headers $Headers | Out-Null
    }
    catch {
        # Best effort cleanup only.
    }
}

function Assert-RemoteBinaryPlaceStagingGone {
    param(
        [Parameter(Mandatory)]
        [string]$StagingBasename,

        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [scriptblock]$GetRemoteFile = $null,

        [scriptblock]$GetRemoteFileList = $null
    )

    $stagingCanonical = 'uploads/' + $StagingBasename
    $guidStem = $StagingBasename.Substring('rundot-sync-'.Length)
    $guidStem = $guidStem.Substring(0, $guidStem.Length - '.bin'.Length)

    Assert-RemotePathAbsent `
        -StudioOrigin $StudioOrigin `
        -ProjectId $ProjectId `
        -Headers $Headers `
        -CanonicalPath $stagingCanonical `
        -GetRemoteFileList $GetRemoteFileList

    $stagingAbsolute = Get-RemoteBinaryPlaceExpectedStagingAbsolutePath -StagingBasename $StagingBasename

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

    try {
        $null = & $GetRemoteFile $StudioOrigin $ProjectId $stagingAbsolute $Headers
        throw [System.InvalidOperationException]::new(
            'Staging path still exists after move.'
        )
    }
    catch {
        if (-not (Test-RemoteNotFoundException -Exception $_.Exception)) {
            throw
        }
    }

    $listed = @(Get-RemoteListedFilePaths `
        -StudioOrigin $StudioOrigin `
        -ProjectId $ProjectId `
        -Headers $Headers `
        -GetRemoteFileList $GetRemoteFileList)

    $siblingPattern = '^uploads/rundot-sync-' + [regex]::Escape($guidStem) + '-\d+\.bin$'
    foreach ($path in $listed) {
        if ([regex]::IsMatch([string]$path, $siblingPattern)) {
            throw [System.InvalidOperationException]::new(
                ("A collision sibling '{0}' remains under /uploads." -f $path)
            )
        }
    }
}

function Invoke-RemoteBinaryPlaceSequence {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$CanonicalPath,

        [Parameter(Mandatory)]
        [string]$LocalSha256,

        [Parameter(Mandatory)]
        $Artifact,

        [Parameter(Mandatory)]
        $Resolution,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [scriptblock]$GetRemoteFile = $null,

        [scriptblock]$GetRemoteFileList = $null
    )

    $localFullPath = ConvertTo-LocalFullPath `
        -WorkspaceRoot $WorkspaceRoot `
        -CanonicalPath $CanonicalPath

    $bytes = [System.IO.File]::ReadAllBytes($localFullPath)
    if ($bytes.Length -le 0) {
        throw [System.InvalidOperationException]::new(
            'Refusing to place an empty binary file.'
        )
    }

    $stagingName = New-RemoteBinaryPlaceStagingBasename
    $expectedStagingAbsolute = Get-RemoteBinaryPlaceExpectedStagingAbsolutePath -StagingBasename $stagingName
    $destinationAbsolute = ConvertTo-StudioAbsoluteApiPath -CanonicalPath $CanonicalPath

    $stagingAbsolutePath = $null
    $moveApplied = $false

    try {
        Assert-RemoteBinaryPlaceStepGate `
            -Artifact $Artifact `
            -Resolution $Resolution `
            -WorkspaceRoot $WorkspaceRoot `
            -ProjectId $ProjectId `
            -CanonicalPath $CanonicalPath `
            -LocalSha256 $LocalSha256 `
            -RemoteCheck 'create' `
            -StudioOrigin $StudioOrigin `
            -ProjectIdForRemote $ProjectId `
            -Headers $Headers `
            -GetRemoteFile $GetRemoteFile

        $uploadUrlResponse = Invoke-RemoteUploadUrl `
            -StudioOrigin $StudioOrigin `
            -ProjectId $ProjectId `
            -DeclaredSize $bytes.Length `
            -Headers $Headers

        Assert-RemoteBinaryPlaceStepGate `
            -Artifact $Artifact `
            -Resolution $Resolution `
            -WorkspaceRoot $WorkspaceRoot `
            -ProjectId $ProjectId `
            -CanonicalPath $CanonicalPath `
            -LocalSha256 $LocalSha256 `
            -RemoteCheck 'create' `
            -StudioOrigin $StudioOrigin `
            -ProjectIdForRemote $ProjectId `
            -Headers $Headers `
            -GetRemoteFile $GetRemoteFile

        $minted = Get-RemoteUploadUrlResponseFields -Response $uploadUrlResponse

        Invoke-RemotePresignedObjectPut `
            -UploadUrl $minted.UploadUrl `
            -Bytes $bytes `
            -ContentType 'application/octet-stream' | Out-Null

        Assert-RemoteBinaryPlaceStepGate `
            -Artifact $Artifact `
            -Resolution $Resolution `
            -WorkspaceRoot $WorkspaceRoot `
            -ProjectId $ProjectId `
            -CanonicalPath $CanonicalPath `
            -LocalSha256 $LocalSha256 `
            -RemoteCheck 'create' `
            -StudioOrigin $StudioOrigin `
            -ProjectIdForRemote $ProjectId `
            -Headers $Headers `
            -GetRemoteFile $GetRemoteFile

        $adoptResponse = Invoke-RemoteUploadAdopt `
            -StudioOrigin $StudioOrigin `
            -ProjectId $ProjectId `
            -UploadId $minted.UploadId `
            -Name $stagingName `
            -Headers $Headers

        $stagingAbsolutePath = Get-RemoteUploadAdoptRecordedPath -Response $adoptResponse

        if (-not [string]::Equals($stagingAbsolutePath, $expectedStagingAbsolute, [System.StringComparison]::Ordinal)) {
            Remove-RemoteBinaryPlaceStagingIfAllowed `
                -StagingAbsolutePath $stagingAbsolutePath `
                -StudioOrigin $StudioOrigin `
                -ProjectId $ProjectId `
                -Headers $Headers

            throw [System.InvalidOperationException]::new(
                ("Adopt recorded '{0}' instead of the expected staging path '{1}'." -f $stagingAbsolutePath, $expectedStagingAbsolute)
            )
        }

        Assert-RemoteBinaryPlaceStepGate `
            -Artifact $Artifact `
            -Resolution $Resolution `
            -WorkspaceRoot $WorkspaceRoot `
            -ProjectId $ProjectId `
            -CanonicalPath $CanonicalPath `
            -LocalSha256 $LocalSha256 `
            -RemoteCheck 'create' `
            -StudioOrigin $StudioOrigin `
            -ProjectIdForRemote $ProjectId `
            -Headers $Headers `
            -GetRemoteFile $GetRemoteFile

        try {
            $moveResponse = Invoke-RemoteMove `
                -StudioOrigin $StudioOrigin `
                -ProjectId $ProjectId `
                -FromAbsolute $stagingAbsolutePath `
                -ToAbsolute $destinationAbsolute `
                -Headers $Headers
            $moveApplied = $true
        }
        catch {
            $status = Get-RemoteHttpStatusCode -Exception $_.Exception
            if ($status -eq 409) {
                throw [System.InvalidOperationException]::new(
                    ("Refusing to place binary at '{0}': destination is already occupied (409)." -f $CanonicalPath),
                    $_.Exception
                )
            }

            throw
        }

        $actualTo = Get-RemoteMoveResponseToAbsolute -Response $moveResponse
        if (-not [string]::Equals($actualTo, $destinationAbsolute, [System.StringComparison]::Ordinal)) {
            throw [System.InvalidOperationException]::new(
                ("Move landed at '{0}' instead of the planned path '{1}'." -f $actualTo, $destinationAbsolute)
            )
        }

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

        $destResponse = & $GetRemoteFile $StudioOrigin $ProjectId $destinationAbsolute $Headers
        $destEncoding = [string](Get-SyncEntryProperty `
            -Entry $destResponse `
            -Names @('encoding', 'Encoding'))
        if ($destEncoding -ne 'base64') {
            throw [System.InvalidOperationException]::new(
                ("Placed file at '{0}' is not binary (base64)." -f $CanonicalPath)
            )
        }

        $destSha = Get-RemoteFileContentSha256 -Response $destResponse
        if (-not (Test-SyncHashEqual -LeftSha256 $destSha -RightSha256 $LocalSha256)) {
            throw [System.InvalidOperationException]::new(
                ("Placed file at '{0}' does not match the local hash." -f $CanonicalPath)
            )
        }

        Assert-RemoteBinaryPlaceStagingGone `
            -StagingBasename $stagingName `
            -StudioOrigin $StudioOrigin `
            -ProjectId $ProjectId `
            -Headers $Headers `
            -GetRemoteFile $GetRemoteFile `
            -GetRemoteFileList $GetRemoteFileList
    }
    catch {
        $original = $_.Exception

        if (-not $moveApplied -and -not [string]::IsNullOrEmpty($stagingAbsolutePath)) {
            Remove-RemoteBinaryPlaceStagingIfAllowed `
                -StagingAbsolutePath $stagingAbsolutePath `
                -StudioOrigin $StudioOrigin `
                -ProjectId $ProjectId `
                -Headers $Headers
        }
        elseif ($moveApplied) {
            $wrapper = [System.InvalidOperationException]::new(
                ("Binary place failed after move for '{0}'. The remote path may hold the new bytes; BASE was not updated." -f $CanonicalPath),
                $original
            )
            throw $wrapper
        }

        throw
    }

    $identity = Get-LocalFileIdentity -LiteralPath $localFullPath

    return [pscustomobject]@{
        Path              = $CanonicalPath
        Sha256            = $identity.Sha256
        Size              = $identity.Size
        LocalDetectedKind = $identity.LocalDetectedKind
        LineEnding        = $identity.LineEnding
        HasBom            = $identity.HasBom
    }
}

function Invoke-RemoteBinaryPlace {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$CanonicalPath,

        [Parameter(Mandatory)]
        [string]$LocalSha256,

        [Parameter(Mandatory)]
        [ValidateSet('create', 'replace')]
        [string]$Mode,

        [string]$ExpectedRemoteHash = $null,

        [Parameter(Mandatory)]
        $Artifact,

        [Parameter(Mandatory)]
        $Resolution,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [scriptblock]$GetRemoteFile = $null,

        [scriptblock]$GetRemoteFileList = $null
    )

    Assert-SyncPathRepresentable -WorkspaceRoot $WorkspaceRoot -CanonicalPath $CanonicalPath

    $placeRefusal = Get-SyncBinaryPlacePathRefusalReason `
        -CanonicalPath $CanonicalPath `
        -RemotePaths @()

    if (-not [string]::IsNullOrEmpty($placeRefusal)) {
        throw [System.InvalidOperationException]::new(
            ("Refusing to place '{0}': {1}" -f $CanonicalPath, $placeRefusal)
        )
    }

    if ($Mode -eq 'replace') {
        if ([string]::IsNullOrEmpty($ExpectedRemoteHash)) {
            throw [System.InvalidOperationException]::new(
                ("Refusing to replace '{0}': expectedRemoteHash is missing." -f $CanonicalPath)
            )
        }

        Assert-RemoteBinaryPlaceStepGate `
            -Artifact $Artifact `
            -Resolution $Resolution `
            -WorkspaceRoot $WorkspaceRoot `
            -ProjectId $ProjectId `
            -CanonicalPath $CanonicalPath `
            -LocalSha256 $LocalSha256 `
            -RemoteCheck 'replaceBeforeDelete' `
            -ExpectedRemoteHash $ExpectedRemoteHash `
            -StudioOrigin $StudioOrigin `
            -ProjectIdForRemote $ProjectId `
            -Headers $Headers `
            -GetRemoteFile $GetRemoteFile

        Invoke-RemoteDeleteFile `
            -StudioOrigin $StudioOrigin `
            -ProjectId $ProjectId `
            -CanonicalPath $CanonicalPath `
            -Headers $Headers | Out-Null

        Assert-RemotePathAbsent `
            -StudioOrigin $StudioOrigin `
            -ProjectId $ProjectId `
            -Headers $Headers `
            -CanonicalPath $CanonicalPath `
            -GetRemoteFileList $GetRemoteFileList

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

        try {
            $null = & $GetRemoteFile $StudioOrigin $ProjectId (ConvertTo-StudioAbsoluteApiPath -CanonicalPath $CanonicalPath) $Headers
            throw [System.InvalidOperationException]::new(
                ("Refusing to replace '{0}': remote path still exists after DELETE." -f $CanonicalPath)
            )
        }
        catch {
            if (-not (Test-RemoteNotFoundException -Exception $_.Exception)) {
                throw
            }
        }
    }

    return Invoke-RemoteBinaryPlaceSequence `
        -WorkspaceRoot $WorkspaceRoot `
        -CanonicalPath $CanonicalPath `
        -LocalSha256 $LocalSha256 `
        -Artifact $Artifact `
        -Resolution $Resolution `
        -ProjectId $ProjectId `
        -StudioOrigin $StudioOrigin `
        -Headers $Headers `
        -GetRemoteFile $GetRemoteFile `
        -GetRemoteFileList $GetRemoteFileList
}
