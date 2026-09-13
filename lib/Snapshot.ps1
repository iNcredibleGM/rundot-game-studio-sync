# Torn-read remote snapshot helpers.
# Callers must load Paths.ps1, Hashing.ps1, Workspace.ps1, and RemoteApi.ps1 first.
#
# Fingerprint validated /files identity. Never hash a raw or malformed payload.

$script:RemoteFingerprintIdentityFields = @(
    'id',
    'etag',
    'hash',
    'sha256',
    'contentHash',
    'version',
    'revision',
    'updatedAt'
)

function Get-RemoteEntryProperty {
    param(
        $Entry,
        [string[]]$Names
    )

    if ($null -eq $Entry) {
        return $null
    }

    foreach ($name in $Names) {
        $property = $Entry.PSObject.Properties[$name]
        if ($null -ne $property) {
            return $property.Value
        }
    }

    return $null
}

function Test-RemoteEntryHasProperty {
    param(
        $Entry,
        [string[]]$Names
    )

    if ($null -eq $Entry) {
        return $false
    }

    foreach ($name in $Names) {
        if ($null -ne $Entry.PSObject.Properties[$name]) {
            return $true
        }
    }

    return $false
}

function Get-RemoteManifestFilesValue {
    param($Manifest)

    if ($null -eq $Manifest) {
        throw [System.InvalidOperationException]::new(
            "Remote manifest is missing."
        )
    }

    if (-not (Test-RemoteEntryHasProperty -Entry $Manifest -Names @('files'))) {
        throw [System.InvalidOperationException]::new(
            "Remote manifest is missing 'files'."
        )
    }

    return (Get-RemoteEntryProperty -Entry $Manifest -Names @('files'))
}

function ConvertTo-RemoteManifestSize {
    param(
        $Value,
        [string]$Path
    )

    if ($null -eq $Value) {
        throw [System.InvalidOperationException]::new(
            "Remote file '$Path' has an invalid size."
        )
    }

    try {
        $size = [int64]$Value
    }
    catch {
        throw [System.InvalidOperationException]::new(
            "Remote file '$Path' has an invalid size.",
            $_.Exception
        )
    }

    if ($size -lt 0) {
        throw [System.InvalidOperationException]::new(
            "Remote file '$Path' has a negative size."
        )
    }

    if (
        ($Value -is [double] -or $Value -is [float] -or $Value -is [decimal]) -and
        ([decimal]$Value -ne [decimal]$size)
    ) {
        throw [System.InvalidOperationException]::new(
            "Remote file '$Path' has an invalid size."
        )
    }

    return $size
}

function Get-RemoteManifestFileRows {
    param($Manifest)

    $filesValue = Get-RemoteManifestFilesValue -Manifest $Manifest
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $canonicalSeen = New-Object 'System.Collections.Generic.Dictionary[string,string]' (
        [System.StringComparer]::Ordinal
    )

    foreach ($entry in @($filesValue)) {
        $type = [string](Get-RemoteEntryProperty -Entry $entry -Names @('type', 'Type'))
        if ($type -ne 'file') {
            continue
        }

        $rawPath = Get-RemoteEntryProperty -Entry $entry -Names @('path', 'Path')
        if ([string]::IsNullOrWhiteSpace([string]$rawPath)) {
            throw [System.InvalidOperationException]::new(
                "Remote file list contains a file entry without a path."
            )
        }

        $canonical = ConvertTo-CanonicalSyncPath -Path ([string]$rawPath)

        if ($canonicalSeen.ContainsKey($canonical)) {
            $existing = $canonicalSeen[$canonical]
            throw [System.InvalidOperationException]::new(
                "Remote project contains duplicate canonical paths:`n  $existing`n  $rawPath"
            )
        }

        $canonicalSeen[$canonical] = [string]$rawPath

        if (Test-RemoteEntryHasProperty -Entry $entry -Names @('size', 'Size')) {
            [void](ConvertTo-RemoteManifestSize `
                -Value (Get-RemoteEntryProperty -Entry $entry -Names @('size', 'Size')) `
                -Path $canonical)
        }

        foreach ($name in @('encoding', 'kind')) {
            if (Test-RemoteEntryHasProperty -Entry $entry -Names @($name)) {
                $value = Get-RemoteEntryProperty -Entry $entry -Names @($name)
                if ($null -ne $value -and -not ($value -is [string])) {
                    throw [System.InvalidOperationException]::new(
                        "Remote file '$canonical' has a non-string $name."
                    )
                }
            }
        }

        $rows.Add([pscustomobject]@{
            CanonicalPath = $canonical
            Entry         = $entry
        })
    }

    if ($canonicalSeen.Count -gt 0) {
        Assert-SafeSyncPathSet -Paths @($canonicalSeen.Keys)
    }

    return ,$rows
}

