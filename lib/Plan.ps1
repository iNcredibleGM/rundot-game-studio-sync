# Plan / Status dry-run engine: the last-plan.json artifact, display-ready
# operation rows, the human report, and BOM/newline text diagnostics.
#
# Read-oriented only. This library never mutates Studio, never writes BASE,
# and never implies that a plan is permission to write. Future Apply work
# consumes the artifact fingerprints recorded here.
#
# Callers must load Paths.ps1, Ignore.ps1, Hashing.ps1, Workspace.ps1,
# Manifest.ps1, Snapshot.ps1, and Classifier.ps1 first.

$script:SyncPlanArtifactSchemaVersion = 1
$script:SyncPlanDefaultTtlMinutes = 20

# Push consumes plan fingerprints but a plan is never permission to write.
# Only a clean text overwrite may be marked applicable; creates, binaries, and
# deletes stay blocked with explicit reasons.
$script:SyncPlanTextCreateReason = 'PUT /file cannot create a new path; a missing remote file returns 404.'
$script:SyncPlanDeleteRemoteBlockedReason = 'Push does not delete remote files.'

$script:SyncPlanDryRunClosingLines = @(
    'Dry run only. No remote files were modified.'
    'This plan is a point-in-time observation, not permission to write.'
    'WARNING: This tool uses unofficial remote API routes that may change.'
)


function Get-PlanArtifactPath {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot
    )

    return Join-Path (Get-RundotSyncRoot -WorkspaceRoot $WorkspaceRoot) 'last-plan.json'
}

function Test-SyncRemoteMutatingStatus {
    # Which statuses would mutate REMOTE if this milestone could apply a plan.
    # 'DELETE' is included so a future status rename cannot silently slip past
    # the block.
    param([string]$Status)

    return @(
        'upload'
        $script:SyncStatusDeleteRemoteCandidate
        'DELETE'
    ) -contains [string]$Status
}

function Format-SyncPlanShortHash {
    param($Value)

    $text = [string]$Value
    if ([string]::IsNullOrEmpty($text)) {
        return '<none>'
    }

    if ($text.Length -le 16) {
        return $text
    }

    return ($text.Substring(0, 8) + '...' + $text.Substring($text.Length - 4))
}

function Get-SyncPlanBaseMapFromResolution {
    # BASE identity comes from the resolver's manifest, not from a second
    # read. A missing or BASE-less resolution is the -AllowNoBase case.
    #
    # The map values must stay in the manifest's own spelling: BASE stores
    # lowercase sha256/size/kind, and the classifier reads those native entry
    # objects. Rebuilding them into hashtables would hide the fields from
    # PSObject.Properties.
    param($Resolution)

    if ($null -eq $Resolution -or $null -eq $Resolution.Base) {
        return $null
    }

    $filesProperty = $Resolution.Base.PSObject.Properties['files']
    if ($null -eq $filesProperty -or $null -eq $filesProperty.Value) {
        return $null
    }

    $files = $filesProperty.Value
    $map = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)

    if ($files -is [System.Collections.IDictionary]) {
        foreach ($key in @($files.Keys)) {
            $map[[string]$key] = $files[$key]
        }

        return $map
    }

    foreach ($property in $files.PSObject.Properties) {
        $map[[string]$property.Name] = $property.Value
    }

    return $map
}

function Get-SyncLocalManifestFingerprint {
    # SHA-256 of a canonical path/hash/size/kind document. This is future-Apply
    # evidence: it proves which LOCAL tree the plan was computed against,
    # without storing any file contents.
    param($Local)

    $paths = @()
    if ($null -ne $Local) {
        if ($Local -is [System.Collections.IDictionary]) {
            $paths = @($Local.Keys | ForEach-Object { [string]$_ })
        }
        else {
            $paths = @($Local.PSObject.Properties | ForEach-Object { [string]$_.Name })
        }
    }

    if ($paths.Count -gt 0) {
        $sorted = New-Object string[] $paths.Count
        $paths.CopyTo($sorted, 0)
        [Array]::Sort($sorted, [System.StringComparer]::Ordinal)
        $paths = $sorted
    }

    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($path in @($paths)) {
        $entry = Get-SyncMapEntry -Map $Local -Path $path
        $sha = [string](Get-SyncEntrySha256 -Entry $entry)
        $size = Get-SyncEntryProperty -Entry $entry -Names @('Size', 'size')
        $sizeText = '<none>'
        if ($null -ne $size) {
            $sizeText = [string][int64]$size
        }

        $kind = [string](Get-SyncEntryKind -Entry $entry)
        $lines.Add("$path`t$sha`t$sizeText`t$kind")
    }

    return Convert-Utf8Sha256Hex -Text ([string]::Join("`n", $lines.ToArray()))
}

