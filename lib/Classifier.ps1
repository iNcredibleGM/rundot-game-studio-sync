# Pure three-way sync classifier over BASE / LOCAL / REMOTE.
#
# Identity is exact SHA-256 of file bytes. There is no timestamp input, no
# network access, and no filesystem access: callers hand this library the
# already-canonical identity maps produced by Get-LocalManifest, the stable
# remote snapshot, and the BASE manifest. Classification never mutates BASE
# or any input map.
#
# Neither LOCAL nor REMOTE is authoritative. BASE is the last verified shared
# state. Any ambiguity is a conflict, not a guess.
#
# Callers must load Paths.ps1, Ignore.ps1, and Hashing.ps1 first.

$script:SyncStatusUnchanged             = 'unchanged'
$script:SyncStatusSynchronizedChange    = 'synchronized-change'
$script:SyncStatusSynchronizedAddition  = 'synchronized-addition'
$script:SyncStatusSettledAbsent         = 'settledAbsent'
$script:SyncStatusUpload                = 'upload'
$script:SyncStatusDownload              = 'download'
$script:SyncStatusConflict              = 'conflict'
$script:SyncStatusIgnored               = 'ignored'
$script:SyncStatusDeleteRemoteCandidate = 'deleteRemoteCandidate'
$script:SyncStatusDeleteLocalCandidate  = 'deleteLocalCandidate'

# Binary uploads are displayed as UPLOAD but never marked applicable. #15
# verified that the upload flow cannot choose a project path and cannot replace
# a file — the requested path is ignored (the file always lands at
# /uploads/{basename}) and a repeated name creates a numeric-suffixed sibling
# rather than replacing the existing file. #38 then proved the capability
# exists, but only through a composed sequence: upload-then-move lands one
# binary at a chosen path, and a replacement is delete-then-place rather than
# an in-place overwrite (docs/binary-place-protocol.md). The product still
# emits none of those routes, so the row stays inapplicable and the reason now
# states the real shape instead of claiming replacement is impossible.
$script:SyncBinaryUploadReason = 'Binary placement needs upload-then-move: the upload flow ignores the requested path and a repeated name creates a sibling instead of replacing, and a replacement is delete-then-place rather than an in-place overwrite.'

# The delete verb is characterized in docs/delete-rename-protocol.md: it
# removes exactly the named path, a repeated delete returns 404 rather than an
# error, and a stale write against a deleted path is refused rather than
# resurrecting it. What it cannot do is refuse a stale delete: there is no
# ETag, no version field, and If-Match is ignored, so nothing server-side can
# reject a delete computed against content that has since changed. The guard
# therefore lives in the client, immediately before the request: a confirmed
# Push re-reads the remote bytes, backs them up, and proves the path is absent
# afterwards (docs/delete.md). Pull never deletes anything.
$script:SyncDeletionCandidateReason = @(
    'Pull never deletes anything, locally or remotely.',
    'A deletion candidate is reported here and applied only by a confirmed Push.',
    'Studio cannot make a delete conditional: there is no ETag or version field and If-Match is ignored, so a stale delete cannot be refused server-side.'
) -join "`n"

$script:SyncIgnoredReason = 'Matches the default ignore set, so it is out of sync scope.'

$script:SyncConflictReason = 'BASE, LOCAL, and REMOTE do not agree, so there is no safe sync direction.'

$script:SyncKindChangeReason = 'The path changed between text and binary, which is an unsupported kind change.'

$script:SyncMetadataDisagreementFields = @('size', 'kind', 'lineEnding', 'hasBom')


function Get-SyncEntryProperty {
    # Read one of several accepted spellings without normalizing callers.
    # BASE stores lowercase sha256/size/kind; LOCAL and REMOTE are PascalCase.
    param(
        $Entry,
        [string[]]$Names
    )

    if ($null -eq $Entry) {
        return $null
    }

    foreach ($name in $Names) {
        $property = $Entry.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) {
            return $property.Value
        }
    }

    return $null
}

