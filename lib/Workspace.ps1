# BASE workspace layout, ownership, and atomic manifest I/O.
# Hashes and metadata only. Callers must load Paths.ps1 first.

$script:RundotSyncSchemaVersion = 1
$script:RundotSyncToolVersion = "0.1.2"

function Get-RundotSyncRoot {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot
    )

    $root = Get-NormalizedWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    return Join-Path $root ".rundot-sync"
}

function Get-BaseManifestPath {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot
    )

    return Join-Path (Get-RundotSyncRoot -WorkspaceRoot $WorkspaceRoot) "base-manifest.json"
}

function Convert-Utf8Sha256Hex {
    param([string]$Text)

    $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }

    return [System.BitConverter]::ToString($hash).Replace("-", "").ToLowerInvariant()
}

function Initialize-RundotSyncLayout {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot
    )

    $syncRoot = Get-RundotSyncRoot -WorkspaceRoot $WorkspaceRoot
    New-Item -ItemType Directory -Force -Path (Join-Path $syncRoot "backups") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $syncRoot "temp") | Out-Null
}

function Get-LocalRootFingerprint {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot
    )

    $normalized = Get-NormalizedWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $item = Get-Item -LiteralPath $normalized
    $full = $item.FullName.TrimEnd('\')
    $nfc = $full.Normalize([System.Text.NormalizationForm]::FormC)
    return Convert-Utf8Sha256Hex -Text $nfc
}

function Get-BaseFileEntryKind {
    param($Entry)

    if ($null -ne $Entry.PSObject.Properties['kind'] -and -not [string]::IsNullOrEmpty($Entry.kind)) {
        return [string]$Entry.kind
    }

    if ($null -ne $Entry.PSObject.Properties['Kind'] -and -not [string]::IsNullOrEmpty($Entry.Kind)) {
        return [string]$Entry.Kind
    }

    if ($null -ne $Entry.PSObject.Properties['LocalDetectedKind']) {
        return [string]$Entry.LocalDetectedKind
    }

    return $null
}

function Get-BaseFileEntryProperty {
    param(
        $Entry,
        [string[]]$Names
    )

    foreach ($name in $Names) {
        $property = $Entry.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) {
            return $property.Value
        }
    }

    return $null
}

function ConvertTo-BaseFileEntry {
    param($Entry)

    $kind = Get-BaseFileEntryKind -Entry $Entry
    $sha256 = [string](Get-BaseFileEntryProperty -Entry $Entry -Names @('sha256', 'Sha256'))
    $size = Get-BaseFileEntryProperty -Entry $Entry -Names @('size', 'Size')

    $map = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)
    $map['sha256'] = $sha256
    $map['size'] = [int64]$size
    $map['kind'] = $kind

    if ($kind -eq 'utf8') {
        $map['lineEnding'] = Get-BaseFileEntryProperty -Entry $Entry -Names @('lineEnding', 'LineEnding')
        $hasBom = Get-BaseFileEntryProperty -Entry $Entry -Names @('hasBom', 'HasBom')
        $map['hasBom'] = [bool]$hasBom
    }

    return $map
}

function ConvertTo-BaseFilesMap {
    param($Files)

    $map = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)

    if ($Files -is [System.Collections.IDictionary]) {
        foreach ($key in @($Files.Keys)) {
            $map[[string]$key] = ConvertTo-BaseFileEntry -Entry $Files[$key]
        }

        return $map
    }

    foreach ($property in $Files.PSObject.Properties) {
        $map[[string]$property.Name] = ConvertTo-BaseFileEntry -Entry $property.Value
    }

    return $map
}

function ConvertTo-BaseManifestObject {
    param(
        [string]$WorkspaceRoot,
        [string]$ProjectId,
        $Files
    )

    $payload = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)
    $payload['schemaVersion'] = [int]$script:RundotSyncSchemaVersion
    $payload['toolVersion'] = $script:RundotSyncToolVersion
    $payload['projectId'] = $ProjectId
    $payload['localRootFingerprint'] = Get-LocalRootFingerprint -WorkspaceRoot $WorkspaceRoot
    $payload['capturedAt'] = [DateTime]::UtcNow.ToString('o')
    $payload['files'] = ConvertTo-BaseFilesMap -Files $Files
    return $payload
}

function Save-BaseManifest {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        $Files
    )

    Initialize-RundotSyncLayout -WorkspaceRoot $WorkspaceRoot

    $syncRoot = Get-RundotSyncRoot -WorkspaceRoot $WorkspaceRoot
    $dest = Join-Path $syncRoot "base-manifest.json"
    $tmp = Join-Path $syncRoot "base-manifest.json.tmp"
    $payload = ConvertTo-BaseManifestObject `
        -WorkspaceRoot $WorkspaceRoot `
        -ProjectId $ProjectId `
        -Files $Files
    $json = $payload | ConvertTo-Json -Depth 8
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
        $backup = Join-Path $syncRoot "base-manifest.json.bak"
        [System.IO.File]::Replace($tmp, $dest, $backup)
        if (Test-Path -LiteralPath $backup) {
            Remove-Item -LiteralPath $backup -Force
        }
    }
    else {
        [System.IO.File]::Move($tmp, $dest)
    }
}

function Assert-BaseManifestShape {
    param($Base)

    if ($null -eq $Base) {
        throw [System.InvalidOperationException]::new("BASE manifest is missing required fields.")
    }

    foreach ($name in @('schemaVersion', 'toolVersion', 'projectId', 'localRootFingerprint', 'capturedAt', 'files')) {
        if ($null -eq $Base.PSObject.Properties[$name]) {
            throw [System.InvalidOperationException]::new("BASE manifest is missing '$name'.")
        }
    }
}

function Read-BaseManifest {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot
    )

    $dest = Get-BaseManifestPath -WorkspaceRoot $WorkspaceRoot
    if (-not (Test-Path -LiteralPath $dest)) {
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

    $base = $json | ConvertFrom-Json
    Assert-BaseManifestShape -Base $base
    return $base
}

function Assert-BaseOwnership {
    param(
        [Parameter(Mandatory)]
        $Base,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [string]$WorkspaceRoot
    )

    if ($null -eq $Base) {
        throw [System.InvalidOperationException]::new("BASE manifest is missing.")
    }

    foreach ($name in @('schemaVersion', 'projectId', 'localRootFingerprint')) {
        if ($null -eq $Base.PSObject.Properties[$name]) {
            throw [System.InvalidOperationException]::new("BASE manifest is missing '$name'.")
        }
    }

    $schemaVersion = [int]$Base.schemaVersion
    if ($schemaVersion -ne $script:RundotSyncSchemaVersion) {
        throw [System.InvalidOperationException]::new(
            "BASE schemaVersion '$schemaVersion' is not supported."
        )
    }

    if (-not [string]::Equals([string]$Base.projectId, $ProjectId, [System.StringComparison]::Ordinal)) {
        throw [System.InvalidOperationException]::new(
            "BASE projectId does not match this workspace."
        )
    }

    $expectedFingerprint = Get-LocalRootFingerprint -WorkspaceRoot $WorkspaceRoot
    if (
        -not [string]::Equals(
            [string]$Base.localRootFingerprint,
            $expectedFingerprint,
            [System.StringComparison]::Ordinal
        )
    ) {
        throw [System.InvalidOperationException]::new(
            "BASE localRootFingerprint does not match this workspace folder."
        )
    }
}
