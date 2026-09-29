# Automatic live round-trip: setup -> up -> down -> restore -> teardown.
#
#   powershell -NoProfile -File .\tests\Live-RoundTrip.ps1 -ProjectId <id>
#
# Unlike tests/Acceptance.ps1, this script makes its own Studio-side change, so
# it needs no manual edit and no Read-Host pause. Every product step runs the
# real CLI in a child process; the only direct library calls are the two
# documented Studio write routes the product already owns, used to act as a
# separate client:
#
#   * Studio-side edit fixture -> Invoke-RemoteTextPut    (PUT /file)
#   * cleanup                  -> Invoke-RemoteDeleteFile (DELETE /file)
#
# The product creates its own probe files through the CLI (`Push` text create),
# so no new Studio write route is introduced. Everything the run makes lives
# under one GUID probe folder, so teardown deletes exactly what it created and
# proves the paths are gone.
#
# Named Live-RoundTrip.ps1, not *.Tests.ps1, so tests/Run-Tests.ps1 does not
# pick it up: it needs a real account and network.
#
# Use a DISPOSABLE project. The script never prints tokens, auth paths, or file
# contents.

param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectId,

    # Workspace. Defaults to a temp scratch dir, removed at the end.
    [string]$LocalDir,

    # Leave the workspace and backups in place for inspection.
    [switch]$KeepWorkspace,

    # Do not DELETE the probe files from Studio at the end.
    [switch]$SkipRemoteCleanup
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$syncCli = Join-Path $repoRoot 'game-studio-sync.ps1'
$StudioOrigin = 'https://venus-studio-prod.series-ai.workers.dev'

. (Join-Path $repoRoot 'lib\Paths.ps1')
. (Join-Path $repoRoot 'lib\Ignore.ps1')
. (Join-Path $repoRoot 'lib\Hashing.ps1')
. (Join-Path $repoRoot 'lib\Progress.ps1')
. (Join-Path $repoRoot 'lib\Workspace.ps1')
. (Join-Path $repoRoot 'lib\Manifest.ps1')
. (Join-Path $repoRoot 'lib\RemoteApi.ps1')
. (Join-Path $repoRoot 'lib\Auth.ps1')
. (Join-Path $repoRoot 'lib\Snapshot.ps1')
. (Join-Path $repoRoot 'lib\RemoteWrite.ps1')
. (Join-Path $repoRoot 'lib\RemoteDelete.ps1')

$script:Steps = New-Object 'System.Collections.Generic.List[object]'
$script:WorkspaceCreated = $false
$script:ProbePaths = @()

# ---------------------------------------------------------------------------
# Reporting and CLI helpers
# ---------------------------------------------------------------------------

function Add-Step {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Status,
        [string]$Detail = ''
    )

    $script:Steps.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
    Write-Host ("  [{0}] {1}" -f $Status, $Name)
    if (-not [string]::IsNullOrEmpty($Detail)) {
        Write-Host ("         {0}" -f $Detail)
    }
}

function Write-Phase {
    param([string]$Text)

    Write-Host ''
    Write-Host '=================================================='
    Write-Host $Text
    Write-Host '=================================================='
}

function Invoke-SyncCli {
    param([string[]]$CliArgs, [switch]$NonInteractive)

    $psArgs = @('-NoProfile')
    if ($NonInteractive) { $psArgs += '-NonInteractive' }
    $psArgs += @('-File', $syncCli)
    $psArgs += $CliArgs

    $lines = & powershell @psArgs 2>&1
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = 0 }

    return [pscustomobject]@{ Output = ($lines | Out-String); ExitCode = [int]$code }
}

function Get-PlanCount {
    param([string]$Output, [string]$StatusName)

    $match = [regex]::Match($Output, ('(?m)^\s*' + [regex]::Escape($StatusName) + ':\s+(\d+)'))
    if ($match.Success) { return [int]$match.Groups[1].Value }
    return -1
}

