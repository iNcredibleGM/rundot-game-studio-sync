# Append-only journal for sync runs.
#
# The journal is the durable audit trail of a mutating command. It records
# METADATA ONLY: what ran, which plan and backup set it belonged to, what it
# changed, and whether BASE was updated. It never records file contents, access
# tokens, refresh tokens, or Authorization headers.
#
# Fields are written from a fixed allowlist, so a caller cannot widen the
# record by passing an unexpected key. A serialized line is additionally
# checked for credential-shaped text, and a line that trips that check is
# refused rather than written.
#
# The file is JSONL: one compact JSON object per line, UTF-8 without a BOM,
# append-only. A crash can leave a partial trailing line; readers skip it and
# never rewrite the file.
#
# Callers must load Paths.ps1, Hashing.ps1, and Workspace.ps1 first.

$script:RundotSyncJournalFileName = 'journal.jsonl'

# The complete set of metadata fields a journal record may carry. Any other
# key is dropped rather than written.
$script:RundotSyncJournalAllowedFields = @(
    'status',
    'projectId',
    'planId',
    'backupSet',
    'applied',
    'overwritten',
    'created',
    'skipped',
    'baseUpdated',
    'reason'
)

# Belt and suspenders: even an allowlisted field must not carry a credential
# or file contents. 'content' and 'stagingpath' are included so a future field
# rename cannot quietly start recording them.
$script:RundotSyncJournalSensitivePattern = (
    '(?i)bearer|authoriz|access[_-]?token|refresh[_-]?token|"content"|stagingpath'
)

function Get-RundotSyncJournalPath {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot
    )

    return Join-Path `
        (Get-RundotSyncRoot -WorkspaceRoot $WorkspaceRoot) `
        $script:RundotSyncJournalFileName
}

function Get-RundotSyncJournalPropertyValue {
    # Read a field from either a hashtable or an object without normalizing
    # the caller. A missing field is $null, never an error.
    param(
        $Record,
        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Record) {
        return $null
    }

    if ($Record -is [System.Collections.IDictionary]) {
        if ($Record.Contains($Name)) {
            return $Record[$Name]
        }

        return $null
    }

    $property = $Record.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function Assert-SyncJournalLineSafe {
    # Refuse a serialized line that contains credential-shaped text. The
    # rejected value is deliberately not echoed: it is the secret.
    param(
        [Parameter(Mandatory)]
        [string]$Line
    )

    if ($Line -match $script:RundotSyncJournalSensitivePattern) {
        throw [System.InvalidOperationException]::new(
            'Refusing to write a journal record: it contains a value that looks like a credential.'
        )
    }
}

function Format-RundotSyncJournalLine {
    # Build the ordered metadata object and serialize it compactly. Only
    # allowlisted fields are copied, so an unexpected key is dropped.
    param(
        [Parameter(Mandatory)]
        [string]$Event,

        $Record,

        [DateTime]$Timestamp = [DateTime]::UtcNow
    )

    $ordered = New-Object 'System.Collections.Specialized.OrderedDictionary' (
        [System.StringComparer]::Ordinal
    )
    $ordered['timestamp'] = $Timestamp.ToUniversalTime().ToString('o')
    $ordered['event'] = [string]$Event

    foreach ($name in $script:RundotSyncJournalAllowedFields) {
        $value = Get-RundotSyncJournalPropertyValue -Record $Record -Name $name
        if ($null -eq $value) {
            continue
        }

        $ordered[$name] = $value
    }

    return ($ordered | ConvertTo-Json -Compress -Depth 4)
}

function Test-RundotSyncJournalNeedsTerminator {
    # True when an existing journal does not end with a newline, so the next
    # append must terminate the torn line before starting a new one. Without
    # this, a record appended after a crash would merge into the partial line.
    param([Parameter(Mandatory)][string]$JournalPath)

    if (-not (Test-Path -LiteralPath $JournalPath -PathType Leaf)) {
        return $false
    }

    $info = New-Object System.IO.FileInfo $JournalPath
    if ($info.Length -le 0) {
        return $false
    }

    $stream = New-Object System.IO.FileStream(
        $JournalPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite
    )
    try {
        [void]$stream.Seek(-1, [System.IO.SeekOrigin]::End)
        return ($stream.ReadByte() -ne 0x0A)
    }
    finally {
        $stream.Dispose()
    }
}

function Add-RundotSyncJournalRecord {
    # Append one metadata-only record. Returns the ordered record that was
    # written so a caller can log or assert on it.
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$Event,

        $Record,

        [DateTime]$Timestamp = [DateTime]::UtcNow
    )

    Initialize-RundotSyncLayout -WorkspaceRoot $WorkspaceRoot

    $line = Format-RundotSyncJournalLine -Event $Event -Record $Record -Timestamp $Timestamp
    Assert-SyncJournalLineSafe -Line $line

    $journalPath = Get-RundotSyncJournalPath -WorkspaceRoot $WorkspaceRoot
    $utf8 = New-Object System.Text.UTF8Encoding $false

    $prefix = ''
    if (Test-RundotSyncJournalNeedsTerminator -JournalPath $journalPath) {
        $prefix = "`n"
    }

    [System.IO.File]::AppendAllText($journalPath, ($prefix + $line + "`n"), $utf8)

    return ($line | ConvertFrom-Json)
}

function Read-RundotSyncJournal {
    # Read every complete record. A missing file is a normal first-run state,
    # and a torn trailing line is skipped rather than repaired.
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot
    )

    $journalPath = Get-RundotSyncJournalPath -WorkspaceRoot $WorkspaceRoot
    if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
        return @()
    }

    $utf8 = New-Object System.Text.UTF8Encoding $false, $true
    $raw = [System.IO.File]::ReadAllText($journalPath, $utf8)
    if ([string]::IsNullOrEmpty($raw)) {
        return @()
    }

    $records = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in @($raw -split "`n")) {
        if ($line.Length -eq 0) {
            continue
        }

        try {
            [void]$records.Add(($line | ConvertFrom-Json))
        }
        catch {
            # A partial line from an interrupted append is not a record.
            continue
        }
    }

    if ($records.Count -eq 0) {
        return @()
    }

    return $records.ToArray()
}
