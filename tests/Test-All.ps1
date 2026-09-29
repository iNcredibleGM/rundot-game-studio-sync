# One-shot test runner: unit suite, offline acceptance gates, live round-trip.
#
#   powershell -NoProfile -File .\tests\Test-All.ps1 -SkipLive
#   powershell -NoProfile -File .\tests\Test-All.ps1 -ProjectId <id>
#
# This is a thin orchestrator. It runs the three existing entry points in child
# processes, streams their output, and prints one combined PASS/FAIL summary:
#
#   1. Run-Tests.ps1        unit suite, no network
#   2. Acceptance.ps1       offline gates (always -SkipLive here)
#   3. Live-RoundTrip.ps1   unattended live round-trip (needs -ProjectId)
#
# tests/Acceptance.ps1's live gates are deliberately NOT run here: gates 2-4
# pause on Read-Host for a human Studio edit, so they cannot be unattended.
# Live-RoundTrip.ps1 covers the same up/down/restore ground without a pause.
#
# Exit code is 0 only when every phase that ran passed.
#
# Use a DISPOSABLE project. No phase prints tokens, auth paths, or file
# contents, and the per-phase logs are removed at the end.

param(
    # Enables the live phase. Without it, only offline phases run. When omitted,
    # a local-only config file is consulted (see Get-LocalTestProjectId).
    [string]$ProjectId,

    # Force offline only, even when -ProjectId was supplied.
    [switch]$SkipLive,

    # Pass through to the live phase: leave its workspace in place.
    [switch]$KeepWorkspace,

    # Pass through to the live phase: do not delete the Studio probe files.
    [switch]$SkipRemoteCleanup
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$unitRunner = Join-Path $PSScriptRoot 'Run-Tests.ps1'
$acceptance = Join-Path $PSScriptRoot 'Acceptance.ps1'
$roundTrip = Join-Path $PSScriptRoot 'Live-RoundTrip.ps1'

$script:Phases = New-Object 'System.Collections.Generic.List[object]'
$script:LogFiles = New-Object 'System.Collections.Generic.List[string]'

function Get-LocalTestProjectId {
    # Read the disposable test project id from a local-only config so it does
    # not have to be pasted on every run. The file is git-ignored (see
    # .git/info/exclude and .gitignore) and holds no credential: a project id is
    # an identifier, not a secret, but it is still not published.
    #
    # Order: -ProjectId parameter wins, then .rundot-test.local.json, then the
    # RUNDOT_TEST_PROJECT_ID environment variable.
    param([string]$ExplicitProjectId)

    if (-not [string]::IsNullOrEmpty($ExplicitProjectId)) {
        return $ExplicitProjectId
    }

    $configPath = Join-Path $repoRoot '.rundot-test.local.json'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try {
            $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
            $value = [string]$config.projectId
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return $value.Trim()
            }
        }
        catch {
            Write-Host ''
            Write-Host ('Ignoring malformed {0}: {1}' -f $configPath, $_.Exception.Message)
            Write-Host ''
        }
    }

    $fromEnv = [string]$env:RUNDOT_TEST_PROJECT_ID
    if (-not [string]::IsNullOrWhiteSpace($fromEnv)) {
        return $fromEnv.Trim()
    }

    return $null
}

function Write-PhaseHeader {
    param([string]$Text)

    Write-Host ''
    Write-Host '##################################################'
    Write-Host ('# ' + $Text)
    Write-Host '##################################################'
    Write-Host ''
}

