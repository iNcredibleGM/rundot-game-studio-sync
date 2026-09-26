# Binary place staging path predicate and adopt-path contracts.
#
# Do not require Pester. No network.

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "lib\Paths.ps1")
. (Join-Path $repoRoot "lib\Ignore.ps1")
. (Join-Path $repoRoot "lib\Hashing.ps1")
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
