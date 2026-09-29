# Streaming SHA-256 and local byte diagnostics for sync identity.
# Hash exact FileStream bytes. Do not decode strings or normalize newlines.

$script:HashRetryCount = 3
$script:HashRetryDelayMs = 100
$script:Win32SharingViolation = 0x80070020
$script:Win32LockViolation = 0x80070021

function Convert-HashBytesToHex {
    param([byte[]]$Hash)

    return [System.BitConverter]::ToString($Hash).Replace("-", "").ToLowerInvariant()
}

function Get-InnermostException {
    param($Exception)

    $current = $Exception
    while ($null -ne $current.InnerException) {
        $current = $current.InnerException
    }

    return $current
}

# Studio's read route refuses a payload over this many bytes with HTTP 413
# "file too large to view". It is a property of GET /file, not of the place
# sequence, so a binary that is placed successfully still cannot be read back
# or verified above it (#51). The limit is observed, not documented.
$script:SyncStudioMaxReadableFileSize = 2000000

function Get-SyncStudioMaxReadableFileSize {
    return [int64]$script:SyncStudioMaxReadableFileSize
}

function Get-SyncEntrySizeValue {
    # The size of a BASE / LOCAL / REMOTE entry, whichever map shape it is in
    # (a Hashtable from BASE, or a PSCustomObject from a parsed manifest), and
    # whichever spelling it uses. Zero when the entry or the size is absent.
    param($Entry)

    if ($null -eq $Entry) {
        return [int64]0
    }

    if ($Entry -is [System.Collections.IDictionary]) {
        foreach ($name in @('Size', 'size')) {
            if ($Entry.Contains($name) -and $null -ne $Entry[$name]) {
                return [int64]$Entry[$name]
            }
        }

        return [int64]0
    }

    foreach ($name in @('Size', 'size')) {
        $property = $Entry.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) {
            return [int64]$property.Value
        }
    }

    return [int64]0
}

function Test-SyncOversizeSize {
    # True when a payload is over Studio's read limit, so GET /file would
    # refuse it with 413 and its bytes can never be verified.
    param([int64]$Size)

    return ($Size -gt [int64]$script:SyncStudioMaxReadableFileSize)
}

function Test-SyncOversizeEntry {
    param($Entry)

    return (Test-SyncOversizeSize -Size (Get-SyncEntrySizeValue -Entry $Entry))
}

