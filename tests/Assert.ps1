# Small assertion helpers for tests/Run-Tests.ps1.
# Do not require Pester. Callers must not put token values in $Message.

$script:TestPasses = 0
$script:TestFailures = 0

function Format-AssertValue {
    param($Value)

    if ($null -eq $Value) {
        return "<null>"
    }

    $text = [string]$Value

    # JWT-shaped strings are never printed. Auth tests still compare them.
    if ($text -match '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$') {
        return "<redacted jwt length=$($text.Length)>"
    }

    if ($text.Length -gt 80) {
        return "$($text.Substring(0, 24))...(length=$($text.Length))"
    }

    return $text
}

function Test-AssertEqual {
    param($Expected, $Actual)

    if ($null -eq $Expected -and $null -eq $Actual) {
        return $true
    }

    if ($null -eq $Expected -or $null -eq $Actual) {
        return $false
    }

    $expectedIsArray = $Expected -is [System.Array]
    $actualIsArray = $Actual -is [System.Array]

    if ($expectedIsArray -or $actualIsArray) {
        $left = @($Expected)
        $right = @($Actual)

        if ($left.Count -ne $right.Count) {
            return $false
        }

        for ($i = 0; $i -lt $left.Count; $i++) {
            if (-not (Test-AssertEqual $left[$i] $right[$i])) {
                return $false
            }
        }

        return $true
    }

    return $Expected -eq $Actual
}

function Assert-True {
    param(
        $Condition,
        [string]$Message = "Assert-True failed"
    )

    if ($Condition) {
        $script:TestPasses++
        return
    }

    $script:TestFailures++
    Write-Host "FAIL: $Message"
}

function Assert-Equal {
    param(
        $Expected,
        $Actual,
        [string]$Message = "Assert-Equal failed"
    )

    if (Test-AssertEqual $Expected $Actual) {
        $script:TestPasses++
        return
    }

    $script:TestFailures++
    Write-Host "FAIL: $Message"
    Write-Host "  expected: $(Format-AssertValue $Expected)"
    Write-Host "  actual:   $(Format-AssertValue $Actual)"
}

function Assert-Null {
    param(
        $Actual,
        [string]$Message = "Assert-Null failed"
    )

    if ($null -eq $Actual) {
        $script:TestPasses++
        return
    }

    $script:TestFailures++
    Write-Host "FAIL: $Message"
    Write-Host "  actual: $(Format-AssertValue $Actual)"
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Script,
        [string]$Message = "Expected an exception"
    )

    $threw = $false

    try {
        & $Script | Out-Null
    }
    catch {
        $threw = $true
    }

    Assert-True $threw $Message
}