function Invoke-Phase {
    # Run one child process, stream its output live, and keep a temp log so the
    # summary can quote the pass/fail line. The log is removed at the end.
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$CliArgs
    )

    Write-PhaseHeader $Name

    $log = Join-Path ([System.IO.Path]::GetTempPath()) (
        'rundot-test-all-' + [Guid]::NewGuid().ToString('N') + '.log'
    )
    $script:LogFiles.Add($log)

    $psArgs = @('-NoProfile', '-File') + $CliArgs
    & powershell @psArgs 2>&1 | Tee-Object -FilePath $log
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = 0 }

    # Quote the runner's own summary line when it printed one.
    $detail = ''
    try {
        $text = [System.IO.File]::ReadAllText($log)
        $match = [regex]::Match($text, '(?m)^Passed:\s+(\d+)\s+Failed:\s+(\d+)')
        if ($match.Success) {
            $detail = ('passed {0}, failed {1}' -f $match.Groups[1].Value, $match.Groups[2].Value)
        }
    }
    catch {
        # Detail is optional.
    }

    $status = 'PASS'
    if ([int]$code -ne 0) { $status = 'FAIL' }
    if ([string]::IsNullOrEmpty($detail)) { $detail = ("exit code {0}" -f $code) }

    $script:Phases.Add([pscustomobject]@{
        Name   = $Name
        Status = $status
        Detail = $detail
    })

    Write-Host ''
    Write-Host ("  >>> {0}  {1}" -f $status, $Name)
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Phase 1: unit suite (offline)
# ---------------------------------------------------------------------------
Invoke-Phase -Name '1. Unit suite (Run-Tests.ps1)' -CliArgs @($unitRunner)

# ---------------------------------------------------------------------------
# Phase 2: offline acceptance gates
# ---------------------------------------------------------------------------

Invoke-Phase -Name '2. Offline acceptance gates (Acceptance.ps1 -SkipLive)' `
    -CliArgs @($acceptance, '-SkipLive')

# ---------------------------------------------------------------------------
# Phase 3: live round-trip (unattended)
# ---------------------------------------------------------------------------

# -ProjectId wins; otherwise the local config or environment supplies it.
if ([string]::IsNullOrEmpty($ProjectId)) {
    $ProjectId = Get-LocalTestProjectId -ExplicitProjectId $ProjectId
    if (-not [string]::IsNullOrEmpty($ProjectId)) {
        Write-Host ("Using project id from local config: {0}" -f $ProjectId)
        Write-Host ''
    }
}

$runLive = (-not $SkipLive) -and (-not [string]::IsNullOrEmpty($ProjectId))

if ($runLive) {
    $liveArgs = @($roundTrip, '-ProjectId', $ProjectId)
    if ($KeepWorkspace) { $liveArgs += '-KeepWorkspace' }
    if ($SkipRemoteCleanup) { $liveArgs += '-SkipRemoteCleanup' }

    Invoke-Phase -Name '3. Live round-trip (Live-RoundTrip.ps1)' -CliArgs $liveArgs
}
else {
    $reason = '-SkipLive'
    if (-not $SkipLive) { $reason = 'no project id (pass -ProjectId, or set .rundot-test.local.json / RUNDOT_TEST_PROJECT_ID)' }

    $script:Phases.Add([pscustomobject]@{
        Name   = '3. Live round-trip (Live-RoundTrip.ps1)'
        Status = 'SKIP'
        Detail = $reason
    })
}

# ---------------------------------------------------------------------------
# Combined summary
# ---------------------------------------------------------------------------

Write-PhaseHeader 'Combined summary'

foreach ($phase in $script:Phases) {
    Write-Host ("  {0,-6} {1}" -f $phase.Status, $phase.Name)
    if (-not [string]::IsNullOrEmpty($phase.Detail)) {
        Write-Host ("         {0}" -f $phase.Detail)
    }
}

$failed = @($script:Phases | Where-Object { $_.Status -eq 'FAIL' }).Count
$passed = @($script:Phases | Where-Object { $_.Status -eq 'PASS' }).Count
$skipped = @($script:Phases | Where-Object { $_.Status -eq 'SKIP' }).Count

Write-Host ''
Write-Host ("Phases passed: {0}  failed: {1}  skipped: {2}" -f $passed, $failed, $skipped)
Write-Host ''

if ($skipped -gt 0) {
    Write-Host 'Skipped phases need a disposable project:'
    Write-Host '  powershell -NoProfile -File .\tests\Test-All.ps1 -ProjectId <id>'
    Write-Host ''
}

# A live phase that could not run its teardown leaves the probe files on
# Studio; say so rather than letting it pass silently.
if ($runLive -and $SkipRemoteCleanup) {
    Write-Host 'NOTE: -SkipRemoteCleanup was set, so the Studio probe files remain.'
    Write-Host ''
}

# Remove the per-phase logs. They hold console output only (no tokens, auth
# paths, or file contents), but nothing is left behind by default.
foreach ($log in $script:LogFiles) {
    if (Test-Path -LiteralPath $log) {
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    }
}

if ($failed -gt 0) {
    exit 1
}

exit 0
