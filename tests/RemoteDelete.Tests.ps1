# Remote delete route contracts: URI shape, path refusal, and absence proof.
#
# Do not require Pester. No network.
#
# SCOPE NOTE: tests/Run-Tests.ps1 dot-sources every *.Tests.ps1 into one
# scope, in filename order. Helpers here are prefixed New-RemoteDeleteTest* /
# Get-RemoteDeleteTest* / Assert-RemoteDeleteTest* so they never shadow a
# library function another test file needs.

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "lib\Paths.ps1")
. (Join-Path $repoRoot "lib\Ignore.ps1")
. (Join-Path $repoRoot "lib\Hashing.ps1")
. (Join-Path $repoRoot "lib\Workspace.ps1")
. (Join-Path $repoRoot "lib\RemoteApi.ps1")
. (Join-Path $repoRoot "lib\Snapshot.ps1")
. (Join-Path $repoRoot "lib\RemoteWrite.ps1")
. (Join-Path $repoRoot "lib\RemoteDelete.ps1")

$remoteDeleteTestOrigin = 'https://example.test'
$remoteDeleteTestProjectId = 'proj-delete-test'


function Assert-RemoteDeleteTestThrowsLike {
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


# --------------------------------------------------------------------------
# URI shape: absolute path required, path percent-encoded
# --------------------------------------------------------------------------

$uriPlain = New-RemoteDeleteUri `
    -StudioOrigin $remoteDeleteTestOrigin `
    -ProjectId $remoteDeleteTestProjectId `
    -AbsolutePath '/uploads/a.txt'
Assert-Equal `
    "$remoteDeleteTestOrigin/api/projects/$remoteDeleteTestProjectId/file?path=%2Fuploads%2Fa.txt" `
    $uriPlain `
    "a delete URI must percent-encode the absolute path"

$uriSpace = New-RemoteDeleteUri `
    -StudioOrigin $remoteDeleteTestOrigin `
    -ProjectId $remoteDeleteTestProjectId `
    -AbsolutePath '/uploads/a b.txt'
Assert-True ($uriSpace -match '%20') "a space in the path must be percent-encoded, not sent raw"
Assert-True ($uriSpace -notmatch 'a b\.txt') "the raw space must not survive into the URI"

Assert-RemoteDeleteTestThrowsLike {
    New-RemoteDeleteUri `
        -StudioOrigin $remoteDeleteTestOrigin `
        -ProjectId $remoteDeleteTestProjectId `
        -AbsolutePath 'relative.txt'
} 'must be absolute' 'a relative path must refuse before any request'


# --------------------------------------------------------------------------
# Reserved roots
# --------------------------------------------------------------------------

Assert-True `
    ((Get-RundotSyncReservedRemoteRoots) -contains '.git') `
    "the reserved root set must include .git"
Assert-True `
    ((Get-RundotSyncReservedRemoteRoots) -contains '.rundot-sync') `
    "the reserved root set must include .rundot-sync"

Assert-Equal `
    '.rundot-sync' `
    (Get-SyncDeletePathReservedRoot -CanonicalPath '.rundot-sync/base-manifest.json') `
    "a path under a reserved root must report that root"
Assert-Equal `
    '.git' `
    (Get-SyncDeletePathReservedRoot -CanonicalPath '.git/config') `
    "a dotfile under .git must report .git"
Assert-Null `
    (Get-SyncDeletePathReservedRoot -CanonicalPath 'src/.gitignore') `
    "a nested name that is not the first segment must not be reserved"
Assert-Null `
    (Get-SyncDeletePathReservedRoot -CanonicalPath 'src/a.ts') `
    "an ordinary path must not be reserved"

Assert-RemoteDeleteTestThrowsLike {
    Assert-SyncDeletePathAllowed `
        -CanonicalPath '.rundot-sync/base-manifest.json' `
        -RemotePaths @()
} 'Reserved path' 'a reserved path must refuse the delete'

# The reserved check is case-insensitive: a Windows filesystem cannot tell
# '.RUNDOT-SYNC' from '.rundot-sync'.
Assert-RemoteDeleteTestThrowsLike {
    Assert-SyncDeletePathAllowed `
        -CanonicalPath '.RUNDOT-SYNC/x.json' `
        -RemotePaths @()
} 'Reserved path' 'a reserved root must match case-insensitively'