function Get-SyncOversizeRefusalReason {
    # One actionable line. A bare 413 told the user nothing, so name the size,
    # the limit, why it cannot work, and what to do about it.
    param([int64]$Size)

    return (
        "{0} bytes is over Studio's {1}-byte read limit: GET /file returns 413 'file too large to view' above it, so the bytes could be placed but never read back or verified. Exclude this file from the sync folder to sync the rest." -f `
            [string]$Size, [string]$script:SyncStudioMaxReadableFileSize
    )
}

# A plain content MD5: 32 lowercase hex characters. Object storage switches an
# ETag to '<md5-of-parts>-<partcount>' for a multipart upload, which is NOT a
# digest of the whole object, so that shape must be refused rather than
# compared (#54).
$script:SyncPlainMd5DigestPattern = '^[0-9a-f]{32}$'

function Test-SyncPlainMd5Digest {
    param([string]$Digest)

    if ([string]::IsNullOrWhiteSpace($Digest)) {
        return $false
    }

    return [bool]([regex]::IsMatch([string]$Digest, $script:SyncPlainMd5DigestPattern))
}

function Get-SyncMd5HexFromEtag {
    # Normalize an ETag header to a bare lowercase digest, dropping the
    # weak-validator prefix and the quoting the header may carry.
    param([string]$Etag)

    if ([string]::IsNullOrWhiteSpace($Etag)) {
        return $null
    }

    $value = ([string]$Etag).Trim()
    $value = $value -replace '^W/', ''
    $value = $value.Trim([char]'"')

    return $value.ToLowerInvariant()
}

function Get-SyncMd5HexFromBytes {
    # MD5 of an in-memory payload. The place sequence hashes the exact byte
    # array it uploaded, so the identity cannot drift if the local file changes
    # between the read and the upload (#54). SHA-256 remains the identity
    # everywhere else, and BASE still records SHA-256.
    param([byte[]]$Bytes)

    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        return Convert-HashBytesToHex -Hash $md5.ComputeHash($Bytes)
    }
    finally {
        $md5.Dispose()
    }
}

function Assert-SyncEtagMatchesLocalMd5 {
    # Prove the object the presigned PUT stored is byte-identical to the local
    # file, using the ETag as the only evidence.
    #
    # Why this exists: a binary over Studio's read limit can be placed but never
    # read back, so the normal SHA-256 read-back verify is impossible (#51).
    # The presigned PUT's ETag is the MD5 of the stored bytes, measured at
    # 2,000,001 bytes, 10 MB, and 50 MB, still a plain digest at 50 MB, and
    # unchanged by the rename route (#54).
    #
    # MD5 is weaker than the SHA-256 used everywhere else, so it is accepted
    # ONLY here, and only as one of several checks: the caller must also have
    # confirmed the adopt-recorded path and the recorded size. A non-plain
    # digest (a multipart ETag) is refused, never compared.
    param(
        [Parameter(Mandatory)]
        [string]$Etag,

        [Parameter(Mandatory)]
        [string]$LocalMd5Hex,

        [Parameter(Mandatory)]
        [string]$CanonicalPath
    )

    $normalized = Get-SyncMd5HexFromEtag -Etag $Etag

    if (-not (Test-SyncPlainMd5Digest -Digest $normalized)) {
        throw [System.InvalidOperationException]::new(
            ("Refusing to verify '{0}': the upload ETag '{1}' is not a plain content MD5, so it cannot be used as byte identity." -f `
                $CanonicalPath, [string]$Etag)
        )
    }

    if (-not [string]::Equals($normalized, [string]$LocalMd5Hex, [System.StringComparison]::Ordinal)) {
        throw [System.InvalidOperationException]::new(
            ("Refusing to verify '{0}': the stored object's MD5 '{1}' does not match the local file's MD5 '{2}'." -f `
                $CanonicalPath, $normalized, [string]$LocalMd5Hex)
        )
    }

    return $normalized
}

function Get-SyncOversizeReplaceRefusalReason {
    # Oversize is fatal for a REPLACE specifically. A create can be verified
    # from the upload ETag, but a replace needs the existing remote bytes for
    # the pre-overwrite backup and the expectedRemoteHash gate, and GET /file
    # cannot return them above the limit (#54).
    param([int64]$Size)

    return (
        "{0} bytes is over Studio's {1}-byte read limit, and this is a replacement: GET /file returns 413 'file too large to view' above it, so the existing remote bytes cannot be read for the pre-overwrite backup or the expectedRemoteHash check. An oversize create is verifiable from the upload ETag, but a replacement is not. Delete the remote copy first, or exclude this file." -f `
            [string]$Size, [string]$script:SyncStudioMaxReadableFileSize
    )
}

function Get-SyncFailureReason {
    # The single most specific cause of a failure, flattened to one line.
    #
    # A post-move failure is wrapped so its top-level message names the
    # ambiguous remote state, which means the real cause lives in
    # InnerException. The Push report reads only the outermost Message, so
    # without this a REFUSED row says "Binary place failed after move" with no
    # clue which check failed (#51). This returns the innermost message with
    # runs of whitespace collapsed, so a report row or a wrapper message stays
    # one line.
    #
    # It only surfaces text that was already on the exception. Callers must
    # still keep file contents and tokens out of exception messages.
    param($Exception)

    if ($null -eq $Exception) {
        return ''
    }

    $inner = Get-InnermostException -Exception $Exception
    if ($null -eq $inner) {
        return ''
    }

    $text = [string]$inner.Message
    if ([string]::IsNullOrWhiteSpace($text)) {
        return ''
    }

    return (($text -replace '\s+', ' ').Trim())
}

function New-RemotePlaceAfterMoveFailure {
    # Build the "move succeeded, a later verify failed" exception. The
    # top-level message names the ambiguous remote state; the inner cause is
    # appended so a REFUSED row says which check actually failed (#51). Both
    # the binary-place and text-create sequences share this shape.
    param(
        [Parameter(Mandatory)]
        [string]$Summary,

        [Parameter(Mandatory)]
        $Cause
    )

    $message = $Summary
    $innerReason = Get-SyncFailureReason -Exception $Cause
    if (-not [string]::IsNullOrEmpty($innerReason)) {
        $message = '{0} Verify failure: {1}' -f $message, $innerReason
    }

    return [System.InvalidOperationException]::new($message, $Cause)
}

function Test-RetryableFileReadException {
    param($Exception)

    $inner = Get-InnermostException -Exception $Exception
    $hresult = [int]$inner.HResult

    if (
        $hresult -eq $script:Win32SharingViolation -or
        $hresult -eq $script:Win32LockViolation -or
        $hresult -eq 32 -or
        $hresult -eq 33
    ) {
        return $true
    }

    if ($inner -is [System.IO.IOException]) {
        return $true
    }

    return $false
}

function ConvertTo-LineEndingKind {
    param(
        [int]$LfOnlyCount,
        [int]$CrlfCount,
        [bool]$HasLoneCr
    )

    if ($HasLoneCr) {
        return "mixed"
    }

    if ($LfOnlyCount -eq 0 -and $CrlfCount -eq 0) {
        return "none"
    }

    if ($LfOnlyCount -gt 0 -and $CrlfCount -eq 0) {
        return "lf"
    }

    if ($CrlfCount -gt 0 -and $LfOnlyCount -eq 0) {
        return "crlf"
    }

    return "mixed"
}

function Get-LocalFileIdentityOnce {
    param([string]$LiteralPath)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $utf8 = New-Object System.Text.UTF8Encoding $false, $true
    $decoder = $utf8.GetDecoder()
    $buffer = New-Object byte[] 65536
    $charBuffer = New-Object char[] ($utf8.GetMaxCharCount($buffer.Length))

    $sawNul = $false
    $utf8Valid = $true
    $hasBom = $false
    $checkedBom = $false
    $lfOnlyCount = 0
    $crlfCount = 0
    $hasLoneCr = $false
    $prevWasCr = $false
    $sizeAtOpen = [int64]0

    $stream = [System.IO.File]::Open(
        $LiteralPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )

    try {
        $sizeAtOpen = $stream.Length

        while ($true) {
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) {
                break
            }

            [void]$sha.TransformBlock($buffer, 0, $read, $null, 0)

            if (-not $checkedBom) {
                $checkedBom = $true
                if (
                    $read -ge 3 -and
                    $buffer[0] -eq 0xEF -and
                    $buffer[1] -eq 0xBB -and
                    $buffer[2] -eq 0xBF
                ) {
                    $hasBom = $true
                }
            }

            for ($i = 0; $i -lt $read; $i++) {
                $byte = $buffer[$i]

                if ($byte -eq 0) {
                    $sawNul = $true
                    $utf8Valid = $false
                }

                if ($byte -eq 0x0A) {
                    if ($prevWasCr) {
                        $crlfCount++
                    }
                    else {
                        $lfOnlyCount++
                    }

                    $prevWasCr = $false
                }
                elseif ($byte -eq 0x0D) {
                    if ($prevWasCr) {
                        $hasLoneCr = $true
                    }

                    $prevWasCr = $true
                }
                else {
                    if ($prevWasCr) {
                        $hasLoneCr = $true
                    }

                    $prevWasCr = $false
                }
            }

            if ($utf8Valid) {
                try {
                    [void]$decoder.GetChars($buffer, 0, $read, $charBuffer, 0)
                }
                catch {
                    $utf8Valid = $false
                }
            }
        }

        if ($prevWasCr) {
            $hasLoneCr = $true
        }

        if ($utf8Valid) {
            try {
                [void]$decoder.GetChars(@(), 0, 0, $charBuffer, 0)
            }
            catch {
                $utf8Valid = $false
            }
        }

        [void]$sha.TransformFinalBlock(@(), 0, 0)
        $hashHex = Convert-HashBytesToHex -Hash $sha.Hash
    }
    finally {
        $stream.Dispose()
        $sha.Dispose()
    }

    $info = New-Object System.IO.FileInfo $LiteralPath
    if ($info.Length -ne $sizeAtOpen) {
        throw [System.IO.IOException]::new(
            "File size changed while hashing '$LiteralPath'."
        )
    }

    $kind = "binary"
    if (-not $sawNul -and $utf8Valid) {
        $kind = "utf8"
    }

    $lineEnding = $null
    $bomValue = $null
    if ($kind -eq "utf8") {
        $lineEnding = ConvertTo-LineEndingKind `
            -LfOnlyCount $lfOnlyCount `
            -CrlfCount $crlfCount `
            -HasLoneCr $hasLoneCr
        $bomValue = [bool]$hasBom
    }

    return [pscustomobject]@{
        Sha256            = $hashHex
        Size              = $sizeAtOpen
        LocalDetectedKind = $kind
        LineEnding        = $lineEnding
        HasBom            = $bomValue
    }
}

function Get-LocalFileIdentity {
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath
    )

    $attempt = 0
    $lastException = $null

    while ($attempt -lt $script:HashRetryCount) {
        $attempt++

        try {
            return Get-LocalFileIdentityOnce -LiteralPath $LiteralPath
        }
        catch {
            $lastException = $_
            $canRetry = Test-RetryableFileReadException -Exception $_.Exception

            if (-not $canRetry -or $attempt -ge $script:HashRetryCount) {
                throw [System.InvalidOperationException]::new(
                    "Unable to read '$LiteralPath' for sync hashing.",
                    $_.Exception
                )
            }

            Start-Sleep -Milliseconds $script:HashRetryDelayMs
        }
    }

    throw [System.InvalidOperationException]::new(
        "Unable to read '$LiteralPath' for sync hashing.",
        $lastException.Exception
    )
}

function Get-FileSha256Hex {
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath
    )

    return (Get-LocalFileIdentity -LiteralPath $LiteralPath).Sha256
}

function ConvertTo-RemoteKind {
    param($Encoding)

    if ([string]::IsNullOrEmpty($Encoding)) {
        return $null
    }

    if ($Encoding -eq "utf8") {
        return "utf8"
    }

    if ($Encoding -eq "base64") {
        return "binary"
    }

    return $null
}

function Test-UnsupportedKindChange {
    param(
        $LocalKind,
        $RemoteKind
    )

    if ([string]::IsNullOrEmpty($LocalKind) -or [string]::IsNullOrEmpty($RemoteKind)) {
        return $false
    }

    if ($LocalKind -eq $RemoteKind) {
        return $false
    }

    $known = @("utf8", "binary")
    if ($known -notcontains $LocalKind -or $known -notcontains $RemoteKind) {
        return $false
    }

    return $true
}
