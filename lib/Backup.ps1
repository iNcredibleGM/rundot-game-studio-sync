# Backup sets for Pull and Push overwrites.
#
# Before Pull replaces a local file, or before Push replaces a remote file, the
# original being overwritten is copied into a timestamped set under
# .rundot-sync/backups so any overwrite is recoverable by a plain file copy.
# Pull backs up LOCAL originals; Push backs up the previous REMOTE bytes it
# fetched immediately before the write. Backups are metadata-free: the bytes of
# the original, nothing else. No tokens, no journal records, no manifests live
# in a backup set.
#
# A backup set name is a UTC timestamp plus an optional counter suffix, so sets
# sort chronologically by ordinal name comparison and two sets created in the
# same millisecond still get distinct folders.
#
# Callers must load Paths.ps1, Hashing.ps1, and Workspace.ps1 first.

$script:RundotSyncBackupSetTimestampFormat = 'yyyyMMddTHHmmssfff\Z'
$script:RundotSyncBackupSetNamePattern = '^(?<stamp>\d{8}T\d{6}\d{3}Z)(?:-(?<suffix>\d+))?$'

function Get-RundotSyncBackupRoot {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot
    )

    return Join-Path (Get-RundotSyncRoot -WorkspaceRoot $WorkspaceRoot) 'backups'
}

function Get-RundotSyncBackupSetPath {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$Name
    )

    return Join-Path (Get-RundotSyncBackupRoot -WorkspaceRoot $WorkspaceRoot) $Name
}

function New-RundotSyncBackupSetName {
    # Base name is ordinal-sortable and parseable. Suffix 0 is the bare
    # timestamp; higher suffixes disambiguate same-millisecond sets.
    param(
        [DateTime]$Timestamp = [DateTime]::UtcNow,

        [int]$Suffix = 0
    )

    $base = $Timestamp.ToUniversalTime().ToString(
        $script:RundotSyncBackupSetTimestampFormat,
        [System.Globalization.CultureInfo]::InvariantCulture
    )

    if ($Suffix -le 0) {
        return $base
    }

    return ('{0}-{1}' -f $base, $Suffix)
}

function Get-RundotSyncBackupSetTimestamp {
    # $null when the folder name is not a backup-set name. Never throws:
    # retention must be able to skip an unrecognized directory.
    param([string]$Name)

    $text = [string]$Name
    if ([string]::IsNullOrEmpty($text)) {
        return $null
    }

    $match = [regex]::Match($text, $script:RundotSyncBackupSetNamePattern)
    if (-not $match.Success) {
        return $null
    }

    $parsed = [DateTime]::MinValue
    $ok = [DateTime]::TryParseExact(
        $match.Groups['stamp'].Value,
        $script:RundotSyncBackupSetTimestampFormat,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal,
        [ref]$parsed
    )

    if (-not $ok) {
        return $null
    }

    return $parsed
}

function New-RundotSyncBackupSet {
    # Creates and returns one backup set. The returned object is what the
    # caller prints after a mutating pull, so no absolute path is inferred
    # later.
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [DateTime]$Timestamp = [DateTime]::UtcNow
    )

    Initialize-RundotSyncLayout -WorkspaceRoot $WorkspaceRoot

    $root = Get-RundotSyncBackupRoot -WorkspaceRoot $WorkspaceRoot
    $suffix = 0
    while ($true) {
        $name = New-RundotSyncBackupSetName -Timestamp $Timestamp -Suffix $suffix
        $path = Join-Path $root $name

        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
            return [pscustomobject]@{
                Name      = $name
                Path      = $path
                Timestamp = $Timestamp.ToUniversalTime()
            }
        }

        $suffix++
    }
}

function Invoke-RundotSyncVerifiedCopy {
    # Write DestinationPath so it is either the exact bytes of SourcePath or
    # absent. Copies to a sibling .tmp, re-hashes both sides, then renames.
    # A failed copy never leaves a partial destination.
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$DestinationPath
    )

    $parent = Split-Path -Parent $DestinationPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $tmp = $DestinationPath + '.tmp'
    if (Test-Path -LiteralPath $tmp) {
        Remove-Item -LiteralPath $tmp -Force
    }

    try {
        [System.IO.File]::Copy($SourcePath, $tmp, $true)

        $sourceHash = Get-FileSha256Hex -LiteralPath $SourcePath
        $copyHash = Get-FileSha256Hex -LiteralPath $tmp
        if (-not [string]::Equals($sourceHash, $copyHash, [System.StringComparison]::Ordinal)) {
            throw [System.InvalidOperationException]::new(
                "Copy verification failed for '$DestinationPath'."
            )
        }

        if (Test-Path -LiteralPath $DestinationPath) {
            Remove-Item -LiteralPath $DestinationPath -Force
        }

        [System.IO.File]::Move($tmp, $DestinationPath)
    }
    catch {
        if (Test-Path -LiteralPath $tmp) {
            try {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction Stop
            }
            catch {
                # The destination is never the tmp path, so a stuck tmp is
                # not a partial destination. Surface the original failure.
            }
        }

        throw
    }

    return $DestinationPath
}