function Get-SyncPlanOperationRows {
    # Display-ready operation rows. The classifier decides status; Plan adds
    # the publish policy on top: only a utf8 text overwrite may be applicable,
    # and every blocked remote-mutating row carries a reason.
    param(
        [object[]]$Changes,
        $Base,
        $Local,
        $Remote
    )

    $rows = New-Object 'System.Collections.Generic.List[object]'

    foreach ($change in @($Changes)) {
        $path = [string]$change.Path
        $baseEntry = Get-SyncMapEntry -Map $Base -Path $path
        $localEntry = Get-SyncMapEntry -Map $Local -Path $path
        $remoteEntry = Get-SyncMapEntry -Map $Remote -Path $path

        $status = [string]$change.Status
        $localKind = [string](Get-SyncEntryKind -Entry $localEntry)
        $remoteMutating = Test-SyncRemoteMutatingStatus -Status $status

        $applicable = [bool]$change.Applicable
        $reason = $change.Reason
        $remoteSha = [string]$change.RemoteSha256

        if ($remoteMutating) {
            if ($status -eq $script:SyncStatusUpload) {
                if ($localKind -eq 'binary') {
                    $applicable = $false
                }
                elseif ($localKind -eq 'utf8') {
                    if ([string]::IsNullOrEmpty($remoteSha)) {
                        $applicable = $false
                        $reason = $script:SyncPlanTextCreateReason
                    }
                }
                else {
                    $applicable = $false
                }
            }
            elseif ($status -eq $script:SyncStatusDeleteRemoteCandidate) {
                $applicable = $false
                $reason = $script:SyncPlanDeleteRemoteBlockedReason
            }
            else {
                $applicable = $false
            }
        }

        $rows.Add([pscustomobject]@{
            path               = $path
            status             = $status
            kind               = $localKind
            kinds              = [pscustomobject]@{
                base   = Get-SyncEntryKind -Entry $baseEntry
                local  = Get-SyncEntryKind -Entry $localEntry
                remote = Get-SyncEntryKind -Entry $remoteEntry
            }
            applicable         = [bool]$applicable
            remoteMutating     = [bool]$remoteMutating
            reason             = $reason
            warning            = $change.Warning
            ignored            = [bool]$change.Ignored
            kindChange         = [bool]$change.KindChange
            baseSha256         = $change.BaseSha256
            localSha256        = $change.LocalSha256
            remoteSha256       = $change.RemoteSha256
            expectedRemoteHash = $change.RemoteSha256
        })
    }

    return $rows.ToArray()
}

function New-RundotSyncPlanArtifact {
    # The persisted dry-run plan. Hashes and metadata only: no file contents,
    # no tokens, no staging paths, no absolute local paths.
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        $Resolution,

        [Parameter(Mandatory)]
        $Local,

        [Parameter(Mandatory)]
        $Remote,

        [Parameter(Mandatory)]
        $Snapshot,

        [double]$TtlMinutes = 20
    )

    $baseMap = Get-SyncPlanBaseMapFromResolution -Resolution $Resolution
    $changes = @(Get-SyncPlanChanges -Base $baseMap -Local $Local -Remote $Remote)
    $operations = @(Get-SyncPlanOperationRows `
        -Changes $changes `
        -Base $baseMap `
        -Local $Local `
        -Remote $Remote)

    $baseCapturedAt = $null
    if ($null -ne $Resolution.Base) {
        $capturedProperty = $Resolution.Base.PSObject.Properties['capturedAt']
        if ($null -ne $capturedProperty) {
            $baseCapturedAt = $capturedProperty.Value
        }
    }

    $created = [DateTime]::UtcNow
    $expires = $created.AddMinutes($TtlMinutes)

    return [pscustomobject]@{
        schemaVersion            = [int]$script:RundotSyncSchemaVersion
        toolVersion              = [string]$script:RundotSyncToolVersion
        planId                   = [string][Guid]::NewGuid()
        projectId                = [string]$ProjectId
        localRootFingerprint     = Get-LocalRootFingerprint -WorkspaceRoot $WorkspaceRoot
        createdAt                = $created.ToString('o')
        expiresAt                = $expires.ToString('o')
        basePresent              = [bool]$Resolution.BasePresent
        untrusted                = [bool]$Resolution.Untrusted
        baseCapturedAt           = $baseCapturedAt
        remoteManifestHashBefore = [string]$Snapshot.RemoteManifestHashBefore
        remoteManifestHashAfter  = [string]$Snapshot.RemoteManifestHashAfter
        localManifestHash        = Get-SyncLocalManifestFingerprint -Local $Local
        operations               = $operations
    }
}