function Assert-RemoteManifestValid {
    param($Manifest)

    [void](Get-RemoteManifestFileRows -Manifest $Manifest)
}

function Get-RemoteFingerprintFieldText {
    param(
        $Entry,
        [string]$Name
    )

    if (-not (Test-RemoteEntryHasProperty -Entry $Entry -Names @($Name))) {
        return $null
    }

    $value = Get-RemoteEntryProperty -Entry $Entry -Names @($Name)
    if ($null -eq $value) {
        return $null
    }

    if ($Name -eq 'size') {
        return ('size=' + [string][int64]$value)
    }

    return ($Name + '=' + [string]$value)
}

function Get-RemoteManifestFingerprint {
    param($Manifest)

    $rows = Get-RemoteManifestFileRows -Manifest $Manifest
    $lines = New-Object 'System.Collections.Generic.List[string]'

    foreach ($row in $rows) {
        $fields = New-Object 'System.Collections.Generic.List[string]'
        [void]$fields.Add('canonicalPath=' + $row.CanonicalPath)

        $sizeText = Get-RemoteFingerprintFieldText -Entry $row.Entry -Name 'size'
        if ($null -ne $sizeText) {
            [void]$fields.Add($sizeText)
        }

        foreach ($name in @('encoding', 'kind', 'type')) {
            $text = Get-RemoteFingerprintFieldText -Entry $row.Entry -Name $name
            if ($null -ne $text) {
                [void]$fields.Add($text)
            }
        }

        foreach ($name in $script:RemoteFingerprintIdentityFields) {
            $text = Get-RemoteFingerprintFieldText -Entry $row.Entry -Name $name
            if ($null -ne $text) {
                [void]$fields.Add($text)
            }
        }

        $lines.Add([string]::Join("`t", $fields.ToArray()))
    }

    $sorted = $lines.ToArray()
    if ($sorted.Length -gt 1) {
        [Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    }

    $document = [string]::Join("`n", $sorted)
    return Convert-Utf8Sha256Hex -Text $document
}

function ConvertFrom-RemoteFileContent {
    param($Response)

    if ($null -eq $Response) {
        throw [System.InvalidOperationException]::new(
            "Remote file payload is missing."
        )
    }

    $encoding = Get-RemoteEntryProperty -Entry $Response -Names @('encoding', 'Encoding')
    if ([string]::IsNullOrEmpty([string]$encoding)) {
        throw [System.InvalidOperationException]::new(
            "Unknown encoding ''."
        )
    }

    if (-not (Test-RemoteEntryHasProperty -Entry $Response -Names @('content', 'Content'))) {
        throw [System.InvalidOperationException]::new(
            "Remote file payload is missing 'content'."
        )
    }

    $content = Get-RemoteEntryProperty -Entry $Response -Names @('content', 'Content')
    if ($null -eq $content) {
        throw [System.InvalidOperationException]::new(
            "Remote file payload is missing 'content'."
        )
    }

    if ($encoding -eq 'utf8') {
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        return $utf8NoBom.GetBytes([string]$content)
    }

    if ($encoding -eq 'base64') {
        try {
            return [Convert]::FromBase64String([string]$content)
        }
        catch {
            throw [System.InvalidOperationException]::new(
                "Malformed base64 in remote file payload.",
                $_.Exception
            )
        }
    }

    throw [System.InvalidOperationException]::new(
        "Unknown encoding '$encoding'."
    )
}


$script:RemoteSnapshotMaxAttempts = 3
$script:RemoteSnapshotIdleMessage = @(
    'The remote project changed while being read. No plan was generated.',
    'Try again when the project is idle.'
) -join "`n"


function Get-RemoteSnapshotTempRoot {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot
    )

    return Join-Path `
        (Get-RundotSyncRoot -WorkspaceRoot $WorkspaceRoot) `
        "temp\remote-snapshot"
}

function Clear-RemoteSnapshotTemp {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot
    )

    $root = Get-RemoteSnapshotTempRoot -WorkspaceRoot $WorkspaceRoot
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

function Test-RemoteSnapshotRetryableException {
    param($Exception)

    $current = $Exception
    while ($null -ne $current) {
        if (Test-RemoteNotFoundException -Exception $current) {
            return $true
        }

        $text = [string]$current.Message
        if ($text -match '(?i)Malformed base64') {
            return $true
        }

        $current = $current.InnerException
    }

    return $false
}