function Get-SyncEntrySha256 {
    param($Entry)

    $value = Get-SyncEntryProperty -Entry $Entry -Names @('Sha256', 'sha256')
    if ($null -eq $value) {
        return $null
    }

    return [string]$value
}

function Get-SyncEntryKind {
    # LOCAL exposes LocalDetectedKind, REMOTE exposes RemoteKind, BASE exposes
    # kind. They are the same identity vocabulary: utf8 or binary.
    param($Entry)

    $value = Get-SyncEntryProperty -Entry $Entry -Names @('LocalDetectedKind', 'RemoteKind', 'Kind', 'kind')
    if ($null -eq $value) {
        return $null
    }

    return [string]$value
}

function Test-SyncHashEqual {
    param($LeftSha256, $RightSha256)

    if ([string]::IsNullOrEmpty($LeftSha256) -or [string]::IsNullOrEmpty($RightSha256)) {
        return $false
    }

    return [string]::Equals($LeftSha256, $RightSha256, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-SyncMetadataFieldValue {
    param(
        $Entry,
        [string]$Field
    )

    switch ($Field) {
        'size' {
            return (Get-SyncEntryProperty -Entry $Entry -Names @('Size', 'size'))
        }
        'kind' {
            return (Get-SyncEntryKind -Entry $Entry)
        }
        'lineEnding' {
            return (Get-SyncEntryProperty -Entry $Entry -Names @('LineEnding', 'lineEnding'))
        }
        'hasBom' {
            return (Get-SyncEntryProperty -Entry $Entry -Names @('HasBom', 'hasBom'))
        }
    }

    return $null
}

function Test-SyncMetadataAgreement {
    # Report the declared metadata fields on which two sides disagree.
    #
    # A field counts only when BOTH sides declare it. BASE omits lineEnding
    # and hasBom for binary entries, and a remote snapshot entry carries no
    # line-ending diagnostics at all, so those absences are not disagreements.
    #
    # Returned names feed a Warning; the content hash is the only decision
    # input, so this never changes a status by itself.
    param($Left, $Right)

    $disagreements = New-Object 'System.Collections.Generic.List[string]'

    if ($null -eq $Left -or $null -eq $Right) {
        return $disagreements.ToArray()
    }

    foreach ($field in $script:SyncMetadataDisagreementFields) {
        $leftValue = Get-SyncMetadataFieldValue -Entry $Left -Field $field
        if ($null -eq $leftValue) {
            continue
        }

        $rightValue = Get-SyncMetadataFieldValue -Entry $Right -Field $field
        if ($null -eq $rightValue) {
            continue
        }

        $agrees = $true
        switch ($field) {
            'size' {
                $agrees = ([int64]$leftValue) -eq ([int64]$rightValue)
            }
            'hasBom' {
                $agrees = ([bool]$leftValue) -eq ([bool]$rightValue)
            }
            default {
                $agrees = [string]::Equals(
                    [string]$leftValue,
                    [string]$rightValue,
                    [System.StringComparison]::Ordinal
                )
            }
        }

        if (-not $agrees) {
            $disagreements.Add($field)
        }
    }

    return $disagreements.ToArray()
}

function Get-SyncPlanMetadataDisagreements {
    param($Base, $Local, $Remote)

    $names = New-Object 'System.Collections.Generic.List[string]'

    foreach ($name in @(Test-SyncMetadataAgreement -Left $Base -Right $Local)) {
        if (-not $names.Contains([string]$name)) {
            $names.Add([string]$name)
        }
    }

    foreach ($name in @(Test-SyncMetadataAgreement -Left $Base -Right $Remote)) {
        if (-not $names.Contains([string]$name)) {
            $names.Add([string]$name)
        }
    }

    foreach ($name in @(Test-SyncMetadataAgreement -Left $Local -Right $Remote)) {
        if (-not $names.Contains([string]$name)) {
            $names.Add([string]$name)
        }
    }

    return $names.ToArray()
}

function Test-SyncKindChangePair {
    # A text <-> binary change is unsupported only when the two sides also have
    # genuinely different content. Equal bytes win: the same bytes described as
    # different kinds is a metadata artifact, not a kind change.
    param($Left, $Right)

    if ($null -eq $Left -or $null -eq $Right) {
        return $false
    }

    $leftKind = Get-SyncEntryKind -Entry $Left
    $rightKind = Get-SyncEntryKind -Entry $Right

    if (-not (Test-UnsupportedKindChange -LocalKind $leftKind -RemoteKind $rightKind)) {
        return $false
    }

    $leftSha = Get-SyncEntrySha256 -Entry $Left
    $rightSha = Get-SyncEntrySha256 -Entry $Right

    return (-not (Test-SyncHashEqual -LeftSha256 $leftSha -RightSha256 $rightSha))
}

function Test-UnsupportedSyncKindChange {
    param($Base, $Local, $Remote)

    if (Test-SyncKindChangePair -Left $Base -Right $Local) {
        return $true
    }

    if (Test-SyncKindChangePair -Left $Base -Right $Remote) {
        return $true
    }

    if (Test-SyncKindChangePair -Left $Local -Right $Remote) {
        return $true
    }

    return $false
}

function Test-SyncNoOpStatus {
    param([string]$Status)

    return @(
        $script:SyncStatusUnchanged,
        $script:SyncStatusSynchronizedChange,
        $script:SyncStatusSynchronizedAddition,
        $script:SyncStatusSettledAbsent
    ) -contains $Status
}

function Get-SyncPathChangeStatus {
    # The decision table. $null means the path is missing on that side.
    #
    # Ignore precedence is checked first so an ignored path is settled rather
    # than an action, a conflict, or a deletion candidate.
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        $Base,
        $Local,
        $Remote
    )

    if (Test-IgnoredSyncPath -CanonicalPath $Path) {
        return $script:SyncStatusIgnored
    }

    $baseSha = Get-SyncEntrySha256 -Entry $Base
    $localSha = Get-SyncEntrySha256 -Entry $Local
    $remoteSha = Get-SyncEntrySha256 -Entry $Remote

    $hasBase = ($null -ne $Base)
    $hasLocal = ($null -ne $Local)
    $hasRemote = ($null -ne $Remote)

    # BASE / LOCAL / REMOTE all present.
    if ($hasBase -and $hasLocal -and $hasRemote) {
        if (Test-SyncHashEqual -LeftSha256 $baseSha -RightSha256 $localSha) {
            if (Test-SyncHashEqual -LeftSha256 $baseSha -RightSha256 $remoteSha) {
                return $script:SyncStatusUnchanged
            }

            return $script:SyncStatusDownload
        }

        if (Test-SyncHashEqual -LeftSha256 $baseSha -RightSha256 $remoteSha) {
            return $script:SyncStatusUpload
        }

        if (Test-SyncHashEqual -LeftSha256 $localSha -RightSha256 $remoteSha) {
            return $script:SyncStatusSynchronizedChange
        }

        return $script:SyncStatusConflict
    }

    # BASE present, no LOCAL and no REMOTE: the deletion has already settled on
    # both sides. This is not a standing DELETE.
    if ($hasBase -and -not $hasLocal -and -not $hasRemote) {
        return $script:SyncStatusSettledAbsent
    }

    # BASE and REMOTE present, LOCAL missing.
    if ($hasBase -and -not $hasLocal) {
        if (Test-SyncHashEqual -LeftSha256 $baseSha -RightSha256 $remoteSha) {
            return $script:SyncStatusDeleteRemoteCandidate
        }

        return $script:SyncStatusConflict
    }

    # BASE and LOCAL present, REMOTE missing.
    if ($hasBase -and -not $hasRemote) {
        if (Test-SyncHashEqual -LeftSha256 $baseSha -RightSha256 $localSha) {
            return $script:SyncStatusDeleteLocalCandidate
        }

        return $script:SyncStatusConflict
    }

    # No BASE: additions.
    if ($hasLocal -and $hasRemote) {
        if (Test-SyncHashEqual -LeftSha256 $localSha -RightSha256 $remoteSha) {
            return $script:SyncStatusSynchronizedAddition
        }

        return $script:SyncStatusConflict
    }

    if ($hasLocal) {
        return $script:SyncStatusUpload
    }

    if ($hasRemote) {
        return $script:SyncStatusDownload
    }

    # Not reachable through Get-SyncPlanChanges, which walks the union.
    return $script:SyncStatusSettledAbsent
}

function Get-SyncPlanChange {
    # Full, display-ready row: status plus whether this milestone may act on it,
    # and why not when it may not.
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        $Base,
        $Local,
        $Remote
    )

    $status = Get-SyncPathChangeStatus -Path $Path -Base $Base -Local $Local -Remote $Remote
    $ignored = ($status -eq $script:SyncStatusIgnored)
    $kindChange = $false
    $reason = $null
    $warning = $null
    $applicable = $false

    if (-not $ignored) {
        $kindChange = Test-UnsupportedSyncKindChange -Base $Base -Local $Local -Remote $Remote
        if ($kindChange) {
            $status = $script:SyncStatusConflict
        }
    }

    if (Test-SyncNoOpStatus -Status $status) {
        $disagreements = @(Get-SyncPlanMetadataDisagreements -Base $Base -Local $Local -Remote $Remote)
        if ($disagreements.Count -gt 0) {
            $warning = (
                'Content hashes agree, but recorded metadata disagrees for: ' +
                ($disagreements -join ', ') + '.'
            )
        }
    }

    switch ($status) {
        $script:SyncStatusUpload {
            if ((Get-SyncEntryKind -Entry $Local) -eq 'binary') {
                $applicable = $false
                $reason = $script:SyncBinaryUploadReason
            }
            else {
                $applicable = $true
            }
        }
        $script:SyncStatusDownload {
            $applicable = $true
        }
        $script:SyncStatusConflict {
            if ($kindChange) {
                $reason = $script:SyncKindChangeReason
            }
            else {
                $reason = $script:SyncConflictReason
            }
        }
        $script:SyncStatusIgnored {
            $reason = $script:SyncIgnoredReason
        }
        $script:SyncStatusDeleteRemoteCandidate {
            $reason = $script:SyncDeletionCandidateReason
        }
        $script:SyncStatusDeleteLocalCandidate {
            $reason = $script:SyncDeletionCandidateReason
        }
    }

    return [pscustomobject]@{
        Path         = [string]$Path
        Status       = [string]$status
        Applicable   = [bool]$applicable
        Reason       = $reason
        Warning      = $warning
        Ignored      = [bool]$ignored
        KindChange   = [bool]$kindChange
        BaseSha256   = Get-SyncEntrySha256 -Entry $Base
        LocalSha256  = Get-SyncEntrySha256 -Entry $Local
        RemoteSha256 = Get-SyncEntrySha256 -Entry $Remote
    }
}