function Assert-PlanArtifactShape {
    param($Artifact)

    if ($null -eq $Artifact) {
        throw [System.InvalidOperationException]::new('Plan artifact is missing.')
    }

    foreach ($name in @(
        'schemaVersion',
        'toolVersion',
        'planId',
        'projectId',
        'localRootFingerprint',
        'createdAt',
        'expiresAt',
        'basePresent',
        'untrusted',
        'baseCapturedAt',
        'remoteManifestHashBefore',
        'remoteManifestHashAfter',
        'localManifestHash',
        'operations'
    )) {
        if ($null -eq $Artifact.PSObject.Properties[$name]) {
            throw [System.InvalidOperationException]::new(
                "Plan artifact is missing '$name'."
            )
        }
    }

    $parsedPlanId = [Guid]::Empty
    if (-not [Guid]::TryParse([string]$Artifact.planId, [ref]$parsedPlanId)) {
        throw [System.InvalidOperationException]::new(
            "Plan artifact planId is not a GUID."
        )
    }

    if ([int]$Artifact.schemaVersion -ne $script:SyncPlanArtifactSchemaVersion) {
        throw [System.InvalidOperationException]::new(
            "Plan artifact schemaVersion '$($Artifact.schemaVersion)' is not supported."
        )
    }
}

function Save-PlanArtifact {
    # Atomic write: a crash must never leave a truncated live plan that a
    # caller could read as evidence. Mirrors Save-BaseManifest, but only ever
    # writes plan state: it never touches BASE.
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        $Artifact
    )

    Assert-PlanArtifactShape -Artifact $Artifact

    Initialize-RundotSyncLayout -WorkspaceRoot $WorkspaceRoot

    $syncRoot = Get-RundotSyncRoot -WorkspaceRoot $WorkspaceRoot
    $dest = Join-Path $syncRoot 'last-plan.json'
    $tmp = Join-Path $syncRoot 'last-plan.json.tmp'
    $json = $Artifact | ConvertTo-Json -Depth 8
    $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($json)

    $stream = New-Object System.IO.FileStream(
        $tmp,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
    )
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }

    if (Test-Path -LiteralPath $dest) {
        $backup = Join-Path $syncRoot 'last-plan.json.bak'
        [System.IO.File]::Replace($tmp, $dest, $backup)
        if (Test-Path -LiteralPath $backup) {
            Remove-Item -LiteralPath $backup -Force
        }
    }
    else {
        [System.IO.File]::Move($tmp, $dest)
    }
}