function Write-RemoteSnapshotStagingFile {
    param(
        [string]$StagingRoot,
        [string]$CanonicalPath,
        [byte[]]$Bytes
    )

    $full = ConvertTo-LocalFullPath `
        -WorkspaceRoot $StagingRoot `
        -CanonicalPath $CanonicalPath
    $parent = Split-Path -Parent $full
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    if ($null -eq $Bytes) {
        $Bytes = [byte[]]@()
    }

    [System.IO.File]::WriteAllBytes($full, $Bytes)
    return $full
}

function Get-RemoteSnapshotFileMap {
    param(
        $Manifest,
        [string]$StagingRoot,
        [string]$StudioOrigin,
        [string]$ProjectId,
        [hashtable]$Headers
    )

    $files = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)
    $rows = Get-RemoteManifestFileRows -Manifest $Manifest

    foreach ($row in $rows) {
        Assert-SyncPathRepresentable `
            -WorkspaceRoot $StagingRoot `
            -CanonicalPath $row.CanonicalPath

        $originalPath = [string](Get-RemoteEntryProperty -Entry $row.Entry -Names @('path', 'Path'))
        $response = Get-RemoteProjectFile `
            -StudioOrigin $StudioOrigin `
            -ProjectId $ProjectId `
            -Path $originalPath `
            -Headers $Headers

        $bytes = ConvertFrom-RemoteFileContent -Response $response
        $stagingPath = Write-RemoteSnapshotStagingFile `
            -StagingRoot $StagingRoot `
            -CanonicalPath $row.CanonicalPath `
            -Bytes $bytes
        $identity = Get-LocalFileIdentity -LiteralPath $stagingPath
        $encoding = Get-RemoteEntryProperty -Entry $response -Names @('encoding', 'Encoding')

        $files[$row.CanonicalPath] = [pscustomobject]@{
            Sha256            = $identity.Sha256
            Size              = $identity.Size
            LocalDetectedKind = $identity.LocalDetectedKind
            LineEnding        = $identity.LineEnding
            HasBom            = $identity.HasBom
            RemoteKind        = ConvertTo-RemoteKind -Encoding $encoding
            Encoding          = $encoding
            StagingPath       = $stagingPath
        }
    }

    return ,$files
}

function Get-StableRemoteSnapshot {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    Initialize-RundotSyncLayout -WorkspaceRoot $WorkspaceRoot
    Clear-RemoteSnapshotTemp -WorkspaceRoot $WorkspaceRoot

    $attempt = 0
    while ($attempt -lt $script:RemoteSnapshotMaxAttempts) {
        $attempt++
        Clear-RemoteSnapshotTemp -WorkspaceRoot $WorkspaceRoot

        $stagingRoot = Join-Path `
            (Get-RemoteSnapshotTempRoot -WorkspaceRoot $WorkspaceRoot) `
            ([string]$attempt)
        New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null

        try {
            $before = Get-RemoteProjectFileList `
                -StudioOrigin $StudioOrigin `
                -ProjectId $ProjectId `
                -Headers $Headers
            $hashBefore = Get-RemoteManifestFingerprint -Manifest $before

            $files = Get-RemoteSnapshotFileMap `
                -Manifest $before `
                -StagingRoot $stagingRoot `
                -StudioOrigin $StudioOrigin `
                -ProjectId $ProjectId `
                -Headers $Headers

            $after = Get-RemoteProjectFileList `
                -StudioOrigin $StudioOrigin `
                -ProjectId $ProjectId `
                -Headers $Headers
            $hashAfter = Get-RemoteManifestFingerprint -Manifest $after

            if ($hashBefore -ne $hashAfter) {
                continue
            }

            return [pscustomobject]@{
                Files                    = $files
                RemoteManifestHashBefore = $hashBefore
                RemoteManifestHashAfter  = $hashAfter
                AttemptCount             = $attempt
                StagingRoot              = $stagingRoot
            }
        }
        catch {
            if (Test-RemoteSnapshotRetryableException -Exception $_.Exception) {
                continue
            }

            Clear-RemoteSnapshotTemp -WorkspaceRoot $WorkspaceRoot
            throw
        }
    }

    Clear-RemoteSnapshotTemp -WorkspaceRoot $WorkspaceRoot
    throw [System.InvalidOperationException]::new(
        $script:RemoteSnapshotIdleMessage
    )
}