# --------------------------------------------------------------------------
# Directory-shaped paths
# --------------------------------------------------------------------------

Assert-True `
    (Test-SyncDeletePathDirectoryShaped `
        -CanonicalPath 'src/dir' `
        -RemotePaths @('src/dir/a.ts')) `
    "a path that prefixes a listed file is directory-shaped"
Assert-True `
    (-not (Test-SyncDeletePathDirectoryShaped `
        -CanonicalPath 'src/dir/a.ts' `
        -RemotePaths @('src/dir/a.ts'))) `
    "an exact leaf match is not directory-shaped"
Assert-True `
    (-not (Test-SyncDeletePathDirectoryShaped `
        -CanonicalPath 'src/dir2' `
        -RemotePaths @('src/dir/a.ts'))) `
    "a sibling prefix must not be mistaken for a directory"

Assert-RemoteDeleteTestThrowsLike {
    Assert-SyncDeletePathAllowed `
        -CanonicalPath 'src/dir' `
        -RemotePaths @('src/dir/a.ts') `
} 'Directory-shaped' 'a directory-shaped path must refuse the delete'

Assert-True `
    ($null -eq (Get-SyncDeletePathRefusalReason -CanonicalPath 'src/a.ts' -RemotePaths @('src/a.ts'))) `
    "an ordinary leaf path must have no refusal reason"


# --------------------------------------------------------------------------
# Absence proof
# --------------------------------------------------------------------------

$headers = @{
    Authorization = 'Bearer test-token-not-for-output'
    Accept        = '*/*'
}

$presentList = {
    param($Origin, $Id, $Hdr)
    return [pscustomobject]@{
        files = @(
            [pscustomobject]@{ path = '/uploads/a.txt'; type = 'file'; size = 3 },
            [pscustomobject]@{ path = '/uploads/b.txt'; type = 'file'; size = 4 }
        )
    }
}

$absentList = {
    param($Origin, $Id, $Hdr)
    return [pscustomobject]@{
        files = @(
            [pscustomobject]@{ path = '/uploads/b.txt'; type = 'file'; size = 4 }
        )
    }
}

$listedPaths = @(Get-RemoteListedFilePaths `
    -StudioOrigin $remoteDeleteTestOrigin `
    -ProjectId $remoteDeleteTestProjectId `
    -Headers $headers `
    -GetRemoteFileList $presentList)
Assert-True ($listedPaths -contains 'uploads/a.txt') "a listed path must canonicalize without its leading slash"

Assert-RemoteDeleteTestThrowsLike {
    Assert-RemotePathAbsent `
        -StudioOrigin $remoteDeleteTestOrigin `
        -ProjectId $remoteDeleteTestProjectId `
        -Headers $headers `
        -CanonicalPath 'uploads/a.txt' `
        -GetRemoteFileList $presentList
} 'still lists it' 'a path that is still listed must not be treated as deleted'

# The postcondition holds once the path is gone from the list.
Assert-RemotePathAbsent `
    -StudioOrigin $remoteDeleteTestOrigin `
    -ProjectId $remoteDeleteTestProjectId `
    -Headers $headers `
    -CanonicalPath 'uploads/a.txt' `
    -GetRemoteFileList $absentList

# An absent path that was never listed is also absent: the same 404 as a
# path that does not exist, which is why absence is proven from the list.
Assert-RemotePathAbsent `
    -StudioOrigin $remoteDeleteTestOrigin `
    -ProjectId $remoteDeleteTestProjectId `
    -Headers $headers `
    -CanonicalPath 'uploads/never-existed.txt' `
    -GetRemoteFileList $absentList


# --------------------------------------------------------------------------
# A 404 maps to the typed not-found the caller branches on
# --------------------------------------------------------------------------

$notFoundException = New-RemoteHttpException -StatusCode 404 -Message 'not found'
Assert-True `
    (Test-RemoteNotFoundException -Exception $notFoundException) `
    "a 404 must be recognized as not-found so an already-deleted path is not a new failure"

$unauthorizedException = New-RemoteHttpException -StatusCode 401 -Message 'unauthorized'
Assert-True `
    (-not (Test-RemoteNotFoundException -Exception $unauthorizedException)) `
    "a 401 must not be mistaken for an already-deleted path"
