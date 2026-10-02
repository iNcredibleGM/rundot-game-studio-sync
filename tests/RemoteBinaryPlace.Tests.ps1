# Binary place staging path predicate, adopt-path, and post-move failure contracts.
#
# Do not require Pester. No network.

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "lib\Paths.ps1")
. (Join-Path $repoRoot "lib\Ignore.ps1")
. (Join-Path $repoRoot "lib\Hashing.ps1")
. (Join-Path $repoRoot "lib\Progress.ps1")
. (Join-Path $repoRoot "lib\Workspace.ps1")
. (Join-Path $repoRoot "lib\Manifest.ps1")
. (Join-Path $repoRoot "lib\Classifier.ps1")
. (Join-Path $repoRoot "lib\Format.ps1")
. (Join-Path $repoRoot "lib\Plan.ps1")
. (Join-Path $repoRoot "lib\RemoteApi.ps1")
. (Join-Path $repoRoot "lib\Snapshot.ps1")
. (Join-Path $repoRoot "lib\RemoteWrite.ps1")
. (Join-Path $repoRoot "lib\RemoteUpload.ps1")
. (Join-Path $repoRoot "lib\RemoteMove.ps1")
. (Join-Path $repoRoot "lib\RemoteDelete.ps1")
. (Join-Path $repoRoot "lib\Push.ps1")
. (Join-Path $repoRoot "lib\RemoteBinaryPlace.ps1")

Assert-True `
    (Test-RemoteBinaryPlaceStagingAbsolutePath -AbsolutePath '/uploads/rundot-sync-0123456789abcdef0123456789abcdef.bin') `
    "the primary staging path shape must be accepted"

Assert-True `
    (Test-RemoteBinaryPlaceStagingAbsolutePath -AbsolutePath '/uploads/rundot-sync-0123456789abcdef0123456789abcdef-1.bin') `
    "a collision sibling staging path must be accepted"

Assert-True `
    (-not (Test-RemoteBinaryPlaceStagingAbsolutePath -AbsolutePath '/src/logo.png')) `
    "a project path must not count as staging"

$expected = Get-RemoteBinaryPlaceExpectedStagingAbsolutePath -StagingBasename 'rundot-sync-0123456789abcdef0123456789abcdef.bin'
Assert-Equal '/uploads/rundot-sync-0123456789abcdef0123456789abcdef.bin' $expected `
    "the expected staging absolute path must match the basename"

$movePayload = [pscustomobject]@{
    success = $true
    data    = [pscustomobject]@{
        from = '/uploads/rundot-sync-0123456789abcdef0123456789abcdef.bin'
        to   = '/public/logo.png'
    }
}
Assert-Equal '/public/logo.png' (Get-RemoteMoveResponseToAbsolute -Response $movePayload) `
    "move response data.to must be read"

# ---------------------------------------------------------------------------
# Post-move failure must name the check that actually failed (#51)
# ---------------------------------------------------------------------------

# Get-SyncFailureReason is the shared flattener: the innermost message, with
# whitespace collapsed, so a REFUSED report row stays one line.
$innerWithNewlines = [System.InvalidOperationException]::new(
    "Placed file at 'public/logo.png' does not match the local hash.`nRefusing."
)
Assert-Equal `
    "Placed file at 'public/logo.png' does not match the local hash. Refusing." `
    (Get-SyncFailureReason -Exception $innerWithNewlines) `
    "the innermost failure reason must collapse to a single line"

$nested = [System.InvalidOperationException]::new(
    'outer',
    [System.InvalidOperationException]::new("  inner`r`n  cause  ")
)
Assert-Equal 'inner cause' (Get-SyncFailureReason -Exception $nested) `
    "Get-SyncFailureReason must return the innermost message on one line"