function Read-PlanArtifact {
    # Reads only the complete live file. A leftover .tmp from a crash is
    # ignored, and a missing artifact is a normal first-run state.
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot
    )

    $dest = Get-PlanArtifactPath -WorkspaceRoot $WorkspaceRoot
    if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) {
        return $null
    }

    $utf8 = New-Object System.Text.UTF8Encoding $false, $true
    $stream = New-Object System.IO.FileStream(
        $dest,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    try {
        $reader = New-Object System.IO.StreamReader($stream, $utf8, $false, 1024, $true)
        try {
            $json = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }

    $artifact = $json | ConvertFrom-Json
    Assert-PlanArtifactShape -Artifact $artifact
    return $artifact
}

function Get-SyncPlanNormalizedText {
    # Decode exact bytes for a display-only comparison. Never a decision input.
    param([byte[]]$Bytes)

    $hasBom = $false
    $start = 0

    if (
        ($null -ne $Bytes) -and
        $Bytes.Length -ge 3 -and
        $Bytes[0] -eq 0xEF -and
        $Bytes[1] -eq 0xBB -and
        $Bytes[2] -eq 0xBF
    ) {
        $hasBom = $true
        $start = 3
    }

    $length = 0
    if ($null -ne $Bytes) {
        $length = $Bytes.Length - $start
    }

    $text = ''
    if ($length -gt 0) {
        $text = (New-Object System.Text.UTF8Encoding $false).GetString($Bytes, $start, $length)
    }

    return [pscustomobject]@{
        Text   = [string]$text
        HasBom = [bool]$hasBom
    }
}

function Get-SyncPlanNewlineNormalized {
    param([string]$Text)

    return ([string]$Text).Replace("`r`n", "`n").Replace("`r", "`n")
}

function Get-SyncTextDiagnostics {
    # Report LOCAL/REMOTE text pairs whose exact bytes differ but whose
    # BOM-stripped, newline-normalized text is identical. This is a diagnostic
    # only: classification stays exact-byte based, so the row keeps its real
    # upload/download/conflict status.
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [object[]]$Changes,

        $Local,

        $Remote
    )

    $diagnostics = New-Object 'System.Collections.Generic.List[object]'

    foreach ($change in @($Changes)) {
        if ([bool]$change.Ignored) {
            continue
        }

        $path = [string]$change.Path
        if ([string]::IsNullOrEmpty($path)) {
            continue
        }

        $localEntry = Get-SyncMapEntry -Map $Local -Path $path
        $remoteEntry = Get-SyncMapEntry -Map $Remote -Path $path
        if ($null -eq $localEntry -or $null -eq $remoteEntry) {
            continue
        }

        if (
            (Get-SyncEntryKind -Entry $localEntry) -ne 'utf8' -or
            (Get-SyncEntryKind -Entry $remoteEntry) -ne 'utf8'
        ) {
            continue
        }

        if (
            Test-SyncHashEqual `
                -LeftSha256 $change.LocalSha256 `
                -RightSha256 $change.RemoteSha256
        ) {
            continue
        }

        $stagingPath = Get-SyncEntryProperty -Entry $remoteEntry -Names @('StagingPath', 'stagingPath')
        if ([string]::IsNullOrEmpty([string]$stagingPath)) {
            continue
        }

        $localBytes = $null
        $remoteBytes = $null
        try {
            $localFull = ConvertTo-LocalFullPath -WorkspaceRoot $WorkspaceRoot -CanonicalPath $path
            if (-not (Test-Path -LiteralPath $localFull -PathType Leaf)) {
                continue
            }

            $localBytes = [System.IO.File]::ReadAllBytes($localFull)
            $remoteBytes = [System.IO.File]::ReadAllBytes([string]$stagingPath)
        }
        catch {
            # A diagnostic is optional. A read failure must never fail a plan.
            continue
        }

        $localText = Get-SyncPlanNormalizedText -Bytes $localBytes
        $remoteText = Get-SyncPlanNormalizedText -Bytes $remoteBytes

        $localRaw = [string]$localText.Text
        $remoteRaw = [string]$remoteText.Text

        $bomDiffers = ([bool]$localText.HasBom) -ne ([bool]$remoteText.HasBom)
        $newlineDiffers = -not [string]::Equals(
            $localRaw,
            $remoteRaw,
            [System.StringComparison]::Ordinal
        )

        $normalizedLocal = Get-SyncPlanNewlineNormalized -Text $localRaw
        $normalizedRemote = Get-SyncPlanNewlineNormalized -Text $remoteRaw

        if (
            -not [string]::Equals(
                $normalizedLocal,
                $normalizedRemote,
                [System.StringComparison]::Ordinal
            )
        ) {
            # The text genuinely differs; there is nothing to diagnose.
            continue
        }

        if (-not $bomDiffers -and -not $newlineDiffers) {
            continue
        }

        $difference = 'newline'
        if ($bomDiffers -and $newlineDiffers) {
            $difference = 'bom+newline'
        }
        elseif ($bomDiffers) {
            $difference = 'bom'
        }

        $diagnostics.Add([pscustomobject]@{
            Path       = $path
            Difference = $difference
        })
    }

    return $diagnostics.ToArray()
}

