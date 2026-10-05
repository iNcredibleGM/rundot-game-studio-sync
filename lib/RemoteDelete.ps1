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

function Get-SyncRemoteAncestorDirectories {
    # Every ancestor directory the remote tree implies, as one set. A path that
    # appears here is directory-shaped: some listed file sits under it. Built
    # once per plan so the per-candidate check is a set lookup instead of a
    # scan of the whole remote list (#69).
    #
    # The comparison is ordinal, matching the StartsWith the per-row scan used:
    # 'src/dir' is an ancestor of 'src/dir/a.ts' but not of 'src/dir2/a.ts'.
    param(
        [AllowNull()]
        [string[]]$RemotePaths
    )

    $directories = New-Object 'System.Collections.Generic.HashSet[string]' (
        [System.StringComparer]::Ordinal
    )

    foreach ($remotePath in @($RemotePaths)) {
        $text = [string]$remotePath
        if ([string]::IsNullOrEmpty($text)) {
            continue
        }

        $segments = $text.Split(@('/'), [System.StringSplitOptions]::None)
        for ($i = 1; $i -lt $segments.Length; $i++) {
            [void]$directories.Add([string]::Join('/', $segments[0..($i - 1)]))
        }
    }

    # The leading comma stops PowerShell unrolling the HashSet into its
    # elements, so an empty remote list still returns an empty set rather than
    # $null and the caller can always call .Contains.
    return ,$directories
}

function Test-SyncDeletePathDirectoryShaped {
    # True when the path is an ancestor directory the remote tree implies, which
    # means it names a directory rather than a leaf. A delete of such a path
    # returns the same 404 as an absent path and removes nothing, so it is
    # refused rather than attempted.
    #
    # -AncestorDirectories is the precomputed set from
    # Get-SyncRemoteAncestorDirectories. When it is omitted the set is built
    # from -RemotePaths, so the check stays usable on its own.
    param(
        [Parameter(Mandatory)]
        [string]$CanonicalPath,

        [AllowNull()]
        [string[]]$RemotePaths,

        [AllowNull()]
        $AncestorDirectories
    )

    $canonical = ConvertTo-CanonicalSyncPath -Path $CanonicalPath

    if ($null -eq $AncestorDirectories) {
        $AncestorDirectories = Get-SyncRemoteAncestorDirectories -RemotePaths $RemotePaths
    }

    return $AncestorDirectories.Contains($canonical)
}

function Get-SyncDeletePathRefusalReason {
    # $null when the path may be deleted; otherwise the reason it may not.
    # Plan and Push both call this so the row's applicability and the engine's
    # refusal can never drift apart.
    param(
        [Parameter(Mandatory)]
        [string]$CanonicalPath,

        [AllowNull()]
        [string[]]$RemotePaths,

        [AllowNull()]
        $AncestorDirectories
    )

    $reservedRoot = Get-SyncDeletePathReservedRoot -CanonicalPath $CanonicalPath
    if (-not [string]::IsNullOrEmpty($reservedRoot)) {
        return (
            "Reserved path '$reservedRoot': a delete never touches sync state or repository metadata."
        )
    }

    if (
        Test-SyncDeletePathDirectoryShaped `
            -CanonicalPath $CanonicalPath `
            -RemotePaths $RemotePaths `
            -AncestorDirectories $AncestorDirectories
    ) {
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
        [string[]]$RemotePaths,

        [AllowNull()]
        $AncestorDirectories
    )

    $reason = Get-SyncDeletePathRefusalReason `
        -CanonicalPath $CanonicalPath `
        -RemotePaths $RemotePaths `
        -AncestorDirectories $AncestorDirectories

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

    Add-RemoteRequestHeaders -Request $request -Headers $Headers

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