Assert-Equal '' (Get-SyncFailureReason -Exception $null) `
    "Get-SyncFailureReason must tolerate a missing exception"

# The wrapper keeps its ambiguous-state summary and appends the inner cause.
$wrapper = New-RemotePlaceAfterMoveFailure `
    -Summary "Binary place failed after move for 'public/logo.png'. The remote path may hold the new bytes; BASE was not updated." `
    -Cause $innerWithNewlines

Assert-True `
    ($wrapper.Message -match 'Verify failure: Placed file .* does not match the local hash') `
    "the post-move wrapper must surface the inner verify failure in its message"

Assert-True `
    ($wrapper.Message -match 'may hold the new bytes') `
    "the post-move wrapper must keep the ambiguous-state summary"

Assert-True `
    ($wrapper.Message -notmatch "[`r`n]") `
    "the post-move wrapper message must stay one line"

Assert-True `
    ([object]::ReferenceEquals($wrapper.InnerException, $innerWithNewlines)) `
    "the post-move wrapper must preserve the original cause as InnerException"

# A cause with no message leaves the summary alone rather than adding an empty
# suffix.
$bareWrapper = New-RemotePlaceAfterMoveFailure `
    -Summary 'Binary place failed after move for public/logo.png.' `
    -Cause ([System.InvalidOperationException]::new('   '))
Assert-Equal 'Binary place failed after move for public/logo.png.' $bareWrapper.Message `
    "a cause with no message must not append a dangling 'Verify failure:' suffix"

# A nested cause is surfaced, not just the first level.
$nestedCause = [System.InvalidOperationException]::new(
    'Placed file is not binary (base64).',
    [System.InvalidOperationException]::new('encoding mismatch')
)
$nestedFailure = New-RemotePlaceAfterMoveFailure `
    -Summary 'Binary place failed after move.' `
    -Cause $nestedCause
Assert-True `
    ($nestedFailure.Message -match 'encoding mismatch') `
    "the innermost cause must be surfaced"


# ---------------------------------------------------------------------------
# The step gate reuses the run's local manifest instead of re-hashing (#59)
# ---------------------------------------------------------------------------
#
# A place calls the step gate four times. Each gate must fingerprint the
# manifest the run already computed rather than re-hashing the whole workspace,
# or a large publish cannot fit the plan TTL. This counts the full-manifest
# computations by wrapping Get-LocalManifest around the gate.

