# Documented Studio delete: DELETE /api/projects/{id}/file
#
# Removes exactly the named file. The route is unversioned: it exposes no ETag
# or revision field, and If-Match / If-None-Match are ignored
# (docs/delete-rename-protocol.md). Nothing server-side can refuse a delete
# computed against content that has since changed, so every guard lives here:
# the caller re-reads the remote bytes immediately before the request, backs
# them up first, and verifies absence afterwards. A 200 status is not proof.
#
# The verb addresses one leaf path. A directory-shaped path returns the same
# 404 as an absent path and is never a recursive delete, so this library
# refuses a directory-shaped path rather than reading that 404 as permission.
# The server has no distinct reserved-path guard either, so the client-side
# reserved-root rule here is load-bearing rather than defense-in-depth.
#
# Rename is a separate route (a project-root POST) and is out of scope: do not
# add it here.
#
# Callers must load Paths.ps1, Hashing.ps1, RemoteApi.ps1, Snapshot.ps1, and
# RemoteWrite.ps1 (for ConvertTo-StudioAbsoluteApiPath) first.

$script:RundotSyncReservedRemoteRoots = @(
    '.git',
    '.gitignore',
    '.rundot-sync',
    '.rundot'
)

function Get-RundotSyncReservedRemoteRoots {
    # The roots a delete must never touch. The server accepted a move onto
    # /.rundot-sync/ and /.rundot/ (docs/delete-rename-protocol.md), so this
    # list is the only thing standing between a mistaken delete and sync
    # state or repository metadata.
    return $script:RundotSyncReservedRemoteRoots
}

