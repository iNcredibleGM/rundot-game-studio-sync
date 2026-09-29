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
