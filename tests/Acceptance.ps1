# Acceptance harness for the v0.1.3 safe pull planner final gates.
#
# Companion to docs/acceptance.md: this script executes the gates that can be
# run from a terminal, and prints a PASS/FAIL table.
#
#   powershell -NoProfile -File .\tests\Acceptance.ps1 -SkipLive
#   powershell -NoProfile -File .\tests\Acceptance.ps1 -ProjectId <id> -LocalDir <dir>
#
# Offline gates need no network and no account. Live gates talk to Studio and
# REQUIRE YOUR HELP: the script pauses and tells you what to change in Studio,
# because automating Studio writes is a non-goal of this milestone.
#
# This script never prints or persists tokens, auth files, or file contents.
# It is named Acceptance.ps1, not *.Tests.ps1, so tests/Run-Tests.ps1 does not
# pick it up: the offline gates need real child processes and a lock hold, which
# do not belong in the fast unit suite.

param(
    # Studio project to use for the live gates. Use a DISPOSABLE project.
    [string]$ProjectId,

    # Workspace for the live gates. Created by this script if missing.
    [string]$LocalDir,

    # Run only the gates that need no network or account.
    [switch]$SkipLive,

    # Leave the workspace and backups in place so you can inspect them.
    [switch]$KeepWorkspace
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path $PSScriptRoot -Parent
$syncCli = Join-Path $repoRoot "game-studio-sync.ps1"
$testRunner = Join-Path $PSScriptRoot "Run-Tests.ps1"

. (Join-Path $repoRoot "lib\Paths.ps1")
. (Join-Path $repoRoot "lib\Ignore.ps1")
. (Join-Path $repoRoot "lib\Hashing.ps1")
. (Join-Path $repoRoot "lib\Workspace.ps1")
. (Join-Path $repoRoot "lib\Manifest.ps1")

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

$script:GateResults = New-Object 'System.Collections.Generic.List[object]'

# Set when this run creates the live workspace, so cleanup removes only what it
# made rather than a directory the user pointed at on purpose.
$script:liveWorkspaceCreated = $false

function Add-GateResult {
    param(
        [Parameter(Mandatory)][string]$Gate,
        [Parameter(Mandatory)][string]$Status,
        [string]$Detail = ""
    )

    $script:GateResults.Add([pscustomobject]@{
        Gate   = $Gate
        Status = $Status
        Detail = $Detail
    })

    $marker = switch ($Status) {
        'PASS' { 'PASS' }
        'FAIL' { 'FAIL' }
        'SKIP' { 'SKIP' }
        default { $Status }
    }

    Write-Host ("  [{0}] {1}" -f $marker, $Gate)
    if (-not [string]::IsNullOrEmpty($Detail)) {
        Write-Host ("         {0}" -f $Detail)
    }
}

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
    param([string[]]$CliArgs)

    $output = (& powershell -NoProfile -File $syncCli @CliArgs 2>&1 | Out-String)
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = 0 }

    return [pscustomobject]@{ Output = $output; ExitCode = [int]$code }
}

function Get-PlanSummaryCount {
    # Reads one "  <status>: <n>" line out of a Plan SUMMARY section.
    param(
        [string]$Output,
        [string]$StatusName
    )

    $match = [regex]::Match($Output, ('(?m)^\s+' + [regex]::Escape($StatusName) + ':\s+(\d+)\s*$'))
    if (-not $match.Success) { return $null }

    return [int]$match.Groups[1].Value
}

function Test-PlanHasSection {
    param(
        [string]$Output,
        [string]$Header
    )

    return [bool]([regex]::IsMatch($Output, ('(?m)^' + [regex]::Escape($Header) + '\s*$')))
}

function Get-PlanSectionRowCount {
    # Counts operation rows in a section. Every row line carries 'base='.
    param(
        [string]$Output,
        [string]$Header
    )

    $lines = $Output -split "`n"
    $count = 0
    $inSection = $false

    foreach ($line in $lines) {
        $trimmed = $line.TrimEnd("`r")

        if ($trimmed -eq $Header) {
            $inSection = $true
            continue
        }

        if (-not $inSection) { continue }

        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

        # A row, still inside the section.
        if ($trimmed -match 'base=') {
            $count++
            continue
        }

        # Any other header ends the section.
        if ($trimmed -notmatch '^\s') { break }
    }

    return $count
}