function Get-SyncMapKeys {
    # The keys of a file map, whichever shape it arrived in: a Hashtable from
    # BASE or a PSCustomObject from a parsed manifest. Emitted as one array so
    # an empty map still returns an empty array rather than $null.
    param($Map)

    if ($null -eq $Map) {
        return ,([string[]]@())
    }

    $keys = New-Object 'System.Collections.Generic.List[string]'

    if ($Map -is [System.Collections.IDictionary]) {
        foreach ($key in $Map.Keys) {
            [void]$keys.Add([string]$key)
        }

        return ,$keys.ToArray()
    }

    foreach ($property in $Map.PSObject.Properties) {
        [void]$keys.Add([string]$property.Name)
    }

    return ,$keys.ToArray()
}

function Copy-SyncMapToHashtable {
    # A fresh ordinal Hashtable copy of a file map, whichever shape it arrived
    # in. Values are copied by reference; a caller that needs to replace an
    # entry does so on the returned map. A missing map copies to an empty map.
    param($Map)

    $copy = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)

    if ($null -eq $Map) {
        return $copy
    }

    if ($Map -is [System.Collections.IDictionary]) {
        foreach ($key in $Map.Keys) {
            $copy[[string]$key] = $Map[$key]
        }

        return $copy
    }

    foreach ($property in $Map.PSObject.Properties) {
        $copy[[string]$property.Name] = $property.Value
    }

    return $copy
}

