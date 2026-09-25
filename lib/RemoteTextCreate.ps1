# Utf8 text create: upload staging, documented move onto an absent path, PUT /file.
#
# Evidence: docs/text-create-protocol.md (#37). Do not PUT /file before the
# path exists.
#
# Callers must load Paths.ps1, Hashing.ps1, Workspace.ps1, RemoteApi.ps1,
# Snapshot.ps1, RemoteWrite.ps1, RemoteUpload.ps1, RemoteMove.ps1, and
# RemoteDelete.ps1 first.

$script:RemoteTextCreateStagingPathPattern = '^/uploads/rundot-sync-[0-9a-f]{32}(?:-\d+)?\.txt$'

function Test-RemoteTextCreateStagingAbsolutePath {
    param(
        [Parameter(Mandatory)]
        [string]$AbsolutePath
    )

    return [bool]([regex]::IsMatch($AbsolutePath, $script:RemoteTextCreateStagingPathPattern))
}

function New-RemoteTextCreateStagingBasename {
    $guid = [Guid]::NewGuid().ToString('N')
    return "rundot-sync-$guid.txt"
}

function Get-RemoteTextCreateStagingBytes {
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath,

        [Parameter(Mandatory)]
        [string]$ExpectedSha256
    )

    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        throw [System.InvalidOperationException]::new(
            'Local file disappeared before text create staging.'
        )
    }

    $bytes = [System.IO.File]::ReadAllBytes($LiteralPath)
    $actualSha = Get-FileSha256Hex -LiteralPath $LiteralPath
    if (-not (Test-SyncHashEqual -LeftSha256 $actualSha -RightSha256 $ExpectedSha256)) {
        throw [System.InvalidOperationException]::new(
            'Local file changed before text create staging.'
        )
    }

    if ($bytes.Length -eq 0) {
        return [byte[]]([char]'x')
    }

    return $bytes
}

function Assert-RemoteTextCreateDestinationAbsent {
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
        ("Refusing to create '{0}': the remote path appeared. Re-run Plan." -f $CanonicalPath)
    )
}

function Remove-RemoteTextCreateStagingIfAllowed {
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

    if (-not (Test-RemoteTextCreateStagingAbsolutePath -AbsolutePath $StagingAbsolutePath)) {
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

function Invoke-RemoteTextCreate {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$CanonicalPath,

        [Parameter(Mandatory)]
        [string]$LocalSha256,

        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [scriptblock]$GetRemoteFile = $null,

        [scriptblock]$PutRemoteFile = $null
    )

    Assert-SyncPathRepresentable -WorkspaceRoot $WorkspaceRoot -CanonicalPath $CanonicalPath

    $localFullPath = ConvertTo-LocalFullPath `
        -WorkspaceRoot $WorkspaceRoot `
        -CanonicalPath $CanonicalPath

    Assert-SyncPushLocalUnchanged `
        -Path $CanonicalPath `
        -ExpectedSha256 $LocalSha256 `
        -LocalFullPath $localFullPath

    Assert-RemoteTextCreateDestinationAbsent `
        -CanonicalPath $CanonicalPath `
        -StudioOrigin $StudioOrigin `
        -ProjectId $ProjectId `
        -Headers $Headers `
        -GetRemoteFile $GetRemoteFile

    $text = Get-LocalUtf8TextForPush -LiteralPath $localFullPath
    $stagingBytes = Get-RemoteTextCreateStagingBytes `
        -LiteralPath $localFullPath `
        -ExpectedSha256 $LocalSha256
    $stagingName = New-RemoteTextCreateStagingBasename

    $stagingAbsolutePath = $null
    $moveApplied = $false
    $destinationAbsolute = ConvertTo-StudioAbsoluteApiPath -CanonicalPath $CanonicalPath

    try {
        $uploadUrlResponse = Invoke-RemoteUploadUrl `
            -StudioOrigin $StudioOrigin `
            -ProjectId $ProjectId `
            -DeclaredSize $stagingBytes.Length `
            -Headers $Headers

        $minted = Get-RemoteUploadUrlResponseFields -Response $uploadUrlResponse

        Invoke-RemotePresignedObjectPut `
            -UploadUrl $minted.UploadUrl `
            -Bytes $stagingBytes `
            -ContentType 'text/plain' | Out-Null

        $adoptResponse = Invoke-RemoteUploadAdopt `
            -StudioOrigin $StudioOrigin `
            -ProjectId $ProjectId `
            -UploadId $minted.UploadId `
            -Name $stagingName `
            -Headers $Headers

        $stagingAbsolutePath = Get-RemoteUploadAdoptRecordedPath -Response $adoptResponse

        try {
            $null = Invoke-RemoteMove `
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
                    ("Refusing to create '{0}': destination is already occupied (409)." -f $CanonicalPath),
                    $_.Exception
                )
            }

            throw
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

        $putResponse = & $PutRemoteFile $StudioOrigin $ProjectId $CanonicalPath $text $Headers
        Assert-RemoteTextPutEcho `
            -Response $putResponse `
            -ExpectedSha256 $LocalSha256
    }
    catch {
        $original = $_.Exception

        if (-not $moveApplied -and -not [string]::IsNullOrEmpty($stagingAbsolutePath)) {
            Remove-RemoteTextCreateStagingIfAllowed `
                -StagingAbsolutePath $stagingAbsolutePath `
                -StudioOrigin $StudioOrigin `
                -ProjectId $ProjectId `
                -Headers $Headers
        }
        elseif ($moveApplied) {
            $wrapper = [System.InvalidOperationException]::new(
                ("Text create failed after move for '{0}'. The remote path may hold staging bytes; BASE was not updated." -f $CanonicalPath),
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
