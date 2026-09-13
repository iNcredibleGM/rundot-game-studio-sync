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
