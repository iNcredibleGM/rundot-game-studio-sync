# Exact-byte SHA-256, local kind, and text diagnostics.
# Do not require Pester.

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "lib\Hashing.ps1")

$emptySha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
$abcSha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

function Get-IndependentFileSha256Hex {
    param([string]$LiteralPath)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::Open(
            $LiteralPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        try {
            $hash = $sha.ComputeHash($stream)
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $sha.Dispose()
    }

    return [System.BitConverter]::ToString($hash).Replace("-", "").ToLowerInvariant()
}

$testRoot = Join-Path $env:TEMP ("rundot-hashing-tests-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    # --------------------------------------------------------------------------
    # Zero-byte and known vectors
    # --------------------------------------------------------------------------

    $emptyPath = Join-Path $testRoot "empty.bin"
    [System.IO.File]::WriteAllBytes($emptyPath, [byte[]]@())

    Assert-Equal `
        $emptySha256 `
        (Get-FileSha256Hex -LiteralPath $emptyPath) `
        "a zero-byte file should hash as the empty SHA-256"

    $emptyIdentity = Get-LocalFileIdentity -LiteralPath $emptyPath
    Assert-Equal $emptySha256 $emptyIdentity.Sha256 "zero-byte identity hash should match empty SHA-256"
    Assert-Equal 0 $emptyIdentity.Size "zero-byte identity size should be 0"
    Assert-Equal "utf8" $emptyIdentity.LocalDetectedKind "a zero-byte file should classify as utf8"
    Assert-Equal "none" $emptyIdentity.LineEnding "a zero-byte file should have lineEnding none"
    Assert-Equal $false $emptyIdentity.HasBom "a zero-byte file should not have a BOM"

    $abcPath = Join-Path $testRoot "abc.txt"
    [System.IO.File]::WriteAllBytes($abcPath, [byte[]](0x61, 0x62, 0x63))
    Assert-Equal `
        $abcSha256 `
        (Get-FileSha256Hex -LiteralPath $abcPath) `
        "bytes 61 62 63 should match the published SHA-256 of abc"


    # --------------------------------------------------------------------------
    # No normalization of newlines, BOM, or JSON
    # --------------------------------------------------------------------------

    $lfPath = Join-Path $testRoot "lf.txt"
    $crlfPath = Join-Path $testRoot "crlf.txt"
    [System.IO.File]::WriteAllBytes($lfPath, [byte[]](0x61, 0x0A))
    [System.IO.File]::WriteAllBytes($crlfPath, [byte[]](0x61, 0x0D, 0x0A))

    $lfHash = Get-FileSha256Hex -LiteralPath $lfPath
    $crlfHash = Get-FileSha256Hex -LiteralPath $crlfPath
    Assert-True ($lfHash -ne $crlfHash) "LF and CRLF files with the same letters must not share a hash"

    $noBomPath = Join-Path $testRoot "nobom.txt"
    $bomPath = Join-Path $testRoot "bom.txt"
    [System.IO.File]::WriteAllBytes($noBomPath, [byte[]](0x61))
    [System.IO.File]::WriteAllBytes($bomPath, [byte[]](0xEF, 0xBB, 0xBF, 0x61))
    Assert-True `
        ((Get-FileSha256Hex -LiteralPath $noBomPath) -ne (Get-FileSha256Hex -LiteralPath $bomPath)) `
        "a UTF-8 BOM must change the hash"

    $jsonCompactPath = Join-Path $testRoot "compact.json"
    $jsonSpacedPath = Join-Path $testRoot "spaced.json"
    [System.IO.File]::WriteAllBytes(
        $jsonCompactPath,
        [System.Text.Encoding]::UTF8.GetBytes('{"a":1}')
    )
    [System.IO.File]::WriteAllBytes(
        $jsonSpacedPath,
        [System.Text.Encoding]::UTF8.GetBytes('{"a": 1}')
    )
    Assert-True `
        ((Get-FileSha256Hex -LiteralPath $jsonCompactPath) -ne (Get-FileSha256Hex -LiteralPath $jsonSpacedPath)) `
        "JSON whitespace must not be normalized before hashing"


    # --------------------------------------------------------------------------
    # Kind detection
    # --------------------------------------------------------------------------

    $utf8AccentPath = Join-Path $testRoot "accent.txt"
    [System.IO.File]::WriteAllBytes($utf8AccentPath, [byte[]](0xC3, 0xA9))
    Assert-Equal `
        "utf8" `
        (Get-LocalFileIdentity -LiteralPath $utf8AccentPath).LocalDetectedKind `
        "UTF-8 e-acute bytes should classify as utf8"

    $nulPath = Join-Path $testRoot "nul.bin"
    [System.IO.File]::WriteAllBytes($nulPath, [byte[]](0x61, 0x00, 0x62))
    $nulIdentity = Get-LocalFileIdentity -LiteralPath $nulPath
    Assert-Equal "binary" $nulIdentity.LocalDetectedKind "an embedded NUL should classify as binary"
    Assert-Null $nulIdentity.LineEnding "binary files should omit lineEnding"
    Assert-Null $nulIdentity.HasBom "binary files should omit hasBom"

    $utf16Path = Join-Path $testRoot "utf16.bin"
    [System.IO.File]::WriteAllBytes($utf16Path, [byte[]](0xFF, 0xFE, 0x61, 0x00))
    Assert-Equal `
        "binary" `
        (Get-LocalFileIdentity -LiteralPath $utf16Path).LocalDetectedKind `
        "a UTF-16 BOM / invalid UTF-8 should classify as binary"

    $invalidUtf8Path = Join-Path $testRoot "invalid-utf8.bin"
    [System.IO.File]::WriteAllBytes($invalidUtf8Path, [byte[]](0xFF))
    Assert-Equal `
        "binary" `
        (Get-LocalFileIdentity -LiteralPath $invalidUtf8Path).LocalDetectedKind `
        "invalid UTF-8 should classify as binary"


    # --------------------------------------------------------------------------
    # Line endings and BOM diagnostics
    # --------------------------------------------------------------------------

    Assert-Equal "lf" (Get-LocalFileIdentity -LiteralPath $lfPath).LineEnding "LF-only text should report lf"
    Assert-Equal "crlf" (Get-LocalFileIdentity -LiteralPath $crlfPath).LineEnding "CRLF-only text should report crlf"
    Assert-Equal $false (Get-LocalFileIdentity -LiteralPath $lfPath).HasBom "LF text without EF BB BF should not have a BOM"

    $nonePath = Join-Path $testRoot "none.txt"
    [System.IO.File]::WriteAllBytes($nonePath, [byte[]](0x61, 0x62, 0x63))
    Assert-Equal "none" (Get-LocalFileIdentity -LiteralPath $nonePath).LineEnding "text without CR or LF should report none"

    $mixedPath = Join-Path $testRoot "mixed.txt"
    [System.IO.File]::WriteAllBytes($mixedPath, [byte[]](0x61, 0x0A, 0x62, 0x0D, 0x0A))
    Assert-Equal "mixed" (Get-LocalFileIdentity -LiteralPath $mixedPath).LineEnding "mixed LF and CRLF should report mixed"

    $loneCrPath = Join-Path $testRoot "lone-cr.txt"
    [System.IO.File]::WriteAllBytes($loneCrPath, [byte[]](0x61, 0x0D, 0x62))
    Assert-Equal "mixed" (Get-LocalFileIdentity -LiteralPath $loneCrPath).LineEnding "lone CR should report mixed"

    $bomCrlfPath = Join-Path $testRoot "bom-crlf.txt"
    [System.IO.File]::WriteAllBytes($bomCrlfPath, [byte[]](0xEF, 0xBB, 0xBF, 0x61, 0x0D, 0x0A))
    $bomCrlfIdentity = Get-LocalFileIdentity -LiteralPath $bomCrlfPath
    Assert-Equal "utf8" $bomCrlfIdentity.LocalDetectedKind "BOM + CRLF text should still be utf8"
    Assert-Equal $true $bomCrlfIdentity.HasBom "EF BB BF should set hasBom"
    Assert-Equal "crlf" $bomCrlfIdentity.LineEnding "BOM is not part of the line-ending classification"


    # --------------------------------------------------------------------------
    # Remote kind mapping and kind-change helper
    # --------------------------------------------------------------------------

    Assert-Equal "utf8" (ConvertTo-RemoteKind -Encoding "utf8") "API encoding utf8 should map to remoteKind utf8"
    Assert-Equal "binary" (ConvertTo-RemoteKind -Encoding "base64") "API encoding base64 should map to remoteKind binary"
    Assert-Null (ConvertTo-RemoteKind -Encoding "unknown") "unknown API encoding should not invent a remoteKind"
    Assert-Null (ConvertTo-RemoteKind -Encoding $null) "missing API encoding should not invent a remoteKind"

    Assert-True `
        (Test-UnsupportedKindChange -LocalKind "utf8" -RemoteKind "binary") `
        "utf8 vs binary should be an unsupported kind change"
    Assert-True `
        (Test-UnsupportedKindChange -LocalKind "binary" -RemoteKind "utf8") `
        "binary vs utf8 should be an unsupported kind change"
    Assert-True `
        (-not (Test-UnsupportedKindChange -LocalKind "utf8" -RemoteKind "utf8")) `
        "matching utf8 kinds are not a kind change"
    Assert-True `
        (-not (Test-UnsupportedKindChange -LocalKind "utf8" -RemoteKind $null)) `
        "a missing remoteKind is not a kind change"


    # --------------------------------------------------------------------------
    # Large binary without loading the production hasher as a string
    # --------------------------------------------------------------------------

    function Write-RepeatingBytes {
        param(
            [string]$LiteralPath,
            [int]$Length,
            [scriptblock]$FillBuffer
        )

        $buffer = New-Object byte[] 65536
        & $FillBuffer $buffer
        $out = [System.IO.File]::Open(
            $LiteralPath,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        try {
            $remaining = $Length
            while ($remaining -gt 0) {
                $chunk = $buffer.Length
                if ($chunk -gt $remaining) {
                    $chunk = $remaining
                }
                $out.Write($buffer, 0, $chunk)
                $remaining -= $chunk
            }
        }
        finally {
            $out.Dispose()
        }
    }

    $largePath = Join-Path $testRoot "large.bin"
    $largeSize = 16 * 1024 * 1024
    Write-RepeatingBytes `
        -LiteralPath $largePath `
        -Length $largeSize `
        -FillBuffer {
            param($Buffer)
            for ($i = 0; $i -lt $Buffer.Length; $i++) {
                $Buffer[$i] = 0x61
            }
        }

    $expectedLargeHash = Get-IndependentFileSha256Hex -LiteralPath $largePath
    $largeIdentity = Get-LocalFileIdentity -LiteralPath $largePath
    Assert-Equal `
        $expectedLargeHash `
        (Get-FileSha256Hex -LiteralPath $largePath) `
        "a 16 MiB file should hash via the stream helper, matching SHA256.Create() on a FileStream"
    Assert-Equal `
        "utf8" `
        $largeIdentity.LocalDetectedKind `
        "16 MiB of ASCII 'a' should classify as utf8 without loading a PowerShell string in Hashing.ps1"
    Assert-Equal $largeSize $largeIdentity.Size "16 MiB identity size should match byte length"

    $largeBinaryPath = Join-Path $testRoot "large-binary.bin"
    Write-RepeatingBytes `
        -LiteralPath $largeBinaryPath `
        -Length $largeSize `
        -FillBuffer {
            param($Buffer)
            for ($i = 0; $i -lt $Buffer.Length; $i++) {
                $Buffer[$i] = [byte]($i % 256)
            }
        }
    Assert-Equal `
        "binary" `
        (Get-LocalFileIdentity -LiteralPath $largeBinaryPath).LocalDetectedKind `
        "a 16 MiB file with NULs and non-UTF-8 bytes should classify as binary"
    Assert-Equal `
        (Get-IndependentFileSha256Hex -LiteralPath $largeBinaryPath) `
        (Get-FileSha256Hex -LiteralPath $largeBinaryPath) `
        "a 16 MiB mixed-byte binary should hash without ReadAllBytes in Hashing.ps1"


    # --------------------------------------------------------------------------
    # Sharing violation aborts instead of omitting the file
    # --------------------------------------------------------------------------

    $lockedPath = Join-Path $testRoot "locked.bin"
    [System.IO.File]::WriteAllBytes($lockedPath, [byte[]](0x61))
    $lockStream = [System.IO.File]::Open(
        $lockedPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    try {
        Assert-Throws {
            Get-FileSha256Hex -LiteralPath $lockedPath
        } "an exclusive lock should abort hashing after bounded retries"
        Assert-Throws {
            Get-LocalFileIdentity -LiteralPath $lockedPath
        } "an exclusive lock should abort identity collection after bounded retries"
    }
    finally {
        $lockStream.Dispose()
    }
}
finally {
    if (Test-Path $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}


# --------------------------------------------------------------------------
# Production hasher must not load whole files into strings or byte[]
# --------------------------------------------------------------------------

$hashingSource = [System.IO.File]::ReadAllText((Join-Path $repoRoot "lib\Hashing.ps1"))
Assert-True `
    ($hashingSource -notmatch '(?i)\bGet-Content\b') `
    "Hashing.ps1 must not call Get-Content"
Assert-True `
    ($hashingSource -notmatch '(?i)ReadAllText') `
    "Hashing.ps1 must not call ReadAllText"
Assert-True `
    ($hashingSource -notmatch '(?i)ReadAllBytes') `
    "Hashing.ps1 must not call ReadAllBytes"
