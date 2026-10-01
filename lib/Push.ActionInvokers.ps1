# Push.ActionInvokers.ps1 - Per-action invokers (overwrite, create, binary, delete).
#
# Part of the Push split (#70). Loaded by lib/Push.ps1; do not dot-source
# directly. Function bodies are unchanged from the original lib/Push.ps1.

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

function Invoke-RundotSyncPushCreateAction {
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

        [scriptblock]$PutRemoteFile = $null,

        [scriptblock]$InvokeTextCreate = $null
    )

    $path = [string]$Action.Path

    if ($null -eq $InvokeTextCreate) {
        $InvokeTextCreate = {
            param($Ws, $Canonical, $Sha, $Origin, $Id, $Hdr, $GetFile, $PutFile)
            Invoke-RemoteTextCreate `
                -WorkspaceRoot $Ws `
                -CanonicalPath $Canonical `
                -LocalSha256 $Sha `
                -StudioOrigin $Origin `
                -ProjectId $Id `
                -Headers $Hdr `
                -GetRemoteFile $GetFile `
                -PutRemoteFile $PutFile
        }
    }

    return & $InvokeTextCreate `
        $WorkspaceRoot `
        $path `
        ([string]$Action.LocalSha256) `
        $StudioOrigin `
        $ProjectId `
        $Headers `
        $GetRemoteFile `
        $PutRemoteFile
}

function Invoke-RundotSyncPushBinaryAction {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        $Action,

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

        [scriptblock]$GetRemoteFileList = $null,

        [scriptblock]$InvokeBinaryPlace = $null,

        [AllowNull()]
        $LiveLocalManifest = $null
    )

    $path = [string]$Action.Path
    $mode = [string]$Action.Mode

    if ($null -eq $InvokeBinaryPlace) {
        $InvokeBinaryPlace = {
            param($Ws, $Canonical, $Sha, $PlaceMode, $ExpectedRemote, $Art, $Res, $Origin, $Id, $Hdr, $GetFile, $GetList, $LiveLocal)
            Invoke-RemoteBinaryPlace `
                -WorkspaceRoot $Ws `
                -CanonicalPath $Canonical `
                -LocalSha256 $Sha `
                -Mode $PlaceMode `
                -ExpectedRemoteHash $ExpectedRemote `
                -Artifact $Art `
                -Resolution $Res `
                -ProjectId $Id `
                -StudioOrigin $Origin `
                -Headers $Hdr `
                -GetRemoteFile $GetFile `
                -GetRemoteFileList $GetList `
                -LiveLocalManifest $LiveLocal
        }
    }

    $expectedRemote = $null
    if ($mode -eq 'replace') {
        $expectedRemote = [string]$Action.ExpectedRemoteHash
    }

    return & $InvokeBinaryPlace `
        $WorkspaceRoot `
        $path `
        ([string]$Action.LocalSha256) `
        $mode `
        $expectedRemote `
        $Artifact `
        $Resolution `
        $StudioOrigin `
        $ProjectId `
        $Headers `
        $GetRemoteFile `
        $GetRemoteFileList `
        $LiveLocalManifest
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
