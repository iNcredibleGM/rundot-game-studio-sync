# Remote manifest fingerprint, list validation, and file-payload decode.
# Do not require Pester. Network is not used.

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "lib\Paths.ps1")
. (Join-Path $repoRoot "lib\Hashing.ps1")
. (Join-Path $repoRoot "lib\Workspace.ps1")
. (Join-Path $repoRoot "lib\RemoteApi.ps1")
. (Join-Path $repoRoot "lib\Snapshot.ps1")

function New-TestFileEntry {
    param([hashtable]$Properties)

    $entry = New-Object PSObject
    foreach ($key in $Properties.Keys) {
        $entry | Add-Member -NotePropertyName $key -NotePropertyValue $Properties[$key]
    }

    return $entry
}

function New-TestRemoteManifest {
    param([object[]]$Files)

    return [pscustomobject]@{
        files = $Files
    }
}

function Assert-FingerprintHex {
    param(
        $Value,
        [string]$Message
    )

    Assert-True (
        ($null -ne $Value) -and
        ([string]$Value -match '^[0-9a-f]{64}$')
    ) $Message
}


# --------------------------------------------------------------------------
# Fingerprint: same identity, different JSON spelling
# --------------------------------------------------------------------------

$stableFiles = @(
    (New-TestFileEntry @{
        path     = 'src/a.ts'
        type     = 'file'
        size     = 3
        encoding = 'utf8'
    }),
    (New-TestFileEntry @{
        path     = 'public/logo.png'
        type     = 'file'
        size     = 16
        encoding = 'base64'
        kind     = 'binary'
    })
)

$hashStable = Get-RemoteManifestFingerprint -Manifest (New-TestRemoteManifest -Files $stableFiles)
Assert-FingerprintHex $hashStable "a valid manifest fingerprint should be 64 lowercase hex chars"

$hashSameAgain = Get-RemoteManifestFingerprint -Manifest (New-TestRemoteManifest -Files $stableFiles)
Assert-FingerprintHex $hashSameAgain "a repeated fingerprint call should still return hex"
Assert-Equal `
    $hashStable `
    $hashSameAgain `
    "the same path set, size, and encoding must produce the same fingerprint"

$leadingSlashFiles = @(
    (New-TestFileEntry @{
        path     = '/src/a.ts'
        type     = 'file'
        size     = 3
        encoding = 'utf8'
    }),
    (New-TestFileEntry @{
        path     = '/public/logo.png'
        type     = 'file'
        size     = 16
        encoding = 'base64'
        kind     = 'binary'
    })
)
$hashLeadingSlash = Get-RemoteManifestFingerprint -Manifest (New-TestRemoteManifest -Files $leadingSlashFiles)
Assert-FingerprintHex $hashLeadingSlash "a leading-slash manifest should still fingerprint"
Assert-Equal `
    $hashStable `
    $hashLeadingSlash `
    "a leading slash from the API must not change the fingerprint"

$reorderedFiles = @(
    $stableFiles[1],
    $stableFiles[0]
)
$hashReordered = Get-RemoteManifestFingerprint -Manifest (New-TestRemoteManifest -Files $reorderedFiles)
Assert-FingerprintHex $hashReordered "a reordered file list should still fingerprint"
Assert-Equal `
    $hashStable `
    $hashReordered `
    "file-array order must not change the fingerprint"

$prettyJson = @'
{
  "files": [
    {
      "path": "src/a.ts",
      "type": "file",
      "size": 3,
      "encoding": "utf8"
    },
    {
      "path": "public/logo.png",
      "type": "file",
      "size": 16,
      "encoding": "base64",
      "kind": "binary"
    }
  ]
}
'@
$compactJson = '{"files":[{"path":"src/a.ts","type":"file","size":3,"encoding":"utf8"},{"path":"public/logo.png","type":"file","size":16,"encoding":"base64","kind":"binary"}]}'
$hashPretty = Get-RemoteManifestFingerprint -Manifest (ConvertFrom-RemoteJson -Text $prettyJson)
$hashCompact = Get-RemoteManifestFingerprint -Manifest (ConvertFrom-RemoteJson -Text $compactJson)
Assert-FingerprintHex $hashPretty "pretty-printed JSON should still fingerprint"
Assert-FingerprintHex $hashCompact "compact JSON should still fingerprint"
Assert-Equal `
    $hashStable `
    $hashPretty `
    "pretty-printed JSON whitespace must not change the fingerprint"