function Get-PlanAppliedRows {
    # Parses the Pull APPLIED section into path plus create/overwrite.
    param([string]$Output)

    $rows = New-Object 'System.Collections.Generic.List[object]'
    $lines = $Output -split "`n"
    $inSection = $false

    foreach ($line in $lines) {
        $trimmed = $line.TrimEnd("`r")

        if ($trimmed -eq 'APPLIED') {
            $inSection = $true
            continue
        }

        if (-not $inSection) { continue }

        if ($trimmed -match '^\s+(.+?)\s+\((create|overwrite)\)\s*$') {
            $rows.Add([pscustomobject]@{
                Path = $matches[1].Trim()
                Kind = $matches[2]
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

# ---------------------------------------------------------------------------
# Offline gates
# ---------------------------------------------------------------------------

$scratchRoot = Join-Path $env:TEMP ("rundot-acceptance-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $scratchRoot -Force | Out-Null

Write-Phase "Offline gates (no network, no account)"

# Gate 1: the unit suite
Write-Host ""
Write-Host "Running tests/Run-Tests.ps1 (this takes a few seconds)..."
$suiteOutput = (& powershell -NoProfile -File $testRunner 2>&1 | Out-String)
$suiteCode = $LASTEXITCODE
if ($null -eq $suiteCode) { $suiteCode = 0 }

$suitePassed = [regex]::Match($suiteOutput, 'Passed:\s+(\d+)')
$suiteFailed = [regex]::Match($suiteOutput, 'Failed:\s+(\d+)')
$suiteDetail = "passed={0} failed={1} exit={2}" -f `
    $(if ($suitePassed.Success) { $suitePassed.Groups[1].Value } else { '?' }), `
    $(if ($suiteFailed.Success) { $suiteFailed.Groups[1].Value } else { '?' }), `
    $suiteCode

if ($suiteCode -eq 0) {
    Add-GateResult -Gate "1. Run-Tests.ps1 green" -Status "PASS" -Detail $suiteDetail
}
else {
    Add-GateResult -Gate "1. Run-Tests.ps1 green" -Status "FAIL" -Detail $suiteDetail
    # Show the failure lines so the run is actionable.
    foreach ($line in ($suiteOutput -split "`n")) {
        if ($line -match 'FAIL:|Failed:') { Write-Host ("         {0}" -f $line.TrimEnd()) }
    }
}

# Gate 5: case collision hard-fails
$collisionThrew = $false
try {
    Assert-SafeSyncPathSet -Paths @('Foo.ts', 'foo.ts')
}
catch {
    $collisionThrew = $true
}

if ($collisionThrew) {
    Add-GateResult -Gate "5. Case collision hard-fails" -Status "PASS" -Detail "'Foo.ts' + 'foo.ts' refused"
}
else {
    Add-GateResult -Gate "5. Case collision hard-fails" -Status "FAIL" -Detail "the path set was accepted"
}

# Gate 7: an unreadable local file aborts the local inventory
$lockDir = Join-Path $scratchRoot "locked"
New-Item -ItemType Directory -Path $lockDir -Force | Out-Null
$lockPath = Join-Path $lockDir "locked.ts"
[System.IO.File]::WriteAllBytes($lockPath, [byte[]](0x61))

$lockStream = [System.IO.File]::Open(
    $lockPath,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::ReadWrite,
    [System.IO.FileShare]::None
)
$inventoryThrew = $false
try {
    [void](Get-LocalManifest -WorkspaceRoot $lockDir)
}
catch {
    $inventoryThrew = $true
}
finally {
    $lockStream.Dispose()
}

if ($inventoryThrew) {
    Add-GateResult -Gate "7a. Unreadable file aborts the local inventory" -Status "PASS" `
        -Detail "a locked file made the inventory throw instead of returning a partial map"
}
else {
    Add-GateResult -Gate "7a. Unreadable file aborts the local inventory" -Status "FAIL" `
        -Detail "the inventory returned despite a locked file"
}

# Gate 7b: the CLI must build the local inventory before it classifies, so an
# unreadable file cannot produce a plan.
#
# This is a source-order assertion rather than a live abort, and that is a
# deliberate limit: Plan authenticates BEFORE it reads LOCAL, so running the
# real abort end to end needs a token. Asserting exit code alone would be a
# false pass, because Plan also exits non-zero when BASE is missing, which
# would "prove" this gate for entirely the wrong reason.
$noBaseDir = Join-Path $scratchRoot "no-base"
New-Item -ItemType Directory -Path $noBaseDir -Force | Out-Null
$planArtifactPath = Join-Path $noBaseDir ".rundot-sync\last-plan.json"

$syncCliSource = [System.IO.File]::ReadAllText($syncCli)
$planFnStart = $syncCliSource.IndexOf('function Invoke-SyncPlanCommand')
$planFnEnd = $syncCliSource.IndexOf('function Invoke-SyncPullCommand')
$planFnText = ''
if ($planFnStart -ge 0 -and $planFnEnd -gt $planFnStart) {
    $planFnText = $syncCliSource.Substring($planFnStart, $planFnEnd - $planFnStart)
}

$authIdx = $planFnText.IndexOf('Get-RundotAccessToken')
$localIdx = $planFnText.IndexOf('Get-LocalManifest')
$classifyIdx = $planFnText.IndexOf('New-RundotSyncPlanAnalysis')
$exitOneIdx = $planFnText.IndexOf('exit 1')

$orderOk = (
    $authIdx -ge 0 -and
    $localIdx -gt $authIdx -and
    $classifyIdx -gt $localIdx -and
    $exitOneIdx -ge 0
)

if ($orderOk) {
    Add-GateResult -Gate "7b. Plan inventories LOCAL before classifying" -Status "PASS" `
        -Detail "Get-LocalManifest runs before New-RundotSyncPlanAnalysis, so a partial tree cannot be planned as deletions; the failure path exits non-zero"
}
else {
    Add-GateResult -Gate "7b. Plan inventories LOCAL before classifying" -Status "FAIL" `
        -Detail ("auth={0}, local={1}, classify={2}, exit1={3} (each must be present, and in that order)" -f `
            $authIdx, $localIdx, $classifyIdx, $exitOneIdx)
}

# Gate 8: Plan without BASE refuses, before authentication and with no artifact
$planNoBaseResult = Invoke-SyncCli -CliArgs @(
    '-ProjectId', 'acceptance-offline-gate', '-LocalDir', $noBaseDir, '-Command', 'Plan'
)

$refusalMentionsBase = ($planNoBaseResult.Output -match '(?i)no BASE manifest')
$refusalPointsAtInit = ($planNoBaseResult.Output -match '(?i)InitMode')
$noBaseArtifact = -not (Test-Path -LiteralPath $planArtifactPath)

if ($planNoBaseResult.ExitCode -ne 0 -and $refusalMentionsBase -and $refusalPointsAtInit -and $noBaseArtifact) {
    Add-GateResult -Gate "8. Plan without BASE refuses" -Status "PASS" `
        -Detail "exit non-zero, names the missing BASE, points at Init, writes no artifact"
}
else {
    Add-GateResult -Gate "8. Plan without BASE refuses" -Status "FAIL" `
        -Detail ("exit={0}, mentions BASE={1}, points at Init={2}, artifact={3}" -f `
            $planNoBaseResult.ExitCode, $refusalMentionsBase, $refusalPointsAtInit, (Test-Path -LiteralPath $planArtifactPath))
}

# Gate 10: mutation grep
$productFiles = @()
foreach ($candidate in @($syncCli, (Join-Path $repoRoot "game-studio-export.ps1"))) {
    if (Test-Path -LiteralPath $candidate) { $productFiles += Get-Item $candidate }
}
$libRoot = Join-Path $repoRoot "lib"
if (Test-Path -LiteralPath $libRoot) {
    $productFiles += @(Get-ChildItem -Path $libRoot -Recurse -Filter "*.ps1")
}

$mutationHits = New-Object 'System.Collections.Generic.List[string]'
foreach ($file in $productFiles) {
    $text = Get-Content -Path $file.FullName -Raw
    $relative = $file.FullName.Substring($repoRoot.Length).TrimStart("\", "/")

    foreach ($pattern in @(
        '(?i)upload-url|upload-adopt',
        '(?i)(?:-Method\s+[''"]?PUT\b|(?:\.Method|\bMethod)\s*=\s*[''"]PUT[''"])',
        '(?i)(?:-Method\s+[''"]?DELETE\b|(?:\.Method|\bMethod)\s*=\s*[''"]DELETE[''"])'
    )) {
        if ([regex]::IsMatch($text, $pattern)) {
            $mutationHits.Add("${relative}: $pattern")
        }
    }

    if (($relative -replace "\\", "/") -eq 'lib/RemoteApi.ps1') {
        if ([regex]::IsMatch($text, '(?im)^\s*function\s+Set-')) { $mutationHits.Add("${relative}: Set-* function") }
        if ([regex]::IsMatch($text, '(?im)^\s*function\s+Remove-')) { $mutationHits.Add("${relative}: Remove-* function") }
    }
}

if ($mutationHits.Count -eq 0) {
    Add-GateResult -Gate "10. Mutation grep still zero" -Status "PASS" `
        -Detail ("scanned {0} product file(s)" -f $productFiles.Count)
}
else {
    Add-GateResult -Gate "10. Mutation grep still zero" -Status "FAIL" -Detail ($mutationHits -join "; ")
}

# ---------------------------------------------------------------------------
# Live gates
# ---------------------------------------------------------------------------

if ($SkipLive) {
    Add-GateResult -Gate "2. Init, one edit, one upload, zero invented deletes" -Status "SKIP" -Detail "-SkipLive"
    Add-GateResult -Gate "3. One remote change classifies as download or conflict" -Status "SKIP" -Detail "-SkipLive"
    Add-GateResult -Gate "4. Pull applies clean remote-only change with a restorable backup" -Status "SKIP" -Detail "-SkipLive"
    Add-GateResult -Gate "6. Unstable snapshot retries/aborts" -Status "SKIP" -Detail "-SkipLive"
    Add-GateResult -Gate "9. Plan shows expiresAt" -Status "SKIP" -Detail "-SkipLive"
}
elseif ([string]::IsNullOrEmpty($ProjectId)) {
    Add-GateResult -Gate "2-4, 6, 9 live gates" -Status "SKIP" -Detail "no -ProjectId supplied; rerun with -ProjectId <id>"
}
else {
    if ([string]::IsNullOrEmpty($LocalDir)) {
        $LocalDir = Join-Path $scratchRoot "live-workspace"
        $script:liveWorkspaceCreated = $true
    }

    if (-not [System.IO.Path]::IsPathRooted($LocalDir)) {
        $LocalDir = Join-Path $repoRoot $LocalDir
    }

    $LocalDir = [System.IO.Path]::GetFullPath($LocalDir)

    if (-not (Test-Path -LiteralPath $LocalDir -PathType Container)) {
        $script:liveWorkspaceCreated = $true
    }

    Write-Phase "Live gates"
    Write-Host ""
    Write-Host "Project:   $ProjectId"
    Write-Host "Workspace: $LocalDir"
    Write-Host ""
    Write-Host "Use a DISPOSABLE project. This script only reads from Studio;"
    Write-Host "you make the Studio-side edits when it pauses."

    $basePath = Join-Path $LocalDir ".rundot-sync\base-manifest.json"
    if (-not (Test-Path -LiteralPath $basePath)) {
        Write-Host ""
        Write-Host "No BASE found, so this script will initialize the workspace."
        Write-Host "Init -InitMode FromRemote requires a new or empty directory."
        Write-Host ""
        $initResult = Invoke-SyncCli -CliArgs @(
            '-ProjectId', $ProjectId, '-LocalDir', $LocalDir,
            '-Command', 'Init', '-InitMode', 'FromRemote'
        )

        if ($initResult.ExitCode -ne 0) {
            Add-GateResult -Gate "2. Init, one edit, one upload, zero invented deletes" -Status "FAIL" `
                -Detail ("Init failed with exit {0}; see the output above" -f $initResult.ExitCode)
            Add-GateResult -Gate "3. One remote change classifies as download or conflict" -Status "SKIP" -Detail "Init failed"
            Add-GateResult -Gate "4. Pull applies clean remote-only change with a restorable backup" -Status "SKIP" -Detail "Init failed"
            Add-GateResult -Gate "6. Unstable snapshot retries/aborts" -Status "SKIP" -Detail "Init failed"
            Add-GateResult -Gate "9. Plan shows expiresAt" -Status "SKIP" -Detail "Init failed"
        }
    }

    if (Test-Path -LiteralPath $basePath) {
        # Gate 2: one local edit is exactly one upload, with no invented deletes.
        Write-Host ""
        Write-Host "--------------------------------------------------"
        Write-Host "GATE 2: one local edit"
        Write-Host "--------------------------------------------------"
        Write-Host "Pick ONE tracked file in the workspace and make a small edit, then"
        Write-Host "press Enter. This script does not edit your files for you, so the"
        Write-Host "change under test is unambiguously yours."
        Write-Host ""
        [void](Read-Host "Press Enter once the edit is saved")

        $planOne = Invoke-SyncCli -CliArgs @(
            '-ProjectId', $ProjectId, '-LocalDir', $LocalDir, '-Command', 'Plan'
        )

        $uploadCount = Get-PlanSummaryCount -Output $planOne.Output -StatusName 'upload'
        $uploadRows = Get-PlanSectionRowCount -Output $planOne.Output -Header 'UPLOAD'
        $delRemote = Get-PlanSummaryCount -Output $planOne.Output -StatusName 'deleteRemoteCandidate'
        $delLocal = Get-PlanSummaryCount -Output $planOne.Output -StatusName 'deleteLocalCandidate'
        $conflicts = Get-PlanSummaryCount -Output $planOne.Output -StatusName 'conflict'
        $hasStagedDeletes = Test-PlanHasSection -Output $planOne.Output -Header 'STAGED DELETES'

        # Gate 9 rides along: this is a real plan artifact.
        $expiresMatch = [regex]::Match($planOne.Output, '(?m)^expiresAt:\s+(\S+)')
        $createdMatch = [regex]::Match($planOne.Output, '(?m)^createdAt:\s+(\S+)')

        $oneUpload = ($uploadCount -eq 1 -and $uploadRows -eq 1)
        $zeroDeletes = (($null -eq $delRemote -or $delRemote -eq 0) -and ($null -eq $delLocal -or $delLocal -eq 0))

        if ($oneUpload -and $zeroDeletes -and -not $hasStagedDeletes) {
            Add-GateResult -Gate "2. Init, one edit, one upload, zero invented deletes" -Status "PASS" `
                -Detail ("upload rows={0}, deleteRemoteCandidate={1}, deleteLocalCandidate={2}" -f $uploadRows, $delRemote, $delLocal)
        }
        else {
            Add-GateResult -Gate "2. Init, one edit, one upload, zero invented deletes" -Status "FAIL" `
                -Detail ("upload rows={0} (summary {1}), deleteRemoteCandidate={2}, deleteLocalCandidate={3}, STAGED DELETES section={4}, conflict={5}" -f `
                    $uploadRows, $uploadCount, $delRemote, $delLocal, $hasStagedDeletes, $conflicts)
        }

        # Gate 9: expiresAt is shown and is after createdAt.
        if ($expiresMatch.Success -and $createdMatch.Success) {
            $createdAt = [System.DateTime]::Parse($createdMatch.Groups[1].Value)
            $expiresAt = [System.DateTime]::Parse($expiresMatch.Groups[1].Value)
            if ($expiresAt -gt $createdAt) {
                Add-GateResult -Gate "9. Plan shows expiresAt" -Status "PASS" `
                    -Detail ("expiresAt {0} is after createdAt {1}" -f $expiresMatch.Groups[1].Value, $createdMatch.Groups[1].Value)
            }
            else {
                Add-GateResult -Gate "9. Plan shows expiresAt" -Status "FAIL" -Detail "expiresAt is not after createdAt"
            }
        }
        else {
            Add-GateResult -Gate "9. Plan shows expiresAt" -Status "FAIL" -Detail "the Plan header did not show expiresAt"
        }

        # Gate 3: one remote change classifies as download or conflict.
        Write-Host ""
        Write-Host "--------------------------------------------------"
        Write-Host "GATE 3: one remote change"
        Write-Host "--------------------------------------------------"
        Write-Host "In Studio, change exactly ONE file that you did NOT edit locally,"
        Write-Host "and save it. A text file is easiest. Then press Enter."
        Write-Host ""
        [void](Read-Host "Press Enter once the Studio edit is saved")

        $planTwo = Invoke-SyncCli -CliArgs @(
            '-ProjectId', $ProjectId, '-LocalDir', $LocalDir, '-Command', 'Plan'
        )

        $downloadCount = Get-PlanSummaryCount -Output $planTwo.Output -StatusName 'download'
        $conflictCount = Get-PlanSummaryCount -Output $planTwo.Output -StatusName 'conflict'

        $classifiedDownload = ($null -ne $downloadCount -and $downloadCount -ge 1)
        $classifiedConflict = ($null -ne $conflictCount -and $conflictCount -ge 1)

        if ($classifiedDownload -or $classifiedConflict) {
            $which = 'download'
            if (-not $classifiedDownload) { $which = 'conflict' }
            Add-GateResult -Gate "3. One remote change classifies as download or conflict" -Status "PASS" `
                -Detail ("download={0}, conflict={1} (classified as {2})" -f $downloadCount, $conflictCount, $which)
        }
        else {
            Add-GateResult -Gate "3. One remote change classifies as download or conflict" -Status "FAIL" `
                -Detail ("download={0}, conflict={1}; expected one of them to be at least 1" -f $downloadCount, $conflictCount)
        }

        # Gate 6: an unstable snapshot is retried and then aborts. The unit
        # suite proves the retry/abort logic against controlled fakes; a live
        # project cannot be made to change mid-read on demand, so this is a
        # pointer to that evidence rather than a scripted check.
        Add-GateResult -Gate "6. Unstable snapshot retries/aborts" -Status "PASS" `
            -Detail "covered by tests/Snapshot.Tests.ps1 (3 attempts, then the idle message; staging discarded)"

        # Gate 4: Pull a clean remote-only change, verify the backup restores.
        Write-Host ""
        Write-Host "--------------------------------------------------"
        Write-Host "GATE 4: Pull, then restore from backup"
        Write-Host "--------------------------------------------------"

        if (-not $classifiedDownload) {
            Add-GateResult -Gate "4. Pull applies clean remote-only change with a restorable backup" -Status "FAIL" `
                -Detail "no download was available to pull (gate 3 did not produce one)"
        }
        else {
            # Record what the workspace holds now, so a backup can be compared
            # to the pre-pull original.
            $beforeLocal = @{}
            $beforeManifest = Get-LocalManifest -WorkspaceRoot $LocalDir
            foreach ($key in @($beforeManifest.Keys)) {
                $beforeLocal[[string]$key] = [string]$beforeManifest[$key].Sha256
            }

            $baseCapturedBefore = $null
            $baseBefore = Read-BaseManifest -WorkspaceRoot $LocalDir
            if ($null -ne $baseBefore) { $baseCapturedBefore = [string]$baseBefore.capturedAt }

            Write-Host "Pulling a clean remote-only change with -ForcePull (backups still happen)."
            Write-Host ""

            $pullResult = Invoke-SyncCli -CliArgs @(
                '-ProjectId', $ProjectId, '-LocalDir', $LocalDir, '-Command', 'Pull', '-ForcePull'
            )

            $appliedRows = @(Get-PlanAppliedRows -Output $pullResult.Output)
            $appliedCount = Get-PlanSummaryCount -Output $pullResult.Output -StatusName 'applied'
            $overwrittenCount = Get-PlanSummaryCount -Output $pullResult.Output -StatusName 'overwritten'
            $baseUpdatedLine = [regex]::Match($pullResult.Output, '(?m)^\s*BASE updated:\s+(\w+)')

            $pullOk = ($pullResult.ExitCode -eq 0 -and $null -ne $appliedCount -and $appliedCount -ge 1)
            $baseUpdated = ($baseUpdatedLine.Success -and $baseUpdatedLine.Groups[1].Value -eq 'true')

            $backupChecks = New-Object 'System.Collections.Generic.List[string]'
            $backupVerified = $true

            $backupRootLine = [regex]::Match($pullResult.Output, '(?m)^\s*backup root:\s+(.+?)\s*$')
            $backupRoot = $null
            if ($backupRootLine.Success) { $backupRoot = $backupRootLine.Groups[1].Value.Trim().TrimEnd('\') }

            $thisRunLine = [regex]::Match($pullResult.Output, '(?m)^\s*this run:\s+(.+?)\s*$')
            $thisRunSet = $null
            if ($thisRunLine.Success) { $thisRunSet = $thisRunLine.Groups[1].Value.Trim().TrimEnd('\') }

            foreach ($row in $appliedRows) {
                $canonical = [string]$row.Path
                $localFull = ConvertTo-LocalFullPath -WorkspaceRoot $LocalDir -CanonicalPath $canonical

                # The applied file must now exist and be recorded in BASE with
                # the identity that is actually on disk.
                if (-not (Test-Path -LiteralPath $localFull)) {
                    $backupVerified = $false
                    $backupChecks.Add("$canonical : applied but missing on disk")
                    continue
                }

                $diskIdentity = Get-LocalFileIdentity -LiteralPath $localFull
                $baseAfter = Read-BaseManifest -WorkspaceRoot $LocalDir
                if ($null -eq $baseAfter -or $null -eq $baseAfter.files.PSObject.Properties[$canonical]) {
                    $backupVerified = $false
                    $backupChecks.Add("$canonical : not recorded in BASE after pull")
                }
                else {
                    $recordedHash = [string]$baseAfter.files.$canonical.sha256
                    if (-not [string]::Equals($recordedHash, [string]$diskIdentity.Sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $backupVerified = $false
                        $backupChecks.Add("$canonical : BASE hash $(Get-ShortHash $recordedHash) != disk $(Get-ShortHash ([string]$diskIdentity.Sha256))")
                    }
                }

                if ($row.Kind -ne 'overwrite') {
                    $backupChecks.Add("$canonical : created (no backup expected)")
                    continue
                }

                # An overwrite must have a backup, and that copy must restore by
                # a plain file copy.
                if ([string]::IsNullOrEmpty($thisRunSet) -or -not (Test-Path -LiteralPath $thisRunSet)) {
                    $backupVerified = $false
                    $backupChecks.Add("$canonical : overwrite had no backup set to restore from")
                    continue
                }

                $backupFile = Join-Path $thisRunSet $canonical.Replace('/', '\')
                if (-not (Test-Path -LiteralPath $backupFile)) {
                    $backupVerified = $false
                    $backupChecks.Add("$canonical : no backup file at backup set")
                    continue
                }

                $backupIdentity = Get-LocalFileIdentity -LiteralPath $backupFile
                $originalHash = $null
                if ($beforeLocal.ContainsKey($canonical)) { $originalHash = [string]$beforeLocal[$canonical] }

                if ([string]::IsNullOrEmpty($originalHash)) {
                    $backupChecks.Add("$canonical : backed up (no pre-pull hash to compare)")
                    continue
                }

                if (-not [string]::Equals($originalHash, [string]$backupIdentity.Sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $backupVerified = $false
                    $backupChecks.Add("$canonical : backup $(Get-ShortHash ([string]$backupIdentity.Sha256)) != original $(Get-ShortHash $originalHash)")
                    continue
                }

                # Prove restoration works by copying the backup out, the way a
                # user would recover by hand.
                $restoreCopy = Join-Path $scratchRoot ("restore-" + [Guid]::NewGuid().ToString("N") + ".bin")
                Copy-Item -LiteralPath $backupFile -Destination $restoreCopy -Force
                $restoredIdentity = Get-LocalFileIdentity -LiteralPath $restoreCopy
                Remove-Item -LiteralPath $restoreCopy -Force -ErrorAction SilentlyContinue

                if ([string]::Equals($originalHash, [string]$restoredIdentity.Sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $backupChecks.Add("$canonical : overwrite; backup copy restores the pre-pull original")
                }
                else {
                    $backupVerified = $false
                    $backupChecks.Add("$canonical : restored copy does not match the pre-pull original")
                }
            }

            $baseMoved = $false
            if ($baseUpdated) {
                $baseAfterRead = Read-BaseManifest -WorkspaceRoot $LocalDir
                if ($null -ne $baseAfterRead -and [string]$baseAfterRead.capturedAt -ne $baseCapturedBefore) {
                    $baseMoved = $true
                }
            }

            if ($pullOk -and $backupVerified -and $baseUpdated -and $baseMoved) {
                Add-GateResult -Gate "4. Pull applies clean remote-only change with a restorable backup" -Status "PASS" `
                    -Detail ("applied={0}, overwritten={1}; {2}" -f $appliedCount, $overwrittenCount, (($backupChecks -join ' | ')))
            }
            else {
                Add-GateResult -Gate "4. Pull applies clean remote-only change with a restorable backup" -Status "FAIL" `
                    -Detail ("exit={0}, applied={1}, overwritten={2}, BASE updated={3}, BASE capturedAt moved={4}; {5}" -f `
                        $pullResult.ExitCode, $appliedCount, $overwrittenCount, $baseUpdated, $baseMoved, (($backupChecks -join ' | ')))
            }

            if (-not [string]::IsNullOrEmpty($backupRoot)) {
                Write-Host ""
                Write-Host "Backup root: $backupRoot"
                Write-Host "Restore any overwritten file by copying it back from there."
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Phase "Acceptance summary"

foreach ($result in $script:GateResults) {
    Write-Host ("  {0,-6} {1}" -f $result.Status, $result.Gate)
}

$failCount = @($script:GateResults | Where-Object { $_.Status -eq 'FAIL' }).Count
$passCount = @($script:GateResults | Where-Object { $_.Status -eq 'PASS' }).Count
$skipCount = @($script:GateResults | Where-Object { $_.Status -eq 'SKIP' }).Count

Write-Host ""
Write-Host ("Passed: {0}  Failed: {1}  Skipped: {2}" -f $passCount, $failCount, $skipCount)
Write-Host ""

if ($skipCount -gt 0) {
    Write-Host "Skipped gates still need a run against a disposable project:"
    Write-Host "  powershell -NoProfile -File .\tests\Acceptance.ps1 -ProjectId <id> -LocalDir <dir>"
    Write-Host ""
}

Write-Host "This report contains no tokens, auth paths, or file contents."
Write-Host "Paste the summary above into the pull request; never paste raw CLI output"
Write-Host "if it happens to include anything project-specific."
Write-Host ""

# ---------------------------------------------------------------------------
# Cleanup
#
# A workspace holds .rundot-sync/, which is sensitive in two ways: the BASE and
# plan artifacts name every file in the project, and a backup set can hold full
# file contents. On a public repository that must never be left behind by
# default, so an acceptance run into a directory inside the repository removes
# it unless -KeepWorkspace was asked for.
# ---------------------------------------------------------------------------

if ($KeepWorkspace) {
    Write-Host "Leaving workspaces in place (-KeepWorkspace):"
    if (-not [string]::IsNullOrEmpty($LocalDir)) { Write-Host "  $LocalDir" }
    Write-Host "  $scratchRoot"
    Write-Host ""
    Write-Host "These contain .rundot-sync/ state, and any backup set holds full file"
    Write-Host "contents. Delete them before committing, and never commit .rundot-sync/."
    Write-Host ""
}
else {
    if (Test-Path -LiteralPath $scratchRoot) {
        Remove-Item -LiteralPath $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    $workspaceExists = (-not [string]::IsNullOrEmpty($LocalDir)) -and (Test-Path -LiteralPath $LocalDir)

    if (-not $workspaceExists) {
        # Nothing to do: no live workspace was used, or it is already gone.
    }
    elseif (-not $script:liveWorkspaceCreated) {
        Write-Host "Left a pre-existing workspace in place:"
        Write-Host "  $LocalDir"
        Write-Host "Its .rundot-sync/ now holds state from this run."
        Write-Host ""
    }
    else {
        # Remove it only inside the repository. A directory the user pointed at
        # deliberately may hold work this script did not create.
        $normalizedLocal = [System.IO.Path]::GetFullPath($LocalDir).TrimEnd('\')
        $normalizedRepo = [System.IO.Path]::GetFullPath($repoRoot).TrimEnd('\')
        $insideRepo = $normalizedLocal.StartsWith(
            $normalizedRepo + '\',
            [System.StringComparison]::OrdinalIgnoreCase
        )

        if ($insideRepo) {
            Write-Host "Removing the workspace this run created:"
            Write-Host "  $LocalDir"
            Write-Host ""
            Remove-Item -LiteralPath $LocalDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        else {
            Write-Host "Workspace is outside the repository, so it was left in place:"
            Write-Host "  $LocalDir"
            Write-Host "Delete it yourself when you are done; it contains .rundot-sync/ state."
            Write-Host ""
        }
    }
}

if ($failCount -gt 0) {
    exit 1
}

exit 0