function Get-SyncDeletePathReservedRoot {
    # The reserved root a canonical path sits under, or $null. Only the first
    # segment decides: a nested '.git' name is not repository metadata.
    param(
        [Parameter(Mandatory)]
        [string]$CanonicalPath
    )

    $canonical = ConvertTo-CanonicalSyncPath -Path $CanonicalPath
    $segments = $canonical.Split(@('/'), [System.StringSplitOptions]::None)

    if ($segments.Length -eq 0) {
        return $null
    }

    foreach ($root in $script:RundotSyncReservedRemoteRoots) {
        if ([string]::Equals($segments[0], $root, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $root
        }
    }

    return $null
}

function Test-SyncDeletePathDirectoryShaped {
    # True when the path is a prefix of a listed remote file, which means it
    # names a directory rather than a leaf. A delete of such a path returns the
    # same 404 as an absent path and removes nothing, so it is refused rather
    # than attempted.
    param(
        [Parameter(Mandatory)]
        [string]$CanonicalPath,

        [AllowNull()]
        [string[]]$RemotePaths
    )

    $canonical = ConvertTo-CanonicalSyncPath -Path $CanonicalPath
    $prefix = $canonical + '/'

    foreach ($remotePath in @($RemotePaths)) {
        if ([string]::IsNullOrEmpty([string]$remotePath)) {
            continue
        }

        if (
            ([string]$remotePath).StartsWith(
                $prefix,
                [System.StringComparison]::Ordinal
            )
        ) {
            return $true
        }
    }

    return $false
}

function Get-SyncDeletePathRefusalReason {
    # $null when the path may be deleted; otherwise the reason it may not.
    # Plan and Push both call this so the row's applicability and the engine's
    # refusal can never drift apart.
    param(
        [Parameter(Mandatory)]
        [string]$CanonicalPath,

        [AllowNull()]
        [string[]]$RemotePaths
    )

    $reservedRoot = Get-SyncDeletePathReservedRoot -CanonicalPath $CanonicalPath
    if (-not [string]::IsNullOrEmpty($reservedRoot)) {
        return (
            "Reserved path '$reservedRoot': a delete never touches sync state or repository metadata."
        )
    }

    if (Test-SyncDeletePathDirectoryShaped -CanonicalPath $CanonicalPath -RemotePaths $RemotePaths) {
        return (
            'Directory-shaped path: this route deletes exactly one file and a directory-shaped path is not a recursive delete.'
        )
    }

    return $null
}

function Assert-SyncDeletePathAllowed {
    param(
        [Parameter(Mandatory)]
        [string]$CanonicalPath,

        [AllowNull()]
        [string[]]$RemotePaths
    )

    $reason = Get-SyncDeletePathRefusalReason `
        -CanonicalPath $CanonicalPath `
        -RemotePaths $RemotePaths

    if (-not [string]::IsNullOrEmpty($reason)) {
        throw [System.InvalidOperationException]::new(
            ("Refusing to delete '{0}': {1}" -f $CanonicalPath, $reason)
        )
    }
}

function New-RemoteDeleteUri {
    param(
        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [string]$AbsolutePath
    )

    if (-not $AbsolutePath.StartsWith('/')) {
        throw [System.InvalidOperationException]::new(
            "Remote delete path must be absolute and start with '/'."
        )
    }

    $encodedPath = [System.Uri]::EscapeDataString($AbsolutePath)
    return "$StudioOrigin/api/projects/$ProjectId/file?path=$encodedPath"
}

function Invoke-RemoteDeleteFile {
    # Send DELETE for exactly one canonical path. A 404 is not swallowed here:
    # it surfaces as the typed 404 Test-RemoteNotFoundException recognizes, so
    # the caller can decide whether the postcondition already holds.
    param(
        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [string]$CanonicalPath,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    $absolutePath = ConvertTo-StudioAbsoluteApiPath -CanonicalPath $CanonicalPath
    $uri = New-RemoteDeleteUri `
        -StudioOrigin $StudioOrigin `
        -ProjectId $ProjectId `
        -AbsolutePath $absolutePath

    $request = [System.Net.HttpWebRequest]::Create($uri)
    $request.Method = 'DELETE'

    foreach ($key in $Headers.Keys) {
        switch -Regex ($key) {
            '^Accept$' {
                $request.Accept = [string]$Headers[$key]
                continue
            }
            default {
                $request.Headers[$key] = [string]$Headers[$key]
            }
        }
    }

    try {
        $httpResponse = $request.GetResponse()
    }
    catch [System.Net.WebException] {
        throw (Convert-WebExceptionToRemoteHttpException -Exception $_.Exception)
    }

    try {
        $bodyText = Read-Utf8HttpResponseBody -HttpResponse $httpResponse
        return ConvertFrom-RemoteJson -Text $bodyText -What $uri
    }
    finally {
        $httpResponse.Dispose()
    }
}

function Get-RemoteListedFilePaths {
    # The canonical paths the live project lists as files. The absence proof
    # is that the deleted path is not among them.
    param(
        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [scriptblock]$GetRemoteFileList = $null
    )

    if ($null -eq $GetRemoteFileList) {
        $GetRemoteFileList = {
            param($Origin, $Id, $Hdr)
            Get-RemoteProjectFileList `
                -StudioOrigin $Origin `
                -ProjectId $Id `
                -Headers $Hdr
        }
    }

    $manifest = & $GetRemoteFileList $StudioOrigin $ProjectId $Headers
    $rows = Get-RemoteManifestFileRows -Manifest $manifest

    $paths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($row in $rows) {
        [void]$paths.Add([string]$row.CanonicalPath)
    }

    return $paths.ToArray()
}

function Assert-RemotePathAbsent {
    # The postcondition. A 200 means the server accepted the request; the proof
    # that the file is gone is that GET /files no longer lists it.
    param(
        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [Parameter(Mandatory)]
        [string]$CanonicalPath,

        [scriptblock]$GetRemoteFileList = $null
    )

    $canonical = ConvertTo-CanonicalSyncPath -Path $CanonicalPath
    $listed = @(Get-RemoteListedFilePaths `
        -StudioOrigin $StudioOrigin `
        -ProjectId $ProjectId `
        -Headers $Headers `
        -GetRemoteFileList $GetRemoteFileList)

    if ($listed -contains $canonical) {
        throw [System.InvalidOperationException]::new(
            ("Refusing to treat the delete of '{0}' as complete: the remote project still lists it." -f $canonical)
        )
    }
}