Assert-Equal `
    $hashPretty `
    $hashCompact `
    "compact JSON whitespace must not change the fingerprint"

$withDirectory = New-TestRemoteManifest -Files @(
    $stableFiles[0],
    $stableFiles[1],
    (New-TestFileEntry @{
        path = 'src'
        type = 'directory'
    })
)
$hashWithDirectory = Get-RemoteManifestFingerprint -Manifest $withDirectory
Assert-FingerprintHex $hashWithDirectory "a list that includes a directory entry should still fingerprint"
Assert-Equal `
    $hashStable `
    $hashWithDirectory `
    "directory entries must not be part of the fingerprint"

$emptyHash = Get-RemoteManifestFingerprint -Manifest (New-TestRemoteManifest -Files @())
Assert-FingerprintHex $emptyHash "an empty file list should still fingerprint"
Assert-True `
    ($emptyHash -ne $hashStable) `
    "an empty file list must not share a non-empty fingerprint"


# --------------------------------------------------------------------------
# Fingerprint: add / remove / size / encoding / identity extras
# --------------------------------------------------------------------------

$added = New-TestRemoteManifest -Files @(
    $stableFiles[0],
    $stableFiles[1],
    (New-TestFileEntry @{
        path     = 'src/b.ts'
        type     = 'file'
        size     = 1
        encoding = 'utf8'
    })
)
Assert-True `
    ((Get-RemoteManifestFingerprint -Manifest $added) -ne $hashStable) `
    "adding a path must change the fingerprint"

$removed = New-TestRemoteManifest -Files @($stableFiles[0])
Assert-True `
    ((Get-RemoteManifestFingerprint -Manifest $removed) -ne $hashStable) `
    "removing a path must change the fingerprint"

$sizeChanged = New-TestRemoteManifest -Files @(
    (New-TestFileEntry @{
        path     = 'src/a.ts'
        type     = 'file'
        size     = 99
        encoding = 'utf8'
    }),
    $stableFiles[1]
)
Assert-True `
    ((Get-RemoteManifestFingerprint -Manifest $sizeChanged) -ne $hashStable) `
    "a size change must change the fingerprint"

$encodingChanged = New-TestRemoteManifest -Files @(
    (New-TestFileEntry @{
        path     = 'src/a.ts'
        type     = 'file'
        size     = 3
        encoding = 'base64'
    }),
    $stableFiles[1]
)
Assert-True `
    ((Get-RemoteManifestFingerprint -Manifest $encodingChanged) -ne $hashStable) `
    "an encoding change must change the fingerprint"

$kindChanged = New-TestRemoteManifest -Files @(
    $stableFiles[0],
    (New-TestFileEntry @{
        path     = 'public/logo.png'
        type     = 'file'
        size     = 16
        encoding = 'base64'
        kind     = 'utf8'
    })
)
Assert-True `
    ((Get-RemoteManifestFingerprint -Manifest $kindChanged) -ne $hashStable) `
    "a kind change must change the fingerprint"

$withEtag = New-TestRemoteManifest -Files @(
    (New-TestFileEntry @{
        path     = 'src/a.ts'
        type     = 'file'
        size     = 3
        encoding = 'utf8'
        etag     = 'etag-1'
    }),
    $stableFiles[1]
)
$etagHash = Get-RemoteManifestFingerprint -Manifest $withEtag
Assert-True `
    ($etagHash -ne $hashStable) `
    "an etag identity extra must change the fingerprint"

$etagChanged = New-TestRemoteManifest -Files @(
    (New-TestFileEntry @{
        path     = 'src/a.ts'
        type     = 'file'
        size     = 3
        encoding = 'utf8'
        etag     = 'etag-2'
    }),
    $stableFiles[1]
)
Assert-True `
    ((Get-RemoteManifestFingerprint -Manifest $etagChanged) -ne $etagHash) `
    "changing etag must change the fingerprint"

$idChanged = New-TestRemoteManifest -Files @(
    (New-TestFileEntry @{
        path     = 'src/a.ts'
        type     = 'file'
        size     = 3
        encoding = 'utf8'
        id       = 'id-1'
    }),
    $stableFiles[1]
)
Assert-True `
    ((Get-RemoteManifestFingerprint -Manifest $idChanged) -ne $hashStable) `
    "an id identity extra must change the fingerprint"


# --------------------------------------------------------------------------
# Validation: malformed lists must not be fingerprintable
# --------------------------------------------------------------------------