$manifestReuseRoot = Join-Path $env:TEMP ("rundot-place-manifest-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $manifestReuseRoot | Out-Null

try {
    $reuseProjectId = 'proj-place-manifest'
    $reuseOrigin = 'https://example.invalid'
    $reusePath = 'public/logo.png'
    $reuseBytes = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03)
    $reuseLocalPath = Join-Path $manifestReuseRoot $reusePath.Replace('/', '\')
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $reuseLocalPath) | Out-Null
    [System.IO.File]::WriteAllBytes($reuseLocalPath, $reuseBytes)

    $reuseLocalSha = Get-FileSha256Hex -LiteralPath $reuseLocalPath
    $reuseLocalMap = @{
        $reusePath = [pscustomobject]@{
            Sha256            = $reuseLocalSha
            Size              = $reuseBytes.Length
            LocalDetectedKind = 'binary'
            LineEnding        = $null
            HasBom            = $null
        }
    }

    $reuseResolution = [pscustomobject]@{
        Base        = [pscustomobject]@{ capturedAt = '2026-09-14T12:00:00.0000000Z'; files = @{} }
        BasePresent = $true
        Untrusted   = $false
    }
    $reuseSnapshot = [pscustomobject]@{
        RemoteManifestHashBefore = ('b' * 64)
        RemoteManifestHashAfter  = ('b' * 64)
    }

    $reuseArtifact = New-RundotSyncPlanArtifact `
        -WorkspaceRoot $manifestReuseRoot `
        -ProjectId $reuseProjectId `
        -Resolution $reuseResolution `
        -Local $reuseLocalMap `
        -Remote @{} `
        -Snapshot $reuseSnapshot

    # The run's manifest, exactly as Push computes it once.
    $runManifest = Get-LocalManifest -WorkspaceRoot $manifestReuseRoot

    # The destination is absent: the gate's create check expects a 404.
    $reuseGetRemote = {
        param($Origin, $Id, $ApiPath, $Hdr)
        $notFound = [System.InvalidOperationException]::new("Remote request failed with HTTP 404 for '$ApiPath'.")
        $notFound.Data['HttpStatusCode'] = 404
        throw $notFound
    }

    # Count full-manifest computations by wrapping Get-LocalManifest. The
    # wrapper must call the captured original, not the name, or it recurses.
    $script:ManifestReuseCount = 0
    $originalGetLocalManifest = ${function:Get-LocalManifest}
    $manifestReuseWrapper = {
        param($WorkspaceRoot, [switch]$ShowProgress)
        $script:ManifestReuseCount++
        return (& $originalGetLocalManifest -WorkspaceRoot $WorkspaceRoot -ShowProgress:$ShowProgress)
    }

    try {
        Set-Item -Path 'function:Get-LocalManifest' -Value $manifestReuseWrapper

        # Four gates, the same count one place performs, all given the run's
        # manifest: none may re-hash the workspace.
        foreach ($step in 1..4) {
            Assert-RemoteBinaryPlaceStepGate `
                -Artifact $reuseArtifact `
                -Resolution $reuseResolution `
                -WorkspaceRoot $manifestReuseRoot `
                -ProjectId $reuseProjectId `
                -CanonicalPath $reusePath `
                -LocalSha256 $reuseLocalSha `
                -RemoteCheck 'create' `
                -StudioOrigin $reuseOrigin `
                -ProjectIdForRemote $reuseProjectId `
                -Headers @{} `
                -GetRemoteFile $reuseGetRemote `
                -LiveLocalManifest $runManifest
        }

        Assert-Equal 0 $script:ManifestReuseCount `
            "four gates given the run's manifest must not re-hash the workspace at all (#59)"

        # Without a supplied manifest the gate must still hash once, so a direct
        # caller outside a Push run keeps its check rather than silently passing.
        Assert-RemoteBinaryPlaceStepGate `
            -Artifact $reuseArtifact `
            -Resolution $reuseResolution `
            -WorkspaceRoot $manifestReuseRoot `
            -ProjectId $reuseProjectId `
            -CanonicalPath $reusePath `
            -LocalSha256 $reuseLocalSha `
            -RemoteCheck 'create' `
            -StudioOrigin $reuseOrigin `
            -ProjectIdForRemote $reuseProjectId `
            -Headers @{} `
            -GetRemoteFile $reuseGetRemote

        Assert-Equal 1 $script:ManifestReuseCount `
            "a gate with no supplied manifest must still hash the workspace once"

        # A stale supplied manifest must still be refused: reuse must not weaken
        # the LOCAL-changed check.
        $staleManifest = @{
            $reusePath = [pscustomobject]@{
                Sha256            = ('0' * 64)
                Size              = $reuseBytes.Length
                LocalDetectedKind = 'binary'
                LineEnding        = $null
                HasBom            = $null
            }
        }

        $staleThrew = $false
        try {
            Assert-RemoteBinaryPlaceStepGate `
                -Artifact $reuseArtifact `
                -Resolution $reuseResolution `
                -WorkspaceRoot $manifestReuseRoot `
                -ProjectId $reuseProjectId `
                -CanonicalPath $reusePath `
                -LocalSha256 $reuseLocalSha `
                -RemoteCheck 'create' `
                -StudioOrigin $reuseOrigin `
                -ProjectIdForRemote $reuseProjectId `
                -Headers @{} `
                -GetRemoteFile $reuseGetRemote `
                -LiveLocalManifest $staleManifest
        }
        catch {
            $staleThrew = $true
        }

        Assert-True $staleThrew "a supplied manifest that does not match the plan must still refuse"
    }
    finally {
        Set-Item -Path 'function:Get-LocalManifest' -Value $originalGetLocalManifest
    }
}
finally {
    if (Test-Path -LiteralPath $manifestReuseRoot) {
        Remove-Item -LiteralPath $manifestReuseRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}


# ---------------------------------------------------------------------------
# A whole place RUN reuses the run's manifest (#75)
# ---------------------------------------------------------------------------
#
# The gate-level test above calls the gate directly. This one drives a real
# create through Invoke-RemoteBinaryPlace and counts Get-LocalManifest, so it
# also fails if the -LiveLocalManifest parameter is dropped anywhere between
# Push and the gate, not only if the gate ignores it.

$placeRunRoot = Join-Path $env:TEMP ("rundot-place-run-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $placeRunRoot | Out-Null

try {
    $placeRunProjectId = 'proj-place-run'
    $placeRunOrigin = 'https://example.invalid'
    $placeRunPath = 'public/logo.png'
    $placeRunBytes = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x11, 0x22, 0x33)
    $placeRunLocalPath = Join-Path $placeRunRoot $placeRunPath.Replace('/', '\')
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $placeRunLocalPath) | Out-Null
    [System.IO.File]::WriteAllBytes($placeRunLocalPath, $placeRunBytes)

    $placeRunSha = Get-FileSha256Hex -LiteralPath $placeRunLocalPath
    $placeRunLocalMap = @{
        $placeRunPath = [pscustomobject]@{
            Sha256            = $placeRunSha
            Size              = $placeRunBytes.Length
            LocalDetectedKind = 'binary'
            LineEnding        = $null
            HasBom            = $null
        }
    }

    $placeRunResolution = [pscustomobject]@{
        Base        = [pscustomobject]@{ capturedAt = '2026-09-14T12:00:00.0000000Z'; files = @{} }
        BasePresent = $true
        Untrusted   = $false
    }
    $placeRunSnapshot = [pscustomobject]@{
        RemoteManifestHashBefore = ('b' * 64)
        RemoteManifestHashAfter  = ('b' * 64)
    }

    $placeRunArtifact = New-RundotSyncPlanArtifact `
        -WorkspaceRoot $placeRunRoot `
        -ProjectId $placeRunProjectId `
        -Resolution $placeRunResolution `
        -Local $placeRunLocalMap `
        -Remote @{} `
        -Snapshot $placeRunSnapshot

    # The run's manifest, exactly as Push computes it once.
    $placeRunManifest = Get-LocalManifest -WorkspaceRoot $placeRunRoot

    $placeRunDestinationAbsolute = ConvertTo-StudioAbsoluteApiPath -CanonicalPath $placeRunPath

    # A tiny in-memory remote that models only what the create sequence needs:
    # the destination is absent until the move lands, then holds the local
    # bytes; every staging path stays absent.
    $placeRunState = [pscustomobject]@{ Moved = $false }
    $placeRunGetRemote = {
        param($Origin, $Id, $ApiPath, $Hdr)
        if ($ApiPath -eq $placeRunDestinationAbsolute -and $placeRunState.Moved) {
            return [pscustomobject]@{
                encoding = 'base64'
                content  = [System.Convert]::ToBase64String($placeRunBytes)
            }
        }

        $notFound = [System.InvalidOperationException]::new("Remote request failed with HTTP 404 for '$ApiPath'.")
        $notFound.Data['HttpStatusCode'] = 404
        throw $notFound
    }
    $placeRunGetRemoteList = {
        param($Origin, $Id, $Hdr)
        return [pscustomobject]@{ files = @() }
    }

    # The place sequence reaches the upload and move routes through functions
    # that take no injectable callback, so stub them for the duration and
    # restore every one in the finally.
    $originalUploadUrl = ${function:Invoke-RemoteUploadUrl}
    $originalPresignedPut = ${function:Invoke-RemotePresignedObjectPut}
    $originalUploadAdopt = ${function:Invoke-RemoteUploadAdopt}
    $originalRemoteMove = ${function:Invoke-RemoteMove}

    $stubUploadUrl = {
        param($StudioOrigin, $ProjectId, [int64]$DeclaredSize, [hashtable]$Headers)
        return [pscustomobject]@{ uploadUrl = 'https://example.invalid/presigned'; uploadId = 'upload-1' }
    }
    $stubPresignedPut = {
        param($UploadUrl, [byte[]]$Bytes, [string]$ContentType = 'text/plain')
        return 'unused-for-a-small-file'
    }
    $stubUploadAdopt = {
        param($StudioOrigin, $ProjectId, $UploadId, $Name, [hashtable]$Headers)
        return [pscustomobject]@{ path = ('/uploads/' + $Name) }
    }
    $stubRemoteMove = {
        param($StudioOrigin, $ProjectId, $FromAbsolute, $ToAbsolute, [hashtable]$Headers)
        $placeRunState.Moved = $true
        return [pscustomobject]@{ success = $true; data = [pscustomobject]@{ from = $FromAbsolute; to = $ToAbsolute } }
    }

    $originalGetLocalManifest = ${function:Get-LocalManifest}
    $manifestCounter = {
        param($WorkspaceRoot, [switch]$ShowProgress)
        $script:PlaceRunManifestCount++
        return (& $originalGetLocalManifest -WorkspaceRoot $WorkspaceRoot -ShowProgress:$ShowProgress)
    }

    try {
        Set-Item -Path 'function:Invoke-RemoteUploadUrl' -Value $stubUploadUrl
        Set-Item -Path 'function:Invoke-RemotePresignedObjectPut' -Value $stubPresignedPut
        Set-Item -Path 'function:Invoke-RemoteUploadAdopt' -Value $stubUploadAdopt
        Set-Item -Path 'function:Invoke-RemoteMove' -Value $stubRemoteMove
        Set-Item -Path 'function:Get-LocalManifest' -Value $manifestCounter

        # One create given the run's manifest: four gates, zero re-hashes.
        $script:PlaceRunManifestCount = 0
        $placeRunState.Moved = $false
        $placed = Invoke-RemoteBinaryPlace `
            -WorkspaceRoot $placeRunRoot `
            -CanonicalPath $placeRunPath `
            -LocalSha256 $placeRunSha `
            -Mode 'create' `
            -Artifact $placeRunArtifact `
            -Resolution $placeRunResolution `
            -ProjectId $placeRunProjectId `
            -StudioOrigin $placeRunOrigin `
            -Headers @{} `
            -GetRemoteFile $placeRunGetRemote `
            -GetRemoteFileList $placeRunGetRemoteList `
            -LiveLocalManifest $placeRunManifest

        Assert-Equal $placeRunSha ([string]$placed.Sha256) `
            'a place run must report the placed file identity (#75)'
        Assert-Equal 0 $script:PlaceRunManifestCount `
            'a place run given the run manifest must not re-hash the workspace (#75)'

        # The same create without a manifest still falls back, and that fallback
        # re-reads the tree once per gate: a create calls the gate four times,
        # so this is the per-binary cost #59 removed (4 vs 0). The gate-level
        # test above pins the single-gate fallback at exactly one.
        $script:PlaceRunManifestCount = 0
        $placeRunState.Moved = $false
        $null = Invoke-RemoteBinaryPlace `
            -WorkspaceRoot $placeRunRoot `
            -CanonicalPath $placeRunPath `
            -LocalSha256 $placeRunSha `
            -Mode 'create' `
            -Artifact $placeRunArtifact `
            -Resolution $placeRunResolution `
            -ProjectId $placeRunProjectId `
            -StudioOrigin $placeRunOrigin `
            -Headers @{} `
            -GetRemoteFile $placeRunGetRemote `
            -GetRemoteFileList $placeRunGetRemoteList

        Assert-Equal 4 $script:PlaceRunManifestCount `
            'a place run with no supplied manifest must still re-read the tree, once per gate (#75)'
    }
    finally {
        Set-Item -Path 'function:Invoke-RemoteUploadUrl' -Value $originalUploadUrl
        Set-Item -Path 'function:Invoke-RemotePresignedObjectPut' -Value $originalPresignedPut
        Set-Item -Path 'function:Invoke-RemoteUploadAdopt' -Value $originalUploadAdopt
        Set-Item -Path 'function:Invoke-RemoteMove' -Value $originalRemoteMove
        Set-Item -Path 'function:Get-LocalManifest' -Value $originalGetLocalManifest
    }
}
finally {
    if (Test-Path -LiteralPath $placeRunRoot) {
        Remove-Item -LiteralPath $placeRunRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}


# ---------------------------------------------------------------------------
# Push threads the run's manifest to the place gate (#75)
# ---------------------------------------------------------------------------
#
# The run-level test above proves the place sequence reuses a manifest it is
# given. These two prove Push actually gives it: a refactor that drops the
# -LiveLocalManifest parameter along the Push -> PushApply -> PushBinaryAction
# chain would leave both tests above green while the per-binary re-hash came
# back, so the parameter is captured and compared by reference.

$threadRoot = Join-Path $env:TEMP ("rundot-place-thread-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $threadRoot | Out-Null

try {
    $threadWorkspace = Join-Path $threadRoot 'ws'
    New-Item -ItemType Directory -Force -Path $threadWorkspace | Out-Null
    Initialize-RundotSyncLayout -WorkspaceRoot $threadWorkspace

    $threadProjectId = 'proj-place-thread'
    $threadOrigin = 'https://example.invalid'
    $threadPath = 'public/thread.png'
    $threadBytes = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x44, 0x55, 0x66)
    $threadLocalPath = Join-Path $threadWorkspace $threadPath.Replace('/', '\')
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $threadLocalPath) | Out-Null
    [System.IO.File]::WriteAllBytes($threadLocalPath, $threadBytes)
    $threadSha = Get-FileSha256Hex -LiteralPath $threadLocalPath

    $threadResolution = [pscustomobject]@{
        Base        = [pscustomobject]@{ capturedAt = '2026-09-14T12:00:00.0000000Z'; files = @{} }
        BasePresent = $true
        Untrusted   = $false
    }
    $threadSnapshot = [pscustomobject]@{
        RemoteManifestHashBefore = ('b' * 64)
        RemoteManifestHashAfter  = ('b' * 64)
    }
    $threadArtifact = New-RundotSyncPlanArtifact `
        -WorkspaceRoot $threadWorkspace `
        -ProjectId $threadProjectId `
        -Resolution $threadResolution `
        -Local @{ $threadPath = [pscustomobject]@{ Sha256 = $threadSha; Size = $threadBytes.Length; LocalDetectedKind = 'binary'; LineEnding = $null; HasBom = $null } } `
        -Remote @{} `
        -Snapshot $threadSnapshot

    # The run manifest is an ordinary object; reference identity is what the
    # chain must preserve, so a same-value re-hash cannot stand in for it.
    $threadManifest = Get-LocalManifest -WorkspaceRoot $threadWorkspace

    $threadAction = [pscustomobject]@{
        Path               = $threadPath
        Mode               = 'create'
        LocalSha256        = $threadSha
        ExpectedRemoteHash = $null
    }

    # PushBinaryAction must pass the manifest as its 13th positional argument.
    $script:ThreadBinaryArg = $null
    $threadCaptureBinary = {
        param($Ws, $Canonical, $Sha, $PlaceMode, $ExpectedRemote, $Art, $Res, $Origin, $Id, $Hdr, $GetFile, $GetList, $LiveLocal)
        $script:ThreadBinaryArg = $LiveLocal
        return [pscustomobject]@{ Path = $Canonical; Sha256 = $Sha }
    }

    $null = Invoke-RundotSyncPushBinaryAction `
        -WorkspaceRoot $threadWorkspace `
        -Action $threadAction `
        -Artifact $threadArtifact `
        -Resolution $threadResolution `
        -ProjectId $threadProjectId `
        -StudioOrigin $threadOrigin `
        -Headers @{} `
        -InvokeBinaryPlace $threadCaptureBinary `
        -LiveLocalManifest $threadManifest

    Assert-True `
        ([object]::ReferenceEquals($threadManifest, $script:ThreadBinaryArg)) `
        'Invoke-RundotSyncPushBinaryAction must pass -LiveLocalManifest to the place call (#75)'

    # PushApply must forward the manifest to the binary action.
    $script:ThreadApplyArg = $null
    $threadCaptureApply = {
        param($Ws, $Canonical, $Sha, $PlaceMode, $ExpectedRemote, $Art, $Res, $Origin, $Id, $Hdr, $GetFile, $GetList, $LiveLocal)
        $script:ThreadApplyArg = $LiveLocal
        return [pscustomobject]@{ Path = $Canonical; Sha256 = $Sha }
    }

    $null = Invoke-RundotSyncPushApply `
        -WorkspaceRoot $threadWorkspace `
        -Actions @() `
        -CreateActions @() `
        -BinaryActions @($threadAction) `
        -DeleteActions @() `
        -Artifact $threadArtifact `
        -Resolution $threadResolution `
        -StudioOrigin $threadOrigin `
        -ProjectId $threadProjectId `
        -Headers @{} `
        -BackupSetPath (Join-Path $threadRoot 'backup-set') `
        -InvokeBinaryPlace $threadCaptureApply `
        -LiveLocalManifest $threadManifest

    Assert-True `
        ([object]::ReferenceEquals($threadManifest, $script:ThreadApplyArg)) `
        'Invoke-RundotSyncPushApply must forward -LiveLocalManifest to the binary action (#75)'
}
finally {
    if (Test-Path -LiteralPath $threadRoot) {
        Remove-Item -LiteralPath $threadRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