function Get-SyncMapEntry {
    param(
        $Map,
        [string]$Path
    )

    if ($null -eq $Map) {
        return $null
    }

    if ($Map.Contains($Path)) {
        return $Map[$Path]
    }

    return $null
}

function Assert-SyncPlanChangeInputs {
    # A missing REMOTE map means the snapshot never completed. Reading it as an
    # empty project would classify every path as locally deleted, so refuse
    # instead. LOCAL is required for the same reason. BASE may be $null: the
    # -AllowNoBase case is a legitimate untrusted first run.
    param($Base, $Local, $Remote)

    if ($null -ne $Base -and $Base -isnot [System.Collections.IDictionary]) {
        throw [System.InvalidOperationException]::new(
            "BASE must be a file map or missing; a malformed BASE cannot be classified."
        )
    }

    if ($Local -isnot [System.Collections.IDictionary]) {
        throw [System.InvalidOperationException]::new(
            "LOCAL must be a file map. A missing LOCAL tree cannot be classified."
        )
    }

    if ($Remote -isnot [System.Collections.IDictionary]) {
        throw [System.InvalidOperationException]::new(
            "REMOTE must be a file map. A failed or torn snapshot cannot be classified."
        )
    }
}

function Get-SyncSortablePaths {
    param($Base, $Local, $Remote)

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)

    foreach ($map in @($Base, $Local, $Remote)) {
        if ($null -eq $map) {
            continue
        }

        foreach ($key in @($map.Keys)) {
            [void]$seen.Add([string]$key)
        }
    }

    $sorted = New-Object string[] $seen.Count
    $seen.CopyTo($sorted)
    [Array]::Sort($sorted, [System.StringComparer]::Ordinal)

    # Emit the paths one by one rather than as a single wrapped array: callers
    # use `@(...)` and `foreach` on the result, and a wrapping comma would make
    # both see one nested element instead of the paths.
    return $sorted
}

function Get-SyncPlanChanges {
    # One row per path in BASE union LOCAL union REMOTE, ordinal-sorted by
    # canonical path. Never mutates an input map and never writes BASE.
    param($Base, $Local, $Remote)

    Assert-SyncPlanChangeInputs -Base $Base -Local $Local -Remote $Remote

    $paths = Get-SyncSortablePaths -Base $Base -Local $Local -Remote $Remote
    $rows = New-Object 'System.Collections.Generic.List[object]'

    foreach ($path in $paths) {
        $rows.Add((Get-SyncPlanChange `
            -Path $path `
            -Base (Get-SyncMapEntry -Map $Base -Path $path) `
            -Local (Get-SyncMapEntry -Map $Local -Path $path) `
            -Remote (Get-SyncMapEntry -Map $Remote -Path $path)))
    }

    if ($rows.Count -eq 0) {
        # A bare `return $rows.ToArray()` on an empty list would be $null, and
        # callers use @(...) to count rows.
        return @()
    }

    # Emit rows one by one: `@(Get-SyncPlanChanges ...)` must count rows, not
    # wrap the returned array as a single element.
    return $rows.ToArray()
}