Assert-Throws {
    Assert-RemoteManifestValid -Manifest $null
} "a missing manifest must not validate"

Assert-Throws {
    Assert-RemoteManifestValid -Manifest ([pscustomobject]@{ projectId = 'x' })
} "a payload without files must not validate"

Assert-Throws {
    Assert-RemoteManifestValid -Manifest (New-TestRemoteManifest -Files @(
        (New-TestFileEntry @{
            type     = 'file'
            size     = 1
            encoding = 'utf8'
        })
    ))
} "a file entry without a path must not validate"

Assert-Throws {
    Assert-RemoteManifestValid -Manifest (New-TestRemoteManifest -Files @(
        (New-TestFileEntry @{
            path     = ''
            type     = 'file'
            size     = 1
            encoding = 'utf8'
        })
    ))
} "an empty path must not validate"

Assert-Throws {
    Assert-RemoteManifestValid -Manifest (New-TestRemoteManifest -Files @(
        (New-TestFileEntry @{
            path     = 'src/a.ts'
            type     = 'file'
            size     = -1
            encoding = 'utf8'
        })
    ))
} "a negative size must not validate"

Assert-Throws {
    Assert-RemoteManifestValid -Manifest (New-TestRemoteManifest -Files @(
        (New-TestFileEntry @{
            path = 'src/a.ts'
            type = 'file'
            size = 1
        }),
        (New-TestFileEntry @{
            path = 'src/a.ts'
            type = 'file'
            size = 1
        })
    ))
} "two identical paths must abort immediately"

Assert-Throws {
    Assert-RemoteManifestValid -Manifest (New-TestRemoteManifest -Files @(
        (New-TestFileEntry @{
            path = '/foo.ts'
            type = 'file'
            size = 1
        }),
        (New-TestFileEntry @{
            path = 'foo.ts'
            type = 'file'
            size = 1
        })
    ))
} "/foo.ts and foo.ts are duplicate canonical paths and must abort immediately"

Assert-Throws {
    Get-RemoteManifestFingerprint -Manifest (New-TestRemoteManifest -Files @(
        (New-TestFileEntry @{
            path = 'src/a.ts'
            type = 'file'
            size = 1
        }),
        (New-TestFileEntry @{
            path = 'src/a.ts'
            type = 'file'
            size = 2
        })
    ))
} "a malformed duplicate list must not be hashed into a fingerprint"

Assert-RemoteManifestValid -Manifest (New-TestRemoteManifest -Files @())
Assert-RemoteManifestValid -Manifest (New-TestRemoteManifest -Files $stableFiles)


# --------------------------------------------------------------------------
# ConvertFrom-RemoteFileContent: decode exact bytes, never guess a codec
# --------------------------------------------------------------------------

$utf8NoBom = New-Object System.Text.UTF8Encoding $false

$hiBytes = ConvertFrom-RemoteFileContent -Response ([pscustomobject]@{
    encoding = 'utf8'
    content  = 'hi'
})
Assert-Equal `
    $utf8NoBom.GetBytes('hi') `
    $hiBytes `
    "utf8 content should decode to the same UTF-8 bytes the exporter writes"

$crlfBytes = ConvertFrom-RemoteFileContent -Response ([pscustomobject]@{
    encoding = 'utf8'
    content  = "a`r`n"
})
Assert-Equal `
    ([byte[]](0x61, 0x0D, 0x0A)) `
    $crlfBytes `
    "utf8 decode must keep CRLF instead of normalizing newlines"

