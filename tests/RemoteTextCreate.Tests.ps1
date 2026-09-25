# Text create staging path predicate and absence guard contracts.
#
# Do not require Pester. No network.

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "lib\Paths.ps1")
. (Join-Path $repoRoot "lib\Ignore.ps1")
. (Join-Path $repoRoot "lib\Hashing.ps1")
. (Join-Path $repoRoot "lib\Workspace.ps1")
. (Join-Path $repoRoot "lib\Manifest.ps1")
. (Join-Path $repoRoot "lib\RemoteApi.ps1")
. (Join-Path $repoRoot "lib\Snapshot.ps1")
. (Join-Path $repoRoot "lib\RemoteWrite.ps1")
. (Join-Path $repoRoot "lib\RemoteUpload.ps1")
. (Join-Path $repoRoot "lib\RemoteMove.ps1")
. (Join-Path $repoRoot "lib\RemoteDelete.ps1")
. (Join-Path $repoRoot "lib\Push.ps1")
. (Join-Path $repoRoot "lib\RemoteTextCreate.ps1")

Assert-True `
    (Test-RemoteTextCreateStagingAbsolutePath -AbsolutePath '/uploads/rundot-sync-0123456789abcdef0123456789abcdef.txt') `
    "the primary staging path shape must be accepted"

Assert-True `
    (Test-RemoteTextCreateStagingAbsolutePath -AbsolutePath '/uploads/rundot-sync-0123456789abcdef0123456789abcdef-1.txt') `
    "a collision sibling staging path must be accepted"

Assert-True `
    (-not (Test-RemoteTextCreateStagingAbsolutePath -AbsolutePath '/src/new.ts')) `
    "a project path must not count as staging"

Assert-True `
    (-not (Test-RemoteTextCreateStagingAbsolutePath -AbsolutePath '/.rundot-sync/seed.txt')) `
    "a reserved-shaped path must not count as staging"

Assert-True `
    (-not (Test-RemoteTextCreateStagingAbsolutePath -AbsolutePath '/uploads/other.txt')) `
    "a foreign uploads name must not count as staging"

$remoteTextCreateTestOrigin = 'https://example.test'
$remoteTextCreateTestProjectId = 'proj-create-test'

function Assert-RemoteTextCreateTestThrowsLike {
    param(
        [scriptblock]$Script,
        [string]$Pattern,
        [string]$Message
    )

    $threw = $false
    $text = $null

    try {
        & $Script | Out-Null
    }
    catch {
        $threw = $true
        $text = $_.Exception.Message
    }

    Assert-True $threw $Message
    if ($threw) {
        Assert-True ($text -match $Pattern) ("$Message (pattern '$Pattern', got '$text')")
    }
}

Assert-RemoteTextCreateTestThrowsLike {
    Assert-RemoteTextCreateDestinationAbsent `
        -CanonicalPath 'src/new.ts' `
        -StudioOrigin $remoteTextCreateTestOrigin `
        -ProjectId $remoteTextCreateTestProjectId `
        -Headers @{ Authorization = 'Bearer test' } `
        -GetRemoteFile {
            param($Origin, $Id, $ApiPath, $Hdr)
            return [pscustomobject]@{ encoding = 'utf8'; content = 'x' }
        }
} 'remote path appeared' 'an occupied destination must refuse before upload'
