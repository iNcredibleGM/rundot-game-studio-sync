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