function Format-SyncPlanOperationLine {
    param($Operation)

    $line = (
        '  {0}  base={1}  local={2}  remote={3}' -f `
            $Operation.path,
            (Format-SyncPlanShortHash -Value $Operation.baseSha256),
            (Format-SyncPlanShortHash -Value $Operation.localSha256),
            (Format-SyncPlanShortHash -Value $Operation.remoteSha256)
    )

    if (-not [string]::IsNullOrEmpty([string]$Operation.reason)) {
        $reason = ([string]$Operation.reason).Replace("`r", ' ').Replace("`n", ' ')
        $line = $line + '  - ' + $reason
    }

    if (-not [string]::IsNullOrEmpty([string]$Operation.warning)) {
        $warning = ([string]$Operation.warning).Replace("`r", ' ').Replace("`n", ' ')
        $line = $line + '  (warning: ' + $warning + ')'
    }

    return $line
}

function Get-SyncPlanNonNoOpRows {
    param([object[]]$Operations)

    return @($Operations | Where-Object { -not (Test-SyncNoOpStatus -Status ([string]$_.status)) })
}

function Format-SyncPlanReport {
    # One string. Section headers appear only when they have rows, and the
    # three dry-run lines always close the report.
    param(
        [string]$Command,

        $Artifact,

        [object[]]$Diagnostics,

        [bool]$IncludeUnchanged,

        [string]$ArtifactPath
    )

    $operations = @($Artifact.operations)
    $lines = New-Object 'System.Collections.Generic.List[string]'

    $lines.Add("RUN Game Studio Sync - $Command")
    $lines.Add(('planId:    {0}' -f [string]$Artifact.planId))
    $lines.Add(('createdAt: {0}' -f [string]$Artifact.createdAt))
    $lines.Add(('expiresAt: {0}' -f [string]$Artifact.expiresAt))

    if ([bool]$Artifact.untrusted) {
        foreach ($bannerLine in ((Get-RundotSyncNoBaseUntrustedBanner) -split "`n")) {
            $lines.Add([string]$bannerLine)
        }
    }
    elseif ([bool]$Artifact.basePresent) {
        $lines.Add(('BASE: verified (capturedAt {0})' -f [string]$Artifact.baseCapturedAt))
    }
    else {
        $lines.Add('BASE: none recorded for this plan')
    }

    $sections = @(
        [pscustomobject]@{
            Header = 'UPLOAD'
            Rows   = @($operations | Where-Object { $_.status -eq $script:SyncStatusUpload })
        }
        [pscustomobject]@{
            Header = 'DOWNLOAD'
            Rows   = @($operations | Where-Object { $_.status -eq $script:SyncStatusDownload })
        }
        [pscustomobject]@{
            Header = 'CONFLICT'
            Rows   = @($operations | Where-Object {
                $_.status -eq $script:SyncStatusConflict -and -not $_.kindChange
            })
        }
        [pscustomobject]@{
            Header = 'STAGED DELETES'
            Rows   = @($operations | Where-Object {
                $_.status -eq $script:SyncStatusDeleteRemoteCandidate -or
                $_.status -eq $script:SyncStatusDeleteLocalCandidate
            })
        }
        [pscustomobject]@{
            Header = 'IGNORED'
            Rows   = @($operations | Where-Object { $_.status -eq $script:SyncStatusIgnored })
        }
        [pscustomobject]@{
            Header = 'UNSUPPORTED'
            Rows   = @($operations | Where-Object { $_.kindChange })
        }
    )

    if ($IncludeUnchanged) {
        $sections += [pscustomobject]@{
            Header = 'UNCHANGED'
            Rows   = @($operations | Where-Object {
                Test-SyncNoOpStatus -Status ([string]$_.status)
            })
        }
    }

    foreach ($section in $sections) {
        $rows = @($section.Rows)
        if ($rows.Count -eq 0) {
            continue
        }

        $lines.Add('')
        $lines.Add([string]$section.Header)
        foreach ($row in $rows) {
            $lines.Add((Format-SyncPlanOperationLine -Operation $row))
        }
    }

    $diagnosticRows = @($Diagnostics)
    if ($diagnosticRows.Count -gt 0) {
        $lines.Add('')
        $lines.Add('DIAGNOSTIC')
        foreach ($diagnostic in $diagnosticRows) {
            $lines.Add((
                '  {0}  text differs only by {1}; bytes differ exactly' -f `
                    [string]$diagnostic.Path,
                    [string]$diagnostic.Difference
            ))
        }
    }

    $lines.Add('')
    $lines.Add('SUMMARY')
    $lines.Add(('  total: {0}' -f $operations.Count))

    foreach ($status in @(
        $script:SyncStatusUpload,
        $script:SyncStatusDownload,
        $script:SyncStatusConflict,
        $script:SyncStatusDeleteRemoteCandidate,
        $script:SyncStatusDeleteLocalCandidate,
        $script:SyncStatusIgnored,
        $script:SyncStatusUnchanged,
        $script:SyncStatusSynchronizedChange,
        $script:SyncStatusSynchronizedAddition,
        $script:SyncStatusSettledAbsent
    )) {
        $count = @($operations | Where-Object { $_.status -eq $status }).Count
        $lines.Add(('  {0}: {1}' -f $status, $count))
    }

    $lines.Add(('  applicable: {0}' -f @($operations | Where-Object { $_.applicable }).Count))

    if (-not [string]::IsNullOrEmpty($ArtifactPath)) {
        $lines.Add(('  saved: {0}' -f $ArtifactPath))
    }

    $lines.Add('')
    foreach ($closingLine in (Get-SyncPlanDryRunClosingLines)) {
        $lines.Add([string]$closingLine)
    }

    return [string]::Join("`n", $lines.ToArray())
}

function Get-SyncPlanDryRunClosingLines {
    return $script:SyncPlanDryRunClosingLines
}

function New-RundotSyncPlanAnalysis {
    # The single entrypoint the CLI calls. It composes the classifier, the
    # artifact, the text diagnostics, and the report. It persists the artifact
    # only when asked, so Status runs the identical engine without writing.
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        $Resolution,

        [Parameter(Mandatory)]
        $Local,

        [Parameter(Mandatory)]
        $Remote,

        [Parameter(Mandatory)]
        $Snapshot,

        [string]$Command = 'Plan',

        [switch]$IncludeUnchanged,

        [switch]$PersistArtifact,

        [double]$TtlMinutes = 20,

        [object[]]$Changes = $null
    )

    $artifact = New-RundotSyncPlanArtifact `
        -WorkspaceRoot $WorkspaceRoot `
        -ProjectId $ProjectId `
        -Resolution $Resolution `
        -Local $Local `
        -Remote $Remote `
        -Snapshot $Snapshot `
        -TtlMinutes $TtlMinutes

    $artifactPath = $null
    if ($PersistArtifact) {
        Save-PlanArtifact -WorkspaceRoot $WorkspaceRoot -Artifact $artifact
        $artifactPath = Get-PlanArtifactPath -WorkspaceRoot $WorkspaceRoot
    }

    $changeRows = $Changes
    if ($null -eq $changeRows) {
        $baseMap = Get-SyncPlanBaseMapFromResolution -Resolution $Resolution
        $changeRows = @(Get-SyncPlanChanges -Base $baseMap -Local $Local -Remote $Remote)
    }

    $diagnostics = @(Get-SyncTextDiagnostics `
        -WorkspaceRoot $WorkspaceRoot `
        -Changes $changeRows `
        -Local $Local `
        -Remote $Remote)

    $report = Format-SyncPlanReport `
        -Command $Command `
        -Artifact $artifact `
        -Diagnostics $diagnostics `
        -IncludeUnchanged ([bool]$IncludeUnchanged) `
        -ArtifactPath $artifactPath

    return [pscustomobject]@{
        Command     = [string]$Command
        Artifact    = $artifact
        Operations  = $artifact.operations
        Diagnostics = $diagnostics
        Report      = $report
        ArtifactPath = $artifactPath
    }
}