function Get-ReportBackupSetPath {
    param([string]$Output)

    $match = [regex]::Match($Output, '(?m)^\s*this run:\s+(.+?)\s*$')
    if ($match.Success) { return $match.Groups[1].Value.Trim() }
    return $null
}

function Assert-ProgressLines {
    # The #43 contract: a plain start line and a plain final line for hashing and
    # download, and a per-path publish line for a multi-file write. Asserted on
    # captured CLI output, so it holds for every command that emits them.
    #
    # -RequireHashing is off for Init -InitMode FromRemote, which downloads into
    # an empty destination and so has no local tree to hash; Adopt hashes one.
    param(
        [Parameter(Mandatory)][string]$Output,
        [Parameter(Mandatory)][string]$Label,
        [switch]$RequirePublish,
        [switch]$RequireHashing
    )

    $missing = New-Object 'System.Collections.Generic.List[string]'

    if ($RequireHashing) {
        if ($Output -notmatch '(?m)^Hashing local files:') { [void]$missing.Add('hashing start') }
        if ($Output -notmatch '(?m)^Hashed \d+ local file\(s\)\.') { [void]$missing.Add('hashing final') }
    }
    if ($Output -notmatch '(?m)^Downloading \d+ remote file\(s\)\.\.\.') { [void]$missing.Add('download start') }
    if ($Output -notmatch '(?m)^Downloaded \d+ remote file\(s\)\.') { [void]$missing.Add('download final') }
    if ($RequirePublish -and $Output -notmatch '(?m)^(Publishing|Backing up|Writing) \d+ of \d+:') {
        [void]$missing.Add('publish per-path line')
    }

    if ($missing.Count -eq 0) {
        Add-Step -Name ("progress lines: {0}" -f $Label) -Status 'PASS'
        return $true
    }

    Add-Step -Name ("progress lines: {0}" -f $Label) -Status 'FAIL' `
        -Detail ('missing: ' + ($missing -join ', '))
    return $false
}

function Test-BytesEqual {
    param([byte[]]$Left, [byte[]]$Right)

    if ($null -eq $Left -or $null -eq $Right) { return $false }
    if ($Left.Length -ne $Right.Length) { return $false }

    for ($i = 0; $i -lt $Left.Length; $i++) {
        if ($Left[$i] -ne $Right[$i]) { return $false }
    }
    return $true
}

# ---------------------------------------------------------------------------
# Scratch workspace
# ---------------------------------------------------------------------------

$scratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    'rundot-live-roundtrip-' + [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Force -Path $scratchRoot | Out-Null

if ([string]::IsNullOrEmpty($LocalDir)) {
    $LocalDir = Join-Path $scratchRoot 'live-workspace'
}
if (-not [System.IO.Path]::IsPathRooted($LocalDir)) {
    $LocalDir = Join-Path $repoRoot $LocalDir
}
$LocalDir = [System.IO.Path]::GetFullPath($LocalDir)
if (-not (Test-Path -LiteralPath $LocalDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null
    $script:WorkspaceCreated = $true
}

$utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Write-ProbeFile {
    param(
        [Parameter(Mandatory)][string]$CanonicalPath,
        [Parameter(Mandatory)][string]$Text
    )

    $full = ConvertTo-LocalFullPath -WorkspaceRoot $LocalDir -CanonicalPath $CanonicalPath
    $parent = Split-Path -Parent $full
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    [System.IO.File]::WriteAllText($full, $Text, $utf8NoBom)
}

function Get-ProbeSha {
    param([Parameter(Mandatory)][string]$CanonicalPath)

    $full = ConvertTo-LocalFullPath -WorkspaceRoot $LocalDir -CanonicalPath $CanonicalPath
    return (Get-LocalFileIdentity -LiteralPath $full).Sha256
}

function Get-ProbeBytes {
    param([Parameter(Mandatory)][string]$CanonicalPath)

    $full = ConvertTo-LocalFullPath -WorkspaceRoot $LocalDir -CanonicalPath $CanonicalPath
    return [System.IO.File]::ReadAllBytes($full)
}

# ---------------------------------------------------------------------------
# Authentication
# ---------------------------------------------------------------------------

Write-Phase 'Live round-trip: authentication'

try {
    $auth = Get-RundotAccessToken `
        -StudioOrigin $StudioOrigin `
        -ProjectId $ProjectId `
        -AuthDir (Join-Path $env:APPDATA '.rundot') `
        -AuthPath (Join-Path $env:APPDATA '.rundot\studio-export.auth.json') `
        -RundotCliSessionPath (Join-Path $env:APPDATA '.rundot\prod.session.json')
}
catch {
    Write-Host ''
    Write-Host ('Authentication failed: ' + $_.Exception.Message)
    Write-Host ''
    if (Test-Path -LiteralPath $scratchRoot) {
        Remove-Item -LiteralPath $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    exit 1
}

$headers = @{
    Authorization = "Bearer $($auth.AccessToken)"
    Accept        = '*/*'
}

Add-Step -Name 'Studio authentication' -Status 'PASS'

# ---------------------------------------------------------------------------
# Setup: Init FromRemote into the empty workspace
# ---------------------------------------------------------------------------

Write-Phase 'Setup'

$probeFolder = 'sync-live/' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$probeA = $probeFolder + '/probe-a.txt'
$probeB = $probeFolder + '/probe-b.txt'
$script:ProbePaths = @($probeA, $probeB)

$initResult = Invoke-SyncCli -CliArgs @(
    '-ProjectId', $ProjectId, '-LocalDir', $LocalDir,
    '-Command', 'Init', '-InitMode', 'FromRemote'
)
$basePath = Join-Path $LocalDir '.rundot-sync\base-manifest.json'
$initOk = ($initResult.ExitCode -eq 0) -and (Test-Path -LiteralPath $basePath)
Add-Step -Name 'Init -InitMode FromRemote' -Status $(if ($initOk) { 'PASS' } else { 'FAIL' }) `
    -Detail ("exit={0}" -f $initResult.ExitCode)
[void](Assert-ProgressLines -Output $initResult.Output -Label 'Init FromRemote')

# Adopt hashes the whole existing tree before it prints anything; that is the
# case #43 is about. A separate throwaway tree keeps the round-trip workspace
# untouched, and Adopt is GET-only, so it mutates nothing on Studio.
$adoptDir = Join-Path $scratchRoot 'adopt-workspace'
New-Item -ItemType Directory -Force -Path $adoptDir | Out-Null
[System.IO.File]::WriteAllText((Join-Path $adoptDir 'a.txt'), "adopt probe`n", $utf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $adoptDir 'b.txt'), "adopt probe 2`n", $utf8NoBom)

$adoptResult = Invoke-SyncCli -CliArgs @(
    '-ProjectId', $ProjectId, '-LocalDir', $adoptDir, '-Command', 'Init', '-InitMode', 'Adopt'
)
$adoptOk = ($adoptResult.ExitCode -eq 0)
Add-Step -Name 'Init -InitMode Adopt on an existing tree' `
    -Status $(if ($adoptOk) { 'PASS' } else { 'FAIL' }) `
    -Detail ("exit={0}" -f $adoptResult.ExitCode)
[void](Assert-ProgressLines -Output $adoptResult.Output -Label 'Init Adopt' -RequireHashing)

$script:Aborted = -not $initOk
# ---------------------------------------------------------------------------
# UP: create both probe files locally, publish them with Push
# ---------------------------------------------------------------------------

if (-not $script:Aborted) {
    Write-Phase 'Up (Push: local -> Studio)'

    # New utf8 text files. Push publishes these through the documented create
    # sequence, so the harness never issues a create route itself.
    $createAText = "live round-trip probe A`n"
    $createBText = "live round-trip probe B`n"
    Write-ProbeFile -CanonicalPath $probeA -Text $createAText
    Write-ProbeFile -CanonicalPath $probeB -Text $createBText
    $createdASha = Get-ProbeSha -CanonicalPath $probeA

    $planCreate = Invoke-SyncCli -CliArgs @(
        '-ProjectId', $ProjectId, '-LocalDir', $LocalDir, '-Command', 'Plan'
    )
    [void](Assert-ProgressLines -Output $planCreate.Output -Label 'Plan (create)' -RequireHashing)

    $createUploads = Get-PlanCount -Output $planCreate.Output -StatusName 'upload'
    Add-Step -Name 'Plan sees the two new probe files as uploads' `
        -Status $(if ($createUploads -ge 2) { 'PASS' } else { 'FAIL' }) `
        -Detail ("upload rows = {0}" -f $createUploads)

    $pushCreate = Invoke-SyncCli -CliArgs @(
        '-ProjectId', $ProjectId, '-LocalDir', $LocalDir, '-Command', 'Push', '-ForcePush'
    )
    [void](Assert-ProgressLines -Output $pushCreate.Output -Label 'Push (create)' -RequirePublish -RequireHashing)

    $created = Get-PlanCount -Output $pushCreate.Output -StatusName 'created'
    $createBaseUpdated = [regex]::IsMatch($pushCreate.Output, '(?m)^\s*BASE updated:\s+true\s*$')
    $createOk = ($pushCreate.ExitCode -eq 0) -and ($created -ge 2) -and $createBaseUpdated
    Add-Step -Name 'Push -ForcePush created both probe files' `
        -Status $(if ($createOk) { 'PASS' } else { 'FAIL' }) `
        -Detail ("exit={0}, created={1}, BASE updated={2}" -f $pushCreate.ExitCode, $created, $createBaseUpdated)

    # The remote bytes must now be the local bytes we published.
    $remoteA = Get-RemoteProjectFile `
        -StudioOrigin $StudioOrigin -ProjectId $ProjectId `
        -Path ('/' + $probeA) -Headers $headers
    $remoteASha = Get-RemoteFileContentSha256 -Response $remoteA
    $createVerified = [string]::Equals($remoteASha, $createdASha, [System.StringComparison]::Ordinal)
    Add-Step -Name 'Studio now serves the created bytes' `
        -Status $(if ($createVerified) { 'PASS' } else { 'FAIL' }) `
        -Detail ("remote sha={0}, local sha={1}" -f $remoteASha.Substring(0, 8), $createdASha.Substring(0, 8))

    # Now a clean overwrite of both: BASE=A, LOCAL=B, REMOTE=A.
    $upAText = "live round-trip probe A (published)`n"
    $upBText = "live round-trip probe B (published)`n"
    Write-ProbeFile -CanonicalPath $probeA -Text $upAText
    Write-ProbeFile -CanonicalPath $probeB -Text $upBText
    $upASha = Get-ProbeSha -CanonicalPath $probeA

    $planUp = Invoke-SyncCli -CliArgs @(
        '-ProjectId', $ProjectId, '-LocalDir', $LocalDir, '-Command', 'Plan'
    )
    [void](Assert-ProgressLines -Output $planUp.Output -Label 'Plan (overwrite)' -RequireHashing)

    $upRows = Get-PlanCount -Output $planUp.Output -StatusName 'upload'
    Add-Step -Name 'Plan sees the two edits as overwrites' `
        -Status $(if ($upRows -ge 2) { 'PASS' } else { 'FAIL' }) `
        -Detail ("upload rows = {0}" -f $upRows)

    $pushUp = Invoke-SyncCli -CliArgs @(
        '-ProjectId', $ProjectId, '-LocalDir', $LocalDir, '-Command', 'Push', '-ForcePush'
    )
    [void](Assert-ProgressLines -Output $pushUp.Output -Label 'Push (overwrite)' -RequirePublish -RequireHashing)

    $applied = Get-PlanCount -Output $pushUp.Output -StatusName 'applied'
    $upBaseUpdated = [regex]::IsMatch($pushUp.Output, '(?m)^\s*BASE updated:\s+true\s*$')
    $upOk = ($pushUp.ExitCode -eq 0) -and ($applied -ge 2) -and $upBaseUpdated
    Add-Step -Name 'Push -ForcePush published both overwrites' `
        -Status $(if ($upOk) { 'PASS' } else { 'FAIL' }) `
        -Detail ("exit={0}, applied={1}, BASE updated={2}" -f $pushUp.ExitCode, $applied, $upBaseUpdated)

    $remoteA2 = Get-RemoteProjectFile `
        -StudioOrigin $StudioOrigin -ProjectId $ProjectId `
        -Path ('/' + $probeA) -Headers $headers
    $remoteA2Sha = Get-RemoteFileContentSha256 -Response $remoteA2
    $upVerified = [string]::Equals($remoteA2Sha, $upASha, [System.StringComparison]::Ordinal)
    Add-Step -Name 'Studio serves the published overwrite bytes' `
        -Status $(if ($upVerified) { 'PASS' } else { 'FAIL' }) `
        -Detail ("remote sha={0}, local sha={1}" -f $remoteA2Sha.Substring(0, 8), $upASha.Substring(0, 8))

    # -----------------------------------------------------------------------
    # DOWN: a Studio-side edit, pulled with Pull
    # -----------------------------------------------------------------------

    Write-Phase 'Down (Pull: Studio -> local)'

    # Act as a separate Studio client using the documented PUT /file route,
    # which is overwrite-only. The probe files exist now, so this succeeds.
    $downText = "live round-trip probe A (remote edit)`n"
    [void](Invoke-RemoteTextPut `
        -StudioOrigin $StudioOrigin -ProjectId $ProjectId `
        -CanonicalPath $probeA -Text $downText -Headers $headers)
    Add-Step -Name 'Studio-side edit: rewrite probe A on Studio' -Status 'PASS'

    $localBeforePullSha = Get-ProbeSha -CanonicalPath $probeA
    $localBeforePullBytes = Get-ProbeBytes -CanonicalPath $probeA

    $planDown = Invoke-SyncCli -CliArgs @(
        '-ProjectId', $ProjectId, '-LocalDir', $LocalDir, '-Command', 'Plan'
    )
    [void](Assert-ProgressLines -Output $planDown.Output -Label 'Plan (download)' -RequireHashing)

    $downloadRows = Get-PlanCount -Output $planDown.Output -StatusName 'download'
    Add-Step -Name 'Plan sees the Studio edit as a clean download' `
        -Status $(if ($downloadRows -ge 1) { 'PASS' } else { 'FAIL' }) `
        -Detail ("download rows = {0}" -f $downloadRows)

    $pullDown = Invoke-SyncCli -CliArgs @(
        '-ProjectId', $ProjectId, '-LocalDir', $LocalDir, '-Command', 'Pull', '-ForcePull'
    )
    [void](Assert-ProgressLines -Output $pullDown.Output -Label 'Pull (download)' -RequirePublish -RequireHashing)

    $pullApplied = Get-PlanCount -Output $pullDown.Output -StatusName 'applied'
    $pullOk = ($pullDown.ExitCode -eq 0) -and ($pullApplied -ge 1)
    Add-Step -Name 'Pull -ForcePull applied the remote edit' `
        -Status $(if ($pullOk) { 'PASS' } else { 'FAIL' }) `
        -Detail ("exit={0}, applied={1}" -f $pullDown.ExitCode, $pullApplied)

    $expectedRemoteBytes = $utf8NoBom.GetBytes($downText)
    $localAfterPullBytes = Get-ProbeBytes -CanonicalPath $probeA
    $downVerified = Test-BytesEqual -Left $localAfterPullBytes -Right $expectedRemoteBytes
    Add-Step -Name 'Local file now holds the Studio bytes' `
        -Status $(if ($downVerified) { 'PASS' } else { 'FAIL' }) `
        -Detail ("bytes={0}, expected={1}" -f $localAfterPullBytes.Length, $expectedRemoteBytes.Length)

    # -----------------------------------------------------------------------
    # RESTORE: the Pull backup set must reproduce the pre-pull local bytes
    # -----------------------------------------------------------------------

    Write-Phase 'Restore from backup'

    $pullBackupSetPath = Get-ReportBackupSetPath -Output $pullDown.Output
    $restoreOk = $false
    $restoreDetail = 'no backup set path found in the Pull output'
    $backupBytes = $null

    if (-not [string]::IsNullOrEmpty($pullBackupSetPath) -and (Test-Path -LiteralPath $pullBackupSetPath)) {
        $backupFile = Join-Path $pullBackupSetPath ($probeA.Replace('/', '\'))
        if (Test-Path -LiteralPath $backupFile -PathType Leaf) {
            $backupBytes = [System.IO.File]::ReadAllBytes($backupFile)
            $restoreOk = Test-BytesEqual -Left $backupBytes -Right $localBeforePullBytes
            $restoreDetail = "backup matches the pre-pull local bytes ({0} bytes)" -f $backupBytes.Length
        }
        else {
            $restoreDetail = "backup file missing: $backupFile"
        }
    }

    Add-Step -Name 'Pull backup restores the overwritten original' `
        -Status $(if ($restoreOk) { 'PASS' } else { 'FAIL' }) -Detail $restoreDetail

    if ($restoreOk) {
        # A plain copy out of the backup set must put the original back.
        $probeAFull = ConvertTo-LocalFullPath -WorkspaceRoot $LocalDir -CanonicalPath $probeA
        [System.IO.File]::WriteAllBytes($probeAFull, $backupBytes)
        $restoredSha = Get-ProbeSha -CanonicalPath $probeA
        $copyRestoreOk = [string]::Equals($restoredSha, $localBeforePullSha, [System.StringComparison]::Ordinal)
        Add-Step -Name 'Copying the backup back restores the original hash' `
            -Status $(if ($copyRestoreOk) { 'PASS' } else { 'FAIL' }) `
            -Detail ("restored sha={0}, original sha={1}" -f $restoredSha.Substring(0, 8), $localBeforePullSha.Substring(0, 8))
    }

    # -----------------------------------------------------------------------
    # Push-side backup: the overwrite in the UP phase must have backed up the
    # previous remote bytes before the PUT.
    # -----------------------------------------------------------------------

    Write-Phase 'Push backup evidence'

    $pushBackupSetPath = Get-ReportBackupSetPath -Output $pushUp.Output
    $pushBackupOk = $false
    $pushBackupDetail = 'no backup set path found in the Push output'

    if (-not [string]::IsNullOrEmpty($pushBackupSetPath) -and (Test-Path -LiteralPath $pushBackupSetPath)) {
        $pushBackupFile = Join-Path $pushBackupSetPath ($probeA.Replace('/', '\'))
        if (Test-Path -LiteralPath $pushBackupFile -PathType Leaf) {
            $pushBackupBytes = [System.IO.File]::ReadAllBytes($pushBackupFile)
            # The backup holds the PRE-overwrite remote bytes (the create text),
            # not the published overwrite bytes.
            $createBytes = $utf8NoBom.GetBytes($createAText)
            $pushBackupOk = Test-BytesEqual -Left $pushBackupBytes -Right $createBytes
            $pushBackupDetail = "backup holds the pre-overwrite remote bytes ({0} bytes)" -f $pushBackupBytes.Length
        }
        else {
            $pushBackupDetail = "backup file missing: $pushBackupFile"
        }
    }

    Add-Step -Name 'Push backup holds the previous remote bytes' `
        -Status $(if ($pushBackupOk) { 'PASS' } else { 'FAIL' }) -Detail $pushBackupDetail

    # -----------------------------------------------------------------------
    # Fail-closed with progress on: a locked local file still aborts Plan
    # -----------------------------------------------------------------------

    Write-Phase 'Fail-closed with progress on'

    $lockTarget = ConvertTo-LocalFullPath -WorkspaceRoot $LocalDir -CanonicalPath $probeA
    $lockStream = [System.IO.File]::Open(
        $lockTarget,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    try {
        $lockedPlan = Invoke-SyncCli -CliArgs @(
            '-ProjectId', $ProjectId, '-LocalDir', $LocalDir, '-Command', 'Plan'
        )
    }
    finally {
        $lockStream.Dispose()
    }

    $failClosedOk = ($lockedPlan.ExitCode -ne 0) `
        -and ($lockedPlan.Output -match '(?m)^Hashing local files:') `
        -and ($lockedPlan.Output -match '(?i)Unable to read')
    Add-Step -Name 'A locked local file still aborts Plan (progress does not soften it)' `
        -Status $(if ($failClosedOk) { 'PASS' } else { 'FAIL' }) `
        -Detail ("exit={0}" -f $lockedPlan.ExitCode)
}

# ---------------------------------------------------------------------------
# Teardown: delete the probe files from Studio, then remove the workspace
# ---------------------------------------------------------------------------

Write-Phase 'Teardown'

if ($SkipRemoteCleanup) {
    Add-Step -Name 'Studio cleanup: delete probe files' -Status 'SKIP' -Detail '-SkipRemoteCleanup'
}
else {
    $cleanupFailed = New-Object 'System.Collections.Generic.List[string]'

    foreach ($canonical in $script:ProbePaths) {
        try {
            [void](Invoke-RemoteDeleteFile `
                -StudioOrigin $StudioOrigin `
                -ProjectId $ProjectId `
                -CanonicalPath $canonical `
                -Headers $headers)
        }
        catch {
            if (Test-RemoteNotFoundException -Exception $_.Exception) {
                # Already absent; the postcondition holds.
                continue
            }
            [void]$cleanupFailed.Add(("{0}: {1}" -f $canonical, $_.Exception.Message))
        }
    }

    # A 200 is not proof; the proof is that GET /files no longer lists them.
    try {
        $listed = @(Get-RemoteListedFilePaths `
            -StudioOrigin $StudioOrigin -ProjectId $ProjectId -Headers $headers)
        foreach ($canonical in $script:ProbePaths) {
            if ($listed -contains $canonical) {
                [void]$cleanupFailed.Add(("{0}: still listed after DELETE" -f $canonical))
            }
        }
    }
    catch {
        [void]$cleanupFailed.Add(('absence proof failed: ' + $_.Exception.Message))
    }

    if ($cleanupFailed.Count -eq 0) {
        Add-Step -Name 'Studio cleanup: probe files deleted and proven absent' -Status 'PASS' `
            -Detail $probeFolder
    }
    else {
        Add-Step -Name 'Studio cleanup: probe files deleted and proven absent' -Status 'FAIL' `
            -Detail ($cleanupFailed -join '; ')
    }
}

if ($KeepWorkspace) {
    Add-Step -Name 'Workspace cleanup' -Status 'SKIP' -Detail ('-KeepWorkspace: ' + $LocalDir)
}
else {
    if ($script:WorkspaceCreated -and (Test-Path -LiteralPath $LocalDir)) {
        Remove-Item -LiteralPath $LocalDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $scratchRoot) {
        Remove-Item -LiteralPath $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Add-Step -Name 'Workspace cleanup: scratch and workspace removed' -Status 'PASS'
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Phase 'Live round-trip summary'

foreach ($step in $script:Steps) {
    Write-Host ("  {0,-6} {1}" -f $step.Status, $step.Name)
}

$failCount = @($script:Steps | Where-Object { $_.Status -eq 'FAIL' }).Count
$passCount = @($script:Steps | Where-Object { $_.Status -eq 'PASS' }).Count
$skipCount = @($script:Steps | Where-Object { $_.Status -eq 'SKIP' }).Count

Write-Host ''
Write-Host ("Passed: {0}  Failed: {1}  Skipped: {2}" -f $passCount, $failCount, $skipCount)
Write-Host ''
Write-Host 'This report contains no tokens, auth paths, or file contents.'
Write-Host ''

if ($failCount -gt 0) {
    exit 1
}

exit 0