$base64Bytes = ConvertFrom-RemoteFileContent -Response ([pscustomobject]@{
    encoding = 'base64'
    content  = 'QQ=='
})
Assert-Equal `
    ([byte[]](0x41)) `
    $base64Bytes `
    "base64 QQ== should decode to 0x41"

Assert-Throws {
    ConvertFrom-RemoteFileContent -Response ([pscustomobject]@{
        encoding = 'base64'
        content  = '%%%not-base64%%%'
    })
} "malformed base64 must not decode"

Assert-Throws {
    ConvertFrom-RemoteFileContent -Response ([pscustomobject]@{
        encoding = 'latin1'
        content  = 'hi'
    })
} "unknown encoding must abort instead of inventing a codec"

Assert-Throws {
    ConvertFrom-RemoteFileContent -Response ([pscustomobject]@{
        encoding = 'utf8'
    })
} "utf8 payloads without content must not decode"


# --------------------------------------------------------------------------
# Torn-read loop: injected fake remote (Get-StableRemoteSnapshot)
# --------------------------------------------------------------------------

$script:ListCallCount = 0
$script:FileCallCount = 0
$script:CapturedListAuth = $null
$script:CapturedFileAuth = $null
$script:ListQueue = @()
$script:FilePayloads = @{}
$script:FileErrors = @{}

function Reset-FakeRemote {
    param(
        [object[]]$Lists,
        [hashtable]$Files,
        [hashtable]$FileErrors
    )

    $script:ListCallCount = 0
    $script:FileCallCount = 0
    $script:CapturedListAuth = $null
    $script:CapturedFileAuth = $null
    $script:ListQueue = @($Lists)
    $script:FilePayloads = @{}
    if ($Files) {
        $script:FilePayloads = $Files
    }

    $script:FileErrors = @{}
    if ($FileErrors) {
        $script:FileErrors = $FileErrors
    }
}

function Get-RemoteProjectFileList {
    param(
        [string]$StudioOrigin,
        [string]$ProjectId,
        [hashtable]$Headers
    )

    $script:ListCallCount++
    $script:CapturedListAuth = $Headers.Authorization
    $index = $script:ListCallCount - 1
    if ($index -ge $script:ListQueue.Count) {
        return $script:ListQueue[$script:ListQueue.Count - 1]
    }

    return $script:ListQueue[$index]
}

function Get-RemoteProjectFile {
    param(
        [string]$StudioOrigin,
        [string]$ProjectId,
        [string]$Path,
        [hashtable]$Headers
    )

    $script:FileCallCount++
    $script:CapturedFileAuth = $Headers.Authorization
    $lookup = $Path
    if ($lookup.StartsWith('/')) {
        $lookup = $lookup.Substring(1)
    }

    if ($script:FileErrors.ContainsKey($Path)) {
        throw $script:FileErrors[$Path]
    }

    if ($script:FileErrors.ContainsKey($lookup)) {
        throw $script:FileErrors[$lookup]
    }

    if ($script:FilePayloads.ContainsKey($Path)) {
        return $script:FilePayloads[$Path]
    }

    if ($script:FilePayloads.ContainsKey($lookup)) {
        return $script:FilePayloads[$lookup]
    }

    throw [System.InvalidOperationException]::new("No fake payload for '$Path'.")
}

function Invoke-TestSnapshot {
    param([string]$WorkspaceRoot)

    return Get-StableRemoteSnapshot `
        -WorkspaceRoot $WorkspaceRoot `
        -StudioOrigin 'https://example.test' `
        -ProjectId 'proj-test-1' `
        -Headers @{
            Authorization = 'Bearer test-token'
            Accept        = '*/*'
        }
}

function Assert-IdleAbortMessage {
    param($Exception)

    $text = [string]$Exception.Message
    Assert-True (
        $text -match [regex]::Escape('The remote project changed while being read. No plan was generated.')
    ) "unstable abort must use the idle message"
    Assert-True (
        $text -match [regex]::Escape('Try again when the project is idle.')
    ) "unstable abort must tell the user to retry when idle"
    Assert-True (
        $text -notmatch '(?i)deleted'
    ) "a torn read must not be described as a remote deletion"
}

function Assert-NotIdleMessage {
    param(
        $Exception,
        [string]$Message
    )

    $text = [string]$Exception.Message
    Assert-True (
        $text -notmatch [regex]::Escape('The remote project changed while being read')
    ) $Message
}

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
$hiEntry = New-TestFileEntry @{
    path     = 'src/a.ts'
    type     = 'file'
    size     = 2
    encoding = 'utf8'
}
$hiManifest = New-TestRemoteManifest -Files @($hiEntry)
$logoEntry = New-TestFileEntry @{
    path     = 'public/logo.png'
    type     = 'file'
    size     = 1
    encoding = 'base64'
}
$addedManifest = New-TestRemoteManifest -Files @($hiEntry, $logoEntry)
$removedManifest = New-TestRemoteManifest -Files @()
$sizeChangedManifest = New-TestRemoteManifest -Files @(
    (New-TestFileEntry @{
        path     = 'src/a.ts'
        type     = 'file'
        size     = 99
        encoding = 'utf8'
    })
)
$encodingChangedManifest = New-TestRemoteManifest -Files @(
    (New-TestFileEntry @{
        path     = 'src/a.ts'
        type     = 'file'
        size     = 2
        encoding = 'base64'
    })
)
$duplicateManifest = New-TestRemoteManifest -Files @(
    (New-TestFileEntry @{
        path = '/foo.ts'
        type = 'file'
        size = 1
    }),
    (New-TestFileEntry @{
        path = 'foo.ts'
        type = 'file'
        size = 1
    })
)
$hiPayload = [pscustomobject]@{
    encoding = 'utf8'
    content  = 'hi'
}
$logoPayload = [pscustomobject]@{
    encoding = 'base64'
    content  = 'QQ=='
}

$tornRoot = Join-Path $env:TEMP ("rundot-snapshot-torn-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tornRoot | Out-Null

try {
    $workspace = Join-Path $tornRoot "workspace"
    New-Item -ItemType Directory -Path $workspace | Out-Null

    # 1. Stable Before == After
    Reset-FakeRemote `
        -Lists @($hiManifest, $hiManifest) `
        -Files @{ 'src/a.ts' = $hiPayload }
    $stable = Invoke-TestSnapshot -WorkspaceRoot $workspace
    Assert-True ($null -ne $stable) "a stable remote capture should return a snapshot"
    Assert-True (
        $stable.Files -is [System.Collections.IDictionary]
    ) "snapshot Files must be a dictionary, not omitted"
    $hasStagedFile = $false
    if ($stable.Files -is [System.Collections.IDictionary]) {
        $hasStagedFile = [bool]$stable.Files.Contains('src/a.ts')
    }
    Assert-True $hasStagedFile "downloaded files should be keyed by canonical path"
    Assert-FingerprintHex $stable.RemoteManifestHashBefore "remoteManifestHashBefore should be stored"
    Assert-FingerprintHex $stable.RemoteManifestHashAfter "remoteManifestHashAfter should be stored"
    Assert-Equal `
        $stable.RemoteManifestHashBefore `
        $stable.RemoteManifestHashAfter `
        "a valid snapshot should have equivalent before/after fingerprints"
    Assert-Equal 1 $stable.AttemptCount "a stable capture should succeed on the first attempt"
    Assert-True (
        $script:CapturedListAuth -eq 'Bearer test-token' -and
        $script:CapturedFileAuth -eq 'Bearer test-token'
    ) "snapshot GETs should pass Authorization without tests printing it"
    Assert-True (
        -not [string]::IsNullOrEmpty($stable.StagingRoot)
    ) "a valid snapshot should keep staging files"
    $stagedHi = $null
    if (-not [string]::IsNullOrEmpty($stable.StagingRoot)) {
        $stagedHi = Join-Path $stable.StagingRoot "src\a.ts"
    }
    Assert-True (
        ($null -ne $stagedHi) -and (Test-Path -LiteralPath $stagedHi)
    ) "utf8 content should be written under .rundot-sync/temp"
    if (($null -ne $stagedHi) -and (Test-Path -LiteralPath $stagedHi)) {
        Assert-Equal `
            $utf8NoBom.GetBytes('hi') `
            ([System.IO.File]::ReadAllBytes($stagedHi)) `
            "staging bytes must match decoded utf8 content"
        $identitySha = $null
        if ($hasStagedFile) {
            $identitySha = $stable.Files['src/a.ts'].Sha256
        }
        Assert-Equal `
            (Get-FileSha256Hex -LiteralPath $stagedHi) `
            $identitySha `
            "snapshot SHA-256 must come from decoded staging bytes"
    }
    Assert-Null `
        (Read-BaseManifest -WorkspaceRoot $workspace) `
        "a remote snapshot must not write BASE"

    # 10. Empty files array, Before == After
    $emptyWorkspace = Join-Path $tornRoot "empty"
    New-Item -ItemType Directory -Path $emptyWorkspace | Out-Null
    $emptyManifest = New-TestRemoteManifest -Files @()
    Reset-FakeRemote -Lists @($emptyManifest, $emptyManifest) -Files @{}
    $emptySnapshot = Invoke-TestSnapshot -WorkspaceRoot $emptyWorkspace
    Assert-True ($null -ne $emptySnapshot) "an empty project should return a snapshot"
    Assert-True (
        $emptySnapshot.Files -is [System.Collections.IDictionary]
    ) "an empty snapshot still has a Files map"
    $emptyCount = -1
    if ($emptySnapshot.Files -is [System.Collections.IDictionary]) {
        $emptyCount = $emptySnapshot.Files.Count
    }
    Assert-Equal 0 $emptyCount "an empty remote project has no file entries"
    Assert-Equal `
        $emptySnapshot.RemoteManifestHashBefore `
        $emptySnapshot.RemoteManifestHashAfter `
        "empty Before and After fingerprints should match"

    # 2. Add during snapshot then stabilize
    Reset-FakeRemote `
        -Lists @($hiManifest, $addedManifest, $hiManifest, $hiManifest) `
        -Files @{
            'src/a.ts'         = $hiPayload
            'public/logo.png'  = $logoPayload
        }
    $afterAdd = Invoke-TestSnapshot -WorkspaceRoot $workspace
    Assert-True ($null -ne $afterAdd) "a retry after an added path should succeed"
    Assert-True (
        $afterAdd.AttemptCount -ge 2
    ) "an add during snapshot must retry before succeeding"

    # 3. Remove / size / encoding change during snapshot
    Reset-FakeRemote `
        -Lists @($hiManifest, $removedManifest, $hiManifest, $hiManifest) `
        -Files @{ 'src/a.ts' = $hiPayload }
    $afterRemove = Invoke-TestSnapshot -WorkspaceRoot $workspace
    Assert-True (
        $null -ne $afterRemove -and $afterRemove.AttemptCount -ge 2
    ) "a remove during snapshot must retry"

    Reset-FakeRemote `
        -Lists @($hiManifest, $sizeChangedManifest, $hiManifest, $hiManifest) `
        -Files @{ 'src/a.ts' = $hiPayload }
    $afterSize = Invoke-TestSnapshot -WorkspaceRoot $workspace
    Assert-True (
        $null -ne $afterSize -and $afterSize.AttemptCount -ge 2
    ) "a size change during snapshot must retry"

    Reset-FakeRemote `
        -Lists @($hiManifest, $encodingChangedManifest, $hiManifest, $hiManifest) `
        -Files @{ 'src/a.ts' = $hiPayload }
    $afterEncoding = Invoke-TestSnapshot -WorkspaceRoot $workspace
    Assert-True (
        $null -ne $afterEncoding -and $afterEncoding.AttemptCount -ge 2
    ) "an encoding change during snapshot must retry"

    # 4. Three consecutive unstable snapshots
    Reset-FakeRemote `
        -Lists @(
            $hiManifest, $addedManifest,
            $hiManifest, $removedManifest,
            $hiManifest, $sizeChangedManifest
        ) `
        -Files @{
            'src/a.ts'        = $hiPayload
            'public/logo.png' = $logoPayload
        }
    $idleThrown = $null
    try {
        Invoke-TestSnapshot -WorkspaceRoot $workspace | Out-Null
        Assert-True $false "three unstable snapshots must abort"
    }
    catch {
        $idleThrown = $_.Exception
    }
    Assert-True ($null -ne $idleThrown) "three unstable snapshots must throw"
    if ($null -ne $idleThrown) {
        Assert-IdleAbortMessage -Exception $idleThrown
    }
    Assert-Equal 6 $script:ListCallCount "three unstable attempts each GET Before and After"
    Assert-Null (Read-BaseManifest -WorkspaceRoot $workspace) "an aborted snapshot must not write BASE"
    $tempRoot = Join-Path $workspace ".rundot-sync\temp\remote-snapshot"
    $leftover = @()
    if (Test-Path -LiteralPath $tempRoot) {
        $leftover = @(Get-ChildItem -LiteralPath $tempRoot -Force)
    }
    Assert-Equal 0 $leftover.Count "failed attempts must discard staging so it cannot be promoted"

    # 5. 404 on GET /file is not remote deletion
    Reset-FakeRemote `
        -Lists @($hiManifest, $hiManifest, $hiManifest, $hiManifest, $hiManifest, $hiManifest) `
        -Files @{} `
        -FileErrors @{ 'src/a.ts' = (New-RemoteHttpException -StatusCode 404) }
    $notFoundThrown = $null
    try {
        Invoke-TestSnapshot -WorkspaceRoot $workspace | Out-Null
        Assert-True $false "three 404 snapshots must abort"
    }
    catch {
        $notFoundThrown = $_.Exception
    }
    Assert-True ($null -ne $notFoundThrown) "a listed path that 404s must abort after retries"
    if ($null -ne $notFoundThrown) {
        Assert-IdleAbortMessage -Exception $notFoundThrown
    }
    Assert-Equal 3 $script:FileCallCount "a 404 during download should retry up to three times"

    # 6. HTML login page aborts immediately
    Reset-FakeRemote -Lists @() -Files @{}
    function Get-RemoteProjectFileList {
        param(
            [string]$StudioOrigin,
            [string]$ProjectId,
            [hashtable]$Headers
        )

        $script:ListCallCount++
        return ConvertFrom-RemoteJson -Text '<!DOCTYPE html><html>login</html>' -What '/files'
    }
    $htmlThrown = $null
    try {
        Invoke-TestSnapshot -WorkspaceRoot $workspace | Out-Null
        Assert-True $false "HTML from /files must abort"
    }
    catch {
        $htmlThrown = $_.Exception
    }
    Assert-True ($null -ne $htmlThrown) "HTML from /files must throw"
    if ($null -ne $htmlThrown) {
        Assert-True (
            $htmlThrown.Message -match '(?i)html|unexpected'
        ) "HTML abort should mention unexpected HTML payload"
        Assert-NotIdleMessage `
            -Exception $htmlThrown `
            "HTML login is not a torn idle abort"
    }
    Assert-Equal 1 $script:ListCallCount "HTML from /files must not retry"
    Assert-Equal 0 $script:FileCallCount "HTML from /files must not download files"

    function Get-RemoteProjectFileList {
        param(
            [string]$StudioOrigin,
            [string]$ProjectId,
            [hashtable]$Headers
        )

        $script:ListCallCount++
        $script:CapturedListAuth = $Headers.Authorization
        $index = $script:ListCallCount - 1
        if ($index -ge $script:ListQueue.Count) {
            return $script:ListQueue[$script:ListQueue.Count - 1]
        }

        return $script:ListQueue[$index]
    }

    Reset-FakeRemote `
        -Lists @($hiManifest, $hiManifest) `
        -Files @{}
    function Get-RemoteProjectFile {
        param(
            [string]$StudioOrigin,
            [string]$ProjectId,
            [string]$Path,
            [hashtable]$Headers
        )

        $script:FileCallCount++
        return ConvertFrom-RemoteJson -Text '<html>login</html>' -What '/file'
    }
    $htmlFileThrown = $null
    try {
        Invoke-TestSnapshot -WorkspaceRoot $workspace | Out-Null
        Assert-True $false "HTML from /file must abort"
    }
    catch {
        $htmlFileThrown = $_.Exception
    }
    Assert-True ($null -ne $htmlFileThrown) "HTML from /file must throw"
    if ($null -ne $htmlFileThrown) {
        Assert-NotIdleMessage `
            -Exception $htmlFileThrown `
            "HTML from /file is not a torn idle abort"
    }
    Assert-Equal 1 $script:ListCallCount "HTML from /file must not GET ManifestAfter"
    Assert-Equal 1 $script:FileCallCount "HTML from /file aborts on the first file GET"

    function Get-RemoteProjectFile {
        param(
            [string]$StudioOrigin,
            [string]$ProjectId,
            [string]$Path,
            [hashtable]$Headers
        )

        $script:FileCallCount++
        $script:CapturedFileAuth = $Headers.Authorization
        $lookup = $Path
        if ($lookup.StartsWith('/')) {
            $lookup = $lookup.Substring(1)
        }

        if ($script:FileErrors.ContainsKey($Path)) {
            throw $script:FileErrors[$Path]
        }

        if ($script:FileErrors.ContainsKey($lookup)) {
            throw $script:FileErrors[$lookup]
        }

        if ($script:FilePayloads.ContainsKey($Path)) {
            return $script:FilePayloads[$Path]
        }

        if ($script:FilePayloads.ContainsKey($lookup)) {
            return $script:FilePayloads[$lookup]
        }

        throw [System.InvalidOperationException]::new("No fake payload for '$Path'.")
    }

    # 7. Bad base64 retries then aborts without a Files map
    Reset-FakeRemote `
        -Lists @($hiManifest, $hiManifest, $hiManifest, $hiManifest, $hiManifest, $hiManifest) `
        -Files @{
            'src/a.ts' = [pscustomobject]@{
                encoding = 'base64'
                content  = '%%%not-base64%%%'
            }
        }
    $badBase64 = $null
    try {
        $badBase64 = Invoke-TestSnapshot -WorkspaceRoot $workspace
        Assert-True $false "three malformed base64 payloads must abort"
    }
    catch {
        $badBase64 = $null
        Assert-True $true "malformed base64 should throw rather than return Files"
    }
    Assert-Null $badBase64 "malformed base64 must not return a snapshot Files map"
    Assert-Equal 3 $script:FileCallCount "malformed base64 should retry up to three times"

    # 8. Duplicate paths abort immediately; After must not run
    Reset-FakeRemote -Lists @($duplicateManifest, $hiManifest) -Files @{}
    $dupThrown = $null
    try {
        Invoke-TestSnapshot -WorkspaceRoot $workspace | Out-Null
        Assert-True $false "duplicate canonical paths must abort"
    }
    catch {
        $dupThrown = $_.Exception
    }
    Assert-True ($null -ne $dupThrown) "duplicate canonical paths must throw"
    if ($null -ne $dupThrown) {
        Assert-True (
            $dupThrown.Message -match '(?i)duplicate'
        ) "duplicate abort should mention duplicate paths"
        Assert-NotIdleMessage `
            -Exception $dupThrown `
            "duplicate paths are not a torn idle abort"
    }
    Assert-Equal 1 $script:ListCallCount "duplicate paths must not GET ManifestAfter"
    Assert-Equal 0 $script:FileCallCount "duplicate paths must not download files"

    # 9. Unknown encoding on /file aborts immediately
    Reset-FakeRemote `
        -Lists @($hiManifest, $hiManifest) `
        -Files @{
            'src/a.ts' = [pscustomobject]@{
                encoding = 'latin1'
                content  = 'hi'
            }
        }
    $unknownThrown = $null
    try {
        Invoke-TestSnapshot -WorkspaceRoot $workspace | Out-Null
        Assert-True $false "unknown encoding must abort immediately"
    }
    catch {
        $unknownThrown = $_.Exception
    }
    Assert-True ($null -ne $unknownThrown) "unknown encoding must throw"
    if ($null -ne $unknownThrown) {
        Assert-True (
            $unknownThrown.Message -match '(?i)encoding'
        ) "unknown encoding abort should mention encoding"
        Assert-NotIdleMessage `
            -Exception $unknownThrown `
            "unknown encoding is not a torn idle abort"
    }
    Assert-Equal 1 $script:ListCallCount "unknown encoding must not GET ManifestAfter"
    Assert-Equal 1 $script:FileCallCount "unknown encoding aborts on the first file GET"
}
finally {
    if (Test-Path -LiteralPath $tornRoot) {
        Remove-Item -LiteralPath $tornRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --------------------------------------------------------------------------
# Payload decode keeps byte[] for empty and single-byte content
#
# PowerShell unrolls a one-element array on return, so a zero-byte or one-byte
# payload would otherwise arrive as $null or a bare Byte. Hashing that raises
# "Multiple ambiguous overloads found for ComputeHash", which aborted a real
# delete of a 0-byte remote file. The decoded value must always be a byte[].
# --------------------------------------------------------------------------

foreach ($payloadCase in @(
    @{ Name = 'empty';   Content = '' },
    @{ Name = 'oneByte'; Content = 'A' },
    @{ Name = 'many';    Content = 'hello world' }
)) {
    $decoded = ConvertFrom-RemoteFileContent -Response ([pscustomobject]@{
        encoding = 'utf8'
        content  = $payloadCase.Content
    })

    Assert-True `
        ($decoded -is [byte[]]) `
        "a decoded $($payloadCase.Name) utf8 payload must stay a byte array"
    Assert-Equal `
        $payloadCase.Content.Length `
        $decoded.Length `
        "a decoded $($payloadCase.Name) payload must have the expected length"

    # The real failure mode: hashing the decoded bytes must not be ambiguous.
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($decoded)
    }
    finally {
        $sha.Dispose()
    }

    Assert-Equal 32 $hash.Length "a $($payloadCase.Name) payload must hash to 32 bytes"
}

$emptyDecoded = ConvertFrom-RemoteFileContent -Response ([pscustomobject]@{
    encoding = 'utf8'
    content  = ''
})
$emptySha = [System.Security.Cryptography.SHA256]::Create()
try {
    $emptyHash = $emptySha.ComputeHash($emptyDecoded)
}
finally {
    $emptySha.Dispose()
}
Assert-Equal `
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' `
    ([System.BitConverter]::ToString($emptyHash).Replace('-', '').ToLowerInvariant()) `
    "empty remote content must hash to the empty-string SHA-256"

$emptyBase64 = ConvertFrom-RemoteFileContent -Response ([pscustomobject]@{
    encoding = 'base64'
    content  = ''
})
Assert-True ($emptyBase64 -is [byte[]]) "a decoded empty base64 payload must stay a byte array"
Assert-Equal 0 $emptyBase64.Length "a decoded empty base64 payload must be zero bytes"

