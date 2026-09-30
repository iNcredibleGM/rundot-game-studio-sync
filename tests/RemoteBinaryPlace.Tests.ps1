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
