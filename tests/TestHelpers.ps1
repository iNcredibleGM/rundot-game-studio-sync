# Shared helpers for tests/Run-Tests.ps1, Acceptance.ps1, and Live-RoundTrip.ps1.
#
# File-scope functions here must not reuse a name from lib/*.ps1. Stubs for
# Get-RemoteProjectFileList, Get-RemoteProjectFile, and Invoke-Utf8TextGet are
# installed into script: scope only when a test calls the installer functions.

function Write-Phase {
    param([string]$Text)

    Write-Host ""
    Write-Host "=================================================="
    Write-Host $Text
    Write-Host "=================================================="
}

function Invoke-SyncCli {
    # Runs the sync CLI in a child process and captures its exit code.
    # Output is returned in memory only; it is never written to disk.
    param(
        [string[]]$CliArgs,
        [switch]$NonInteractive
    )

    $psArgs = @('-NoProfile')
    if ($NonInteractive) {
        $psArgs += '-NonInteractive'
    }
    $psArgs += @('-File', $syncCli)
    $psArgs += $CliArgs

    $outputLines = & powershell @psArgs 2>&1
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = 0 }

    $output = ($outputLines | Out-String)

    return [pscustomobject]@{ Output = $output; ExitCode = [int]$code }
}

function Get-PushBinaryRows {
    # Parse the BINARY section of a Push report into path and create/replace rows.
    param([string]$Output)

    $rows = New-Object 'System.Collections.Generic.List[object]'
    $lines = $Output -split "`n"
    $inSection = $false

    foreach ($line in $lines) {
        $trimmed = $line.TrimEnd("`r")

        if ($trimmed -eq 'BINARY') {
            $inSection = $true
            continue
        }

        if (-not $inSection) { continue }

        if ($trimmed -match '^\s+(.+?)\s+\(binary (create|replace)\)\s*$') {
            $rows.Add([pscustomobject]@{
                Path = $matches[1].Trim()
                Mode = $matches[2]
            })
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($trimmed) -and $trimmed -notmatch '^\s') { break }
    }

    return $rows.ToArray()
}

function Get-ShortHash {
    param([string]$Hash)

    if ([string]::IsNullOrEmpty($Hash)) { return "<none>" }
    if ($Hash.Length -le 12) { return $Hash }
    return $Hash.Substring(0, 12)
}

function Reset-FakeRemote {
    param(
        [object[]]$Lists = @(),
        [hashtable]$Files = @{},
        [hashtable]$FileErrors = @{}
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

function Enable-FakeRemoteProjectReads {
    function script:Get-RemoteProjectFileList {
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

    function script:Get-RemoteProjectFile {
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
}

function Set-Utf8TextGetStub {
    param(
        [Parameter(Mandatory)]
        [string]$ResponseText
    )

    $script:Utf8TextGetStubText = $ResponseText

    function script:Invoke-Utf8TextGet {
        param(
            [string]$Uri,
            [hashtable]$Headers
        )

        $script:CapturedTextUri = $Uri
        $script:CapturedTextHeaders = $Headers
        return $script:Utf8TextGetStubText
    }
}
