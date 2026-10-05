# Shared display form for SHA-256 values in plan and Adopt reports.
# Empty or null renders as <none>. Values of 16 characters or fewer are
# unchanged. Longer values render as the first 8 characters, '...', and the
# last 4.

function Format-SyncShortHash {
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

function Get-RundotSyncInitFromRemoteSummaryLines {
    param(
        [Parameter(Mandatory)]
        [int]$FileCount,

        $Unverifiable
    )

    $lines = New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add(("  Files verified and promoted: {0}" -f $FileCount))

    $unverifiableRows = @($Unverifiable)
    if ($unverifiableRows.Count -gt 0) {
        [void]$lines.Add(
            ("  {0} file(s) over Studio's read limit were not downloaded and are not tracked in BASE." -f `
                $unverifiableRows.Count)
        )
        foreach ($row in $unverifiableRows) {
            [void]$lines.Add(
                ("    {0}  ({1} bytes)" -f [string]$row.Path, [string]$row.Size)
            )
        }
    }

    return $lines.ToArray()
}

function Format-RundotSyncAdoptReport {
    param(
        [Parameter(Mandatory)]
        $Comparisons,

        [Parameter(Mandatory)]
        [int]$BaseFileCount
    )

    $identical = New-Object 'System.Collections.Generic.List[object]'
    $conflicts = New-Object 'System.Collections.Generic.List[object]'
    $localOnly = New-Object 'System.Collections.Generic.List[object]'
    $remoteOnly = New-Object 'System.Collections.Generic.List[object]'
    $ignored = New-Object 'System.Collections.Generic.List[object]'
    $unverifiable = New-Object 'System.Collections.Generic.List[object]'

    foreach ($row in @($Comparisons)) {
        switch ([string]$row.Status) {
            'Identical' { [void]$identical.Add($row) }
            'Conflict' { [void]$conflicts.Add($row) }
            'LocalOnly' { [void]$localOnly.Add($row) }
            'RemoteOnly' { [void]$remoteOnly.Add($row) }
            'IgnoredRemote' { [void]$ignored.Add($row) }
            'Unverifiable' { [void]$unverifiable.Add($row) }
        }
    }

    $total = @($Comparisons).Count
    $unresolved = $conflicts.Count + $localOnly.Count + $remoteOnly.Count + $ignored.Count + $unverifiable.Count

    $lines = New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add('Init Adopt unresolved paths')
    [void]$lines.Add('===========================')
    [void]$lines.Add(
        ('IDENTICAL (BASE): {0}      CONFLICT: {1}      LOCAL-ONLY: {2}' -f `
            $identical.Count, $conflicts.Count, $localOnly.Count)
    )
    [void]$lines.Add(
        ('REMOTE-ONLY: {0}            IGNORED: {1}            UNVERIFIABLE: {2}' -f `
            $remoteOnly.Count, $ignored.Count, $unverifiable.Count)
    )

    if ($conflicts.Count -gt 0) {
        [void]$lines.Add('')
        [void]$lines.Add('CONFLICT')
        foreach ($row in $conflicts) {
            [void]$lines.Add(
                ('  {0}  local={1}  remote={2}' -f `
                    $row.Path,
                    (Format-SyncShortHash -Value $row.LocalSha256),
                    (Format-SyncShortHash -Value $row.RemoteSha256))
            )
        }
    }

    if ($localOnly.Count -gt 0) {
        [void]$lines.Add('')
        [void]$lines.Add('LOCAL-ONLY')
        foreach ($row in $localOnly) {
            [void]$lines.Add(
                ('  {0}  local={1}' -f $row.Path, (Format-SyncShortHash -Value $row.LocalSha256))
            )
        }
    }

    if ($remoteOnly.Count -gt 0) {
        [void]$lines.Add('')
        [void]$lines.Add('REMOTE-ONLY')
        foreach ($row in $remoteOnly) {
            [void]$lines.Add(
                ('  {0}  remote={1}' -f $row.Path, (Format-SyncShortHash -Value $row.RemoteSha256))
            )
        }
    }

    if ($ignored.Count -gt 0) {
        [void]$lines.Add('')
        [void]$lines.Add('IGNORED (matches the default ignore set)')
        foreach ($row in $ignored) {
            [void]$lines.Add(('  {0}' -f $row.Path))
        }
    }

    if ($unverifiable.Count -gt 0) {
        [void]$lines.Add('')
        [void]$lines.Add('UNVERIFIABLE (over Studio read limit)')
        foreach ($row in $unverifiable) {
            $listedSize = Get-SyncEntrySizeValue -Entry $row.RemoteEntry
            [void]$lines.Add(('  {0}  size={1}' -f $row.Path, [string]$listedSize))
        }
    }

    [void]$lines.Add('')
    [void]$lines.Add(
        ('BASE records only path+hash-identical entries: {0} of {1} paths.' -f `
            $BaseFileCount, $total)
    )

    if ($unresolved -gt 0) {
        [void]$lines.Add('Every path listed above is unresolved; it is not evidence of a safe sync direction.')
    }

    if ($BaseFileCount -eq 0) {
        [void]$lines.Add('')
        [void]$lines.Add('WARNING: no proven-identical paths. Synchronization direction is untrusted for every path.')
    }

    return ($lines.ToArray() -join "`n")
}