function Copy-RundotSyncBackupFile {
    # Copy one local original into a backup set. Callers abort the pull when
    # this throws: no backup means no overwrite.
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$DestinationPath
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw [System.InvalidOperationException]::new(
            "Backup source '$SourcePath' is not a file."
        )
    }

    return Invoke-RundotSyncVerifiedCopy `
        -SourcePath $SourcePath `
        -DestinationPath $DestinationPath
}

function Restore-RundotSyncBackupFile {
    # Put a backed-up original back on disk. Used by pull rollback.
    param(
        [Parameter(Mandatory)]
        [string]$BackupPath,

        [Parameter(Mandatory)]
        [string]$DestinationPath
    )

    if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
        throw [System.InvalidOperationException]::new(
            "Backup file '$BackupPath' is missing."
        )
    }

    return Invoke-RundotSyncVerifiedCopy `
        -SourcePath $BackupPath `
        -DestinationPath $DestinationPath
}

function Get-RundotSyncBackupSets {
    # Every direct child directory of the backup root, ordinal-sorted by name
    # (which is chronological for parseable names). Timestamp is $null for a
    # folder whose name is not a backup-set name.
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot
    )

    $root = Get-RundotSyncBackupRoot -WorkspaceRoot $WorkspaceRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        return @()
    }

    $directories = @(Get-ChildItem -LiteralPath $root -Directory -Force)
    if ($directories.Count -eq 0) {
        return @()
    }

    $names = New-Object string[] $directories.Count
    for ($i = 0; $i -lt $directories.Count; $i++) {
        $names[$i] = $directories[$i].Name
    }
    [Array]::Sort($names, [System.StringComparer]::Ordinal)

    $sets = New-Object 'System.Collections.Generic.List[object]'
    foreach ($name in $names) {
        $sets.Add([pscustomobject]@{
            Name      = $name
            Path      = Join-Path $root $name
            Timestamp = Get-RundotSyncBackupSetTimestamp -Name $name
        })
    }

    if ($sets.Count -eq 0) {
        return @()
    }

    return $sets.ToArray()
}

function Remove-RundotSyncExpiredBackupSets {
    # Best-effort retention. Keeps the union of:
    #   - the newest MaxSets sets
    #   - every set no older than MaxAgeDays
    # so the policy always gives at least as much recovery as either rule.
    #
    # The in-flight set is never deleted, and a folder whose name is not a
    # backup-set name is never touched. A delete failure is swallowed: losing
    # recovery space is never a reason to fail a pull that already succeeded.
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [string]$KeepName,

        [int]$MaxSets = 10,

        [int]$MaxAgeDays = 7,

        [DateTime]$Now = [DateTime]::UtcNow
    )

    $deleted = New-Object 'System.Collections.Generic.List[string]'

    $parseable = @(
        Get-RundotSyncBackupSets -WorkspaceRoot $WorkspaceRoot |
            Where-Object { $null -ne $_.Timestamp }
    )

    if ($parseable.Count -eq 0) {
        return @()
    }

    $byName = @{}
    $namesAscending = New-Object string[] $parseable.Count
    for ($i = 0; $i -lt $parseable.Count; $i++) {
        $namesAscending[$i] = [string]$parseable[$i].Name
        $byName[$namesAscending[$i]] = $parseable[$i]
    }
    [Array]::Sort($namesAscending, [System.StringComparer]::Ordinal)

    # Newest first, for the "newest MaxSets" rule.
    $namesDescending = New-Object string[] $namesAscending.Length
    $namesAscending.CopyTo($namesDescending, 0)
    [Array]::Reverse($namesDescending)

    $cutoff = $Now.ToUniversalTime().AddDays(-$MaxAgeDays)
    $keep = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)

    if (-not [string]::IsNullOrEmpty($KeepName)) {
        [void]$keep.Add($KeepName)
    }

    for ($i = 0; $i -lt $namesDescending.Length; $i++) {
        $name = $namesDescending[$i]

        if ($i -lt $MaxSets) {
            [void]$keep.Add($name)
            continue
        }

        if ($byName[$name].Timestamp -ge $cutoff) {
            [void]$keep.Add($name)
        }
    }

    # Delete oldest first, so the sets that still give the most recovery are
    # the last to be given up.
    $root = Get-RundotSyncBackupRoot -WorkspaceRoot $WorkspaceRoot
    foreach ($name in $namesAscending) {
        if ($keep.Contains($name)) {
            continue
        }

        try {
            Remove-Item -LiteralPath (Join-Path $root $name) -Recurse -Force -ErrorAction Stop
            [void]$deleted.Add($name)
        }
        catch {
            # Best effort.
        }
    }

    if ($deleted.Count -eq 0) {
        return @()
    }

    return $deleted.ToArray()
}
