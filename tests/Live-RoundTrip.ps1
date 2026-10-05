# Automatic live round-trip: setup -> up -> down -> restore -> delete -> teardown.
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
# and removes one through the CLI (`Push -ForcePush` delete), so no new Studio
# write route is introduced. Everything the run makes lives under one GUID probe
# folder, so teardown deletes exactly what it created and proves the paths are
# gone.
#
# Phases: setup -> up (create, overwrite) -> down (pull) -> restore from backup
# -> push-backup evidence -> delete (confirmed remote delete + backup + journal)
# -> binary create/replace -> Init #82 with oversize on Studio -> fail-closed
# -> teardown.
#
# Named Live-RoundTrip.ps1, not *.Tests.ps1, so tests/Run-Tests.ps1 does not
# pick it up: it needs a real account and network.
#
# Use a DISPOSABLE project. The script never prints tokens, auth paths, or file
# contents.

param(
    # Studio project to use. When omitted, a local-only config file is
    # consulted: .rundot-test.local.json at the repo root, then the
    # RUNDOT_TEST_PROJECT_ID environment variable.
    [string]$ProjectId,

    # Workspace. Defaults to a temp scratch dir, removed at the end.
    [string]$LocalDir,

    # Leave the workspace and backups in place for inspection.
    [switch]$KeepWorkspace,

    # Do not DELETE the probe files from Studio at the end.
    [switch]$SkipRemoteCleanup,

    # Optional real binary asset (PNG/JPG) for the binary create + replace
    # phase. The gate-15 asset is a 10-byte fake PNG, which does not exercise
    # a real image; a real asset does (#51). When omitted, the binary phase is
    # SKIPPED so the text round-trip still runs.
    [string]$BinaryAssetPath,

    # Optional second real binary asset for the replace step. When omitted, a
    # distinct variant of the create asset is used so the replace has new bytes.
    [string]$BinaryReplaceAssetPath
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$syncCli = Join-Path $repoRoot 'game-studio-sync.ps1'
$StudioOrigin = 'https://venus-studio-prod.series-ai.workers.dev'

function Resolve-LiveProjectId {
    # The project id is an identifier, not a credential, but it is still not
    # published. Read it from a git-ignored local config so it does not have to
    # be pasted on every run.
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
            # Fall through to the environment variable.
        }
    }

    $fromEnv = [string]$env:RUNDOT_TEST_PROJECT_ID
    if (-not [string]::IsNullOrWhiteSpace($fromEnv)) {
        return $fromEnv.Trim()
    }

    return $null
}

$ProjectId = Resolve-LiveProjectId -ExplicitProjectId $ProjectId
if ([string]::IsNullOrEmpty($ProjectId)) {
    Write-Host ''
    Write-Host 'No project id. Pass -ProjectId <id>, or create .rundot-test.local.json:'
    Write-Host ''
    Write-Host '  { "projectId": "<id>" }'
    Write-Host ''
    Write-Host 'or set the RUNDOT_TEST_PROJECT_ID environment variable.'
    Write-Host ''
    exit 2
}

. (Join-Path $repoRoot 'lib\Paths.ps1')
. (Join-Path $repoRoot 'lib\Ignore.ps1')
. (Join-Path $repoRoot 'lib\Hashing.ps1')
. (Join-Path $repoRoot 'lib\Progress.ps1')
. (Join-Path $repoRoot 'lib\Workspace.ps1')
. (Join-Path $repoRoot 'lib\Manifest.ps1')
. (Join-Path $repoRoot 'lib\RemoteApi.ps1')
. (Join-Path $repoRoot 'lib\Auth.ps1')
. (Join-Path $repoRoot 'lib\AuthHost.ps1')
. (Join-Path $repoRoot 'lib\Snapshot.ps1')
. (Join-Path $repoRoot 'lib\Classifier.ps1')
. (Join-Path $repoRoot 'lib\Journal.ps1')
. (Join-Path $repoRoot 'lib\RemoteWrite.ps1')
. (Join-Path $repoRoot 'lib\RemoteDelete.ps1')
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$restoredFileDefinition = (Get-Command Get-RemoteProjectFile -CommandType Function).Definition
if ($restoredFileDefinition -notmatch 'EscapeDataString') {
    throw 'tests/TestHelpers.ps1 must not shadow Get-RemoteProjectFile from lib/RemoteApi.ps1.'
}

$restoredTextDefinition = (Get-Command Invoke-Utf8TextGet -CommandType Function).Definition
if ($restoredTextDefinition -notmatch 'Read-Utf8HttpResponseBody') {
    throw 'tests/TestHelpers.ps1 must not shadow Invoke-Utf8TextGet from lib/RemoteApi.ps1.'
}

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

function Get-PlanCount {
    param([string]$Output, [string]$StatusName)

    $match = [regex]::Match($Output, ('(?m)^\s*' + [regex]::Escape($StatusName) + ':\s+(\d+)'))
    if ($match.Success) { return [int]$match.Groups[1].Value }
    return -1
}

function Get-RemoteFileContentSize {
    # Decoded byte length of a remote file payload, for failure evidence only.
    # Never prints content.
    param($Response)

    try {
        return (ConvertFrom-RemoteFileContent -Response $Response).Length
    }
    catch {
        return '<unknown>'
    }
}

function Write-LiveBinaryEvidence {
    # One actionable evidence block after a binary place refusal (#51). It
    # prints sizes, an encoding, and a truncated hash, never file contents.
    param(
        [string]$Output,
        [string]$StudioOrigin,
        [string]$ProjectId,
        [hashtable]$Headers,
        [string]$CanonicalPath,
        [string]$LocalSha256
    )

    $refusedLine = [regex]::Match($Output, '(?m)^\s+(\S.*?)\s+\[[^\]]+\]\s+(.+?)\s*$')
    $reason = '<no REFUSED row>'
    if ($refusedLine.Success) { $reason = $refusedLine.Groups[2].Value }

    $remoteEncoding = '<unreadable>'
    $remoteSize = '<unreadable>'
    $remoteSha = '<unreadable>'
    try {
        $remote = Get-RemoteProjectFile `
            -StudioOrigin $StudioOrigin -ProjectId $ProjectId `
            -Path ('/' + $CanonicalPath) -Headers $Headers
        $remoteEncoding = [string](Get-SyncEntryProperty -Entry $remote -Names @('encoding', 'Encoding'))
        $remoteSize = Get-RemoteFileContentSize -Response $remote
        $remoteSha = Get-RemoteFileContentSha256 -Response $remote
    }
    catch {
        $remoteEncoding = '<absent>'
    }

    $bytesEqual = [string]::Equals($remoteSha, $LocalSha256, [System.StringComparison]::Ordinal)
    Add-Step -Name 'Binary failure evidence' -Status 'FAIL' `
        -Detail ("reason={0} | remote encoding={1} size={2} sha={3} | local sha={4} | bytesEqual={5}" -f `
            $reason, $remoteEncoding, $remoteSize, (Get-ShortHash $remoteSha), (Get-ShortHash $LocalSha256), $bytesEqual)
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
        -RundotCliSessionPath (Join-Path $env:APPDATA '.rundot\prod.session.json') `
        -WriteStatus ${function:Write-RundotAuthStatusLine} `
        -ReadManualToken ${function:Read-RundotManualBearerToken}
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
    # DELETE: a confirmed Push removes one remote file (#39)
    #
    # Probe B was created and overwritten in the UP phase, so BASE, LOCAL, and
    # REMOTE all agree on it. Removing the LOCAL copy leaves a clean
    # deleteRemoteCandidate (BASE=A, LOCAL=-, REMOTE=A). Default Push must fail
    # closed non-interactively; Push -ForcePush applies the documented
    # DELETE /file route, backs up the previous remote bytes, drops the path
    # from BASE, and proves it absent from GET /files.
    # -----------------------------------------------------------------------

    Write-Phase 'Delete (Push: remote delete)'

    $probeBFull = ConvertTo-LocalFullPath -WorkspaceRoot $LocalDir -CanonicalPath $probeB
    $probeBRemoteSha = (Get-ProbeSha -CanonicalPath $probeB)
    Remove-Item -LiteralPath $probeBFull -Force

    $planDelete = Invoke-SyncCli -CliArgs @(
        '-ProjectId', $ProjectId, '-LocalDir', $LocalDir, '-Command', 'Plan'
    )
    [void](Assert-ProgressLines -Output $planDelete.Output -Label 'Plan (delete)' -RequireHashing)

    $deleteRows = Get-PlanCount -Output $planDelete.Output -StatusName 'deleteRemoteCandidate'
    Add-Step -Name 'Plan sees the removed local file as a delete candidate' `
        -Status $(if ($deleteRows -ge 1) { 'PASS' } else { 'FAIL' }) `
        -Detail ("deleteRemoteCandidate rows = {0}" -f $deleteRows)

    # A non-interactive default Push has no console to confirm on, so it must
    # refuse before any DELETE.
    $deleteDeclined = Invoke-SyncCli -NonInteractive -CliArgs @(
        '-ProjectId', $ProjectId, '-LocalDir', $LocalDir, '-Command', 'Push'
    )
    $deleteStillListed = @(Get-RemoteListedFilePaths `
        -StudioOrigin $StudioOrigin -ProjectId $ProjectId -Headers $headers) -contains $probeB
    $declineOk = ($deleteDeclined.ExitCode -ne 0) -and $deleteStillListed
    Add-Step -Name 'Push without force refused the delete (file still listed)' `
        -Status $(if ($declineOk) { 'PASS' } else { 'FAIL' }) `
        -Detail ("exit={0}, still listed={1}" -f $deleteDeclined.ExitCode, $deleteStillListed)

    # The real delete. Push re-reads remote, verifies expectedRemoteHash,
    # backs up the previous remote bytes, sends DELETE, then proves absence.
    $pushDelete = Invoke-SyncCli -CliArgs @(
        '-ProjectId', $ProjectId, '-LocalDir', $LocalDir, '-Command', 'Push', '-ForcePush'
    )
    [void](Assert-ProgressLines -Output $pushDelete.Output -Label 'Push (delete)' -RequirePublish -RequireHashing)

    $deletedCount = Get-PlanCount -Output $pushDelete.Output -StatusName 'deleted'
    $deleteBaseUpdated = [regex]::IsMatch($pushDelete.Output, '(?m)^\s*BASE updated:\s+true\s*$')
    $deleteListedAfter = @(Get-RemoteListedFilePaths `
        -StudioOrigin $StudioOrigin -ProjectId $ProjectId -Headers $headers) -contains $probeB
    $deleteOk = ($pushDelete.ExitCode -eq 0) -and ($deletedCount -ge 1) `
        -and $deleteBaseUpdated -and (-not $deleteListedAfter)
    Add-Step -Name 'Push -ForcePush deleted the remote file and proved it absent' `
        -Status $(if ($deleteOk) { 'PASS' } else { 'FAIL' }) `
        -Detail ("exit={0}, deleted={1}, BASE updated={2}, still listed={3}" -f `
            $pushDelete.ExitCode, $deletedCount, $deleteBaseUpdated, $deleteListedAfter)

    # The delete backup must hold the pre-delete remote bytes, which are the
    # overwrite bytes the UP phase published for probe B.
    $deleteBackupSetPath = Get-ReportBackupSetPath -Output $pushDelete.Output
    $deleteBackupOk = $false
    $deleteBackupDetail = 'no backup set path found in the Push output'
    if (-not [string]::IsNullOrEmpty($deleteBackupSetPath) -and (Test-Path -LiteralPath $deleteBackupSetPath)) {
        $deleteBackupFile = Join-Path $deleteBackupSetPath ($probeB.Replace('/', '\'))
        if (Test-Path -LiteralPath $deleteBackupFile -PathType Leaf) {
            $deleteBackupSha = (Get-LocalFileIdentity -LiteralPath $deleteBackupFile).Sha256
            $deleteBackupOk = [string]::Equals($deleteBackupSha, $probeBRemoteSha, [System.StringComparison]::Ordinal)
            $deleteBackupDetail = "backup sha={0}, pre-delete remote sha={1}" -f `
                $deleteBackupSha.Substring(0, 8), $probeBRemoteSha.Substring(0, 8)
        }
        else {
            $deleteBackupDetail = "backup file missing: $deleteBackupFile"
        }
    }
    Add-Step -Name 'Delete backup holds the pre-delete remote bytes' `
        -Status $(if ($deleteBackupOk) { 'PASS' } else { 'FAIL' }) -Detail $deleteBackupDetail

    # The journal must record the delete as metadata only, with no secrets.
    $deleteJournalOk = $false
    $deleteJournalDetail = 'no push-delete record found'
    $journalPath = Join-Path $LocalDir '.rundot-sync\journal.jsonl'
    if (Test-Path -LiteralPath $journalPath -PathType Leaf) {
        $journalText = [System.IO.File]::ReadAllText($journalPath)
        $hasDeleteRecord = $journalText -match ('"event":"push-delete".*?"path":"' + [regex]::Escape($probeB) + '"')
        $hasSecret = $journalText -match '(?i)(bearer |refresh_token|client_secret|api[_-]?key|"content")'
        $deleteJournalOk = $hasDeleteRecord -and (-not $hasSecret)
        $deleteJournalDetail = "push-delete record={0}, secret pattern={1}" -f $hasDeleteRecord, $hasSecret
    }
    Add-Step -Name 'Journal records push-delete without secrets' `
        -Status $(if ($deleteJournalOk) { 'PASS' } else { 'FAIL' }) -Detail $deleteJournalDetail

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

    # -----------------------------------------------------------------------
    # Binary create + replace via Push -LocalWins (#51)
    #
    # The gate-15 asset is a 10-byte fake PNG, which never exercises a real
    # image. A real asset does, and a binary replace is where a post-move
    # verify can fail. The create proves the place sequence end to end; the
    # replace proves the delete-then-place path, a backup of the pre-replace
    # remote bytes, and a BASE update.
    # -----------------------------------------------------------------------

    Write-Phase 'Binary create + replace (Push -LocalWins)'

    $binaryCanonical = $probeFolder + '/binary-probe.png'

    if ([string]::IsNullOrEmpty($BinaryAssetPath) -or -not (Test-Path -LiteralPath $BinaryAssetPath -PathType Leaf)) {
        Add-Step -Name 'Binary create + replace (Push -LocalWins)' -Status 'SKIP' `
            -Detail '-BinaryAssetPath not supplied or not a file; the text round-trip still ran'
    }
    else {
        $script:ProbePaths += $binaryCanonical

        $binaryFull = ConvertTo-LocalFullPath -WorkspaceRoot $LocalDir -CanonicalPath $binaryCanonical
        $binaryParent = Split-Path -Parent $binaryFull
        if (-not (Test-Path -LiteralPath $binaryParent -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $binaryParent | Out-Null
        }

        # Exact bytes of the real asset, so a read-back hash is a byte-identity
        # claim about a real image rather than a synthetic one.
        $createBytes = [System.IO.File]::ReadAllBytes($BinaryAssetPath)
        [System.IO.File]::WriteAllBytes($binaryFull, $createBytes)
        $createIdentity = Get-LocalFileIdentity -LiteralPath $binaryFull

        if ($createIdentity.LocalDetectedKind -ne 'binary') {
            Add-Step -Name 'Binary create + replace (Push -LocalWins)' -Status 'FAIL' `
                -Detail ('-BinaryAssetPath is not a binary asset (detected {0})' -f $createIdentity.LocalDetectedKind)
        }
        else {
            # Create: Plan, then Push -LocalWins -ForcePush.
            $binaryPlanCreate = Invoke-SyncCli -CliArgs @(
                '-ProjectId', $ProjectId, '-LocalDir', $LocalDir, '-Command', 'Plan'
            )
            [void](Assert-ProgressLines -Output $binaryPlanCreate.Output -Label 'Plan (binary create)' -RequireHashing)

            $binaryCreatePush = Invoke-SyncCli -CliArgs @(
                '-ProjectId', $ProjectId, '-LocalDir', $LocalDir, '-Command', 'Push', '-LocalWins', '-ForcePush'
            )
            [void](Assert-ProgressLines -Output $binaryCreatePush.Output -Label 'Push (binary create)' -RequirePublish -RequireHashing)

            $createBinaryRows = @(Get-PushBinaryRows -Output $binaryCreatePush.Output)
            $createBaseUpdated = [regex]::IsMatch($binaryCreatePush.Output, '(?m)^\s*BASE updated:\s+true\s*$')

            $remoteCreate = Get-RemoteProjectFile `
                -StudioOrigin $StudioOrigin -ProjectId $ProjectId `
                -Path ('/' + $binaryCanonical) -Headers $headers
            $remoteCreateSha = Get-RemoteFileContentSha256 -Response $remoteCreate
            $remoteCreateEncoding = [string](Get-SyncEntryProperty `
                -Entry $remoteCreate -Names @('encoding', 'Encoding'))

            $createOk = ($binaryCreatePush.ExitCode -eq 0) `
                -and ($createBinaryRows.Count -eq 1) `
                -and ([string]$createBinaryRows[0].Mode -eq 'create') `
                -and $createBaseUpdated `
                -and [string]::Equals($remoteCreateSha, [string]$createIdentity.Sha256, [System.StringComparison]::Ordinal)

            Add-Step -Name 'Push -LocalWins placed a real binary and BASE moved' `
                -Status $(if ($createOk) { 'PASS' } else { 'FAIL' }) `
                -Detail ("exit={0}, BINARY rows={1}, BASE updated={2}, remote sha={3}, local sha={4}" -f `
                    $binaryCreatePush.ExitCode, $createBinaryRows.Count, $createBaseUpdated, `
                    (Get-ShortHash $remoteCreateSha), (Get-ShortHash ([string]$createIdentity.Sha256)))

            if (-not $createOk) {
                # Surface why, not only that it failed: a REFUSED row carries
                # the inner verify reason; a hash mismatch is the decisive
                # re-encoding evidence.
                Add-Step -Name 'Binary create failure evidence' -Status 'FAIL' `
                    -Detail ("remote encoding={0}, remote size={1}, local size={2}" -f `
                        $remoteCreateEncoding, (Get-RemoteFileContentSize -Response $remoteCreate), $createIdentity.Size)
                Add-Step -Name 'Binary replace (Push -LocalWins)' -Status 'SKIP' -Detail 'binary create failed'
            }
            else {
                # Replace: new bytes at the same path.
                $replaceSource = $BinaryReplaceAssetPath
                if ([string]::IsNullOrEmpty($replaceSource) -or -not (Test-Path -LiteralPath $replaceSource -PathType Leaf)) {
                    # A deterministic variant: flip the last byte of the create
                    # bytes so the replace has genuinely new content without
                    # needing a second real asset.
                    $replaceBytes = New-Object byte[] ($createBytes.Length)
                    [Array]::Copy($createBytes, $replaceBytes, $createBytes.Length)
                    $replaceBytes[$replaceBytes.Length - 1] = $replaceBytes[$replaceBytes.Length - 1] -bxor 0xFF
                    [System.IO.File]::WriteAllBytes($binaryFull, $replaceBytes)
                }
                else {
                    [System.IO.File]::Copy($replaceSource, $binaryFull, $true)
                }

                $replaceIdentity = Get-LocalFileIdentity -LiteralPath $binaryFull

                $binaryPlanReplace = Invoke-SyncCli -CliArgs @(
                    '-ProjectId', $ProjectId, '-LocalDir', $LocalDir, '-Command', 'Plan'
                )
                [void](Assert-ProgressLines -Output $binaryPlanReplace.Output -Label 'Plan (binary replace)' -RequireHashing)

                $binaryReplacePush = Invoke-SyncCli -CliArgs @(
                    '-ProjectId', $ProjectId, '-LocalDir', $LocalDir, '-Command', 'Push', '-LocalWins', '-ForcePush'
                )
                [void](Assert-ProgressLines -Output $binaryReplacePush.Output -Label 'Push (binary replace)' -RequirePublish -RequireHashing)

                $replaceBinaryRows = @(Get-PushBinaryRows -Output $binaryReplacePush.Output)
                $replaceBaseUpdated = [regex]::IsMatch($binaryReplacePush.Output, '(?m)^\s*BASE updated:\s+true\s*$')

                $remoteReplace = Get-RemoteProjectFile `
                    -StudioOrigin $StudioOrigin -ProjectId $ProjectId `
                    -Path ('/' + $binaryCanonical) -Headers $headers
                $remoteReplaceSha = Get-RemoteFileContentSha256 -Response $remoteReplace

                $thisRunLine = [regex]::Match($binaryReplacePush.Output, '(?m)^\s*this run:\s+(.+?)\s*$')
                $thisRunSet = $null
                if ($thisRunLine.Success) { $thisRunSet = $thisRunLine.Groups[1].Value.Trim().TrimEnd('\') }

                $replaceBackupOk = $false
                $replaceBackupDetail = 'no backup set printed'
                if (-not [string]::IsNullOrEmpty($thisRunSet) -and (Test-Path -LiteralPath $thisRunSet)) {
                    $backupFile = Join-Path $thisRunSet ($binaryCanonical.Replace('/', '\'))
                    if (Test-Path -LiteralPath $backupFile -PathType Leaf) {
                        $backupSha = (Get-LocalFileIdentity -LiteralPath $backupFile).Sha256
                        $replaceBackupOk = [string]::Equals($backupSha, [string]$createIdentity.Sha256, [System.StringComparison]::Ordinal)
                        $replaceBackupDetail = "backup holds the pre-replace remote bytes ({0})" -f (Get-ShortHash $backupSha)
                    }
                    else {
                        $replaceBackupDetail = "backup file missing: $backupFile"
                    }
                }

                $replaceJournal = @(Read-RundotSyncJournal -WorkspaceRoot $LocalDir)
                $replaceBackupRecords = @($replaceJournal | Where-Object {
                    [string]$_.event -eq 'push-backup' -and [string]$_.path -eq $binaryCanonical
                })
                $replaceBinaryRecords = @($replaceJournal | Where-Object {
                    [string]$_.event -eq 'push-binary' -and [string]$_.path -eq $binaryCanonical
                })

                $replaceOk = ($binaryReplacePush.ExitCode -eq 0) `
                    -and ($replaceBinaryRows.Count -eq 1) `
                    -and ([string]$replaceBinaryRows[0].Mode -eq 'replace') `
                    -and $replaceBaseUpdated `
                    -and [string]::Equals($remoteReplaceSha, [string]$replaceIdentity.Sha256, [System.StringComparison]::Ordinal) `
                    -and $replaceBackupOk `
                    -and ($replaceBackupRecords.Count -ge 1) `
                    -and ($replaceBinaryRecords.Count -ge 1)

                Add-Step -Name 'Push -LocalWins replaced a real binary, BASE moved, backup kept' `
                    -Status $(if ($replaceOk) { 'PASS' } else { 'FAIL' }) `
                    -Detail ("exit={0}, BINARY rows={1}, BASE updated={2}, remote sha={3}, local sha={4}; {5}" -f `
                        $binaryReplacePush.ExitCode, $replaceBinaryRows.Count, $replaceBaseUpdated, `
                        (Get-ShortHash $remoteReplaceSha), (Get-ShortHash ([string]$replaceIdentity.Sha256)), $replaceBackupDetail)

                if (-not $replaceOk) {
                    # The decisive post-move evidence: does Studio serve bytes
                    # that differ from local (re-encoding), or the same bytes
                    # with only the wrapper failing (timing/staging)?
                        $refusedLine = [regex]::Match($binaryReplacePush.Output, '(?m)^\s+(\S.*?)\s+\[[^\]]+\]\s+(.+?)\s*$')
                    Add-Step -Name 'Binary replace failure evidence' -Status 'FAIL' `
                        -Detail ("remote encoding={0}, remote size={1}, local size={2}, refused-reason={3}" -f `
                            ([string](Get-SyncEntryProperty -Entry $remoteReplace -Names @('encoding', 'Encoding'))), `
                            (Get-RemoteFileContentSize -Response $remoteReplace), `
                            $replaceIdentity.Size, `
                            $(if ($refusedLine.Success) { $refusedLine.Groups[2].Value } else { '<no REFUSED row>' }))
                }
            }
        }
    }

    # ---------------------------------------------------------------------
    # Oversize binary create (#54). A file over Studio's read limit cannot be
    # read back, so the place sequence verifies it from the presigned PUT's
    # ETag. This gate proves the whole path live: Plan keeps it applicable,
    # Push publishes it, BASE records it, and GET /files reports the size.
    # ---------------------------------------------------------------------
    $oversizeLimit = Get-SyncStudioMaxReadableFileSize
    $oversizeCanonical = $probeFolder + '/oversize-probe.bin'
    $oversizeSize = $oversizeLimit + 4096
    $oversizeFull = ConvertTo-LocalFullPath -WorkspaceRoot $LocalDir -CanonicalPath $oversizeCanonical
    $oversizeParent = Split-Path -Parent $oversizeFull
    if (-not (Test-Path -LiteralPath $oversizeParent -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $oversizeParent | Out-Null
    }

    # Deterministic bytes, so the MD5 the ETag carries is reproducible.
    $oversizeBytes = New-Object byte[] $oversizeSize
    for ($i = 0; $i -lt $oversizeSize; $i++) { $oversizeBytes[$i] = [byte](($i * 31 + 7) % 251) }
    [System.IO.File]::WriteAllBytes($oversizeFull, $oversizeBytes)
    $script:ProbePaths += $oversizeCanonical

    $oversizePlan = Invoke-SyncCli -CliArgs @(
        '-ProjectId', $ProjectId, '-LocalDir', $LocalDir, '-Command', 'Plan'
    )
    [void](Assert-ProgressLines -Output $oversizePlan.Output -Label 'Plan (oversize create)' -RequireHashing)

    $oversizePush = Invoke-SyncCli -CliArgs @(
        '-ProjectId', $ProjectId, '-LocalDir', $LocalDir, '-Command', 'Push', '-LocalWins', '-ForcePush'
    )
    [void](Assert-ProgressLines -Output $oversizePush.Output -Label 'Push (oversize create)' -RequirePublish -RequireHashing)

    $oversizeRows = @(Get-PushBinaryRows -Output $oversizePush.Output | Where-Object {
        [string]$_.Path -eq $oversizeCanonical
    })
    $oversizeBaseUpdated = [regex]::IsMatch($oversizePush.Output, '(?m)^\s*BASE updated:\s+true\s*$')

    # The remote cannot be read back, so prove presence and size from the list.
    # Get-RemoteManifestFileRows handles the manifest shape (the files property
    # name varies), so do not reach into $payload.files directly.
    $oversizeListed = $false
    $oversizeListedSize = 0
    try {
        $listedRows = @(Get-RemoteListedFilePaths `
            -StudioOrigin $StudioOrigin -ProjectId $ProjectId -Headers $headers)
        $oversizeListed = ($listedRows -contains $oversizeCanonical)

        $filesPayload = Get-RemoteProjectFileList `
            -StudioOrigin $StudioOrigin -ProjectId $ProjectId -Headers $headers
        # Get-RemoteManifestFileRows returns its list un-enumerated (return ,$rows),
        # so iterate it directly. Wrapping it in @() would yield a one-element
        # array holding the list, and every row read would come back null.
        $manifestRows = Get-RemoteManifestFileRows -Manifest $filesPayload
        foreach ($manifestRow in $manifestRows) {
            if ([string]$manifestRow.CanonicalPath -eq $oversizeCanonical) {
                $oversizeListedSize = [int64](Get-SyncEntrySizeValue -Entry $manifestRow.Entry)
            }
        }
    }
    catch { }

    $oversizeOk = ($oversizePush.ExitCode -eq 0) `
        -and ($oversizeRows.Count -eq 1) `
        -and ([string]$oversizeRows[0].Mode -eq 'create') `
        -and $oversizeBaseUpdated `
        -and $oversizeListed `
        -and ($oversizeListedSize -eq [int64]$oversizeSize)

    Add-Step -Name 'Push -LocalWins published an oversize binary create via ETag verify (#54)' `
        -Status $(if ($oversizeOk) { 'PASS' } else { 'FAIL' }) `
        -Detail ("exit={0}, BINARY rows={1}, BASE updated={2}, listed={3}, listed size={4}, local size={5}" -f `
            $oversizePush.ExitCode, $oversizeRows.Count, $oversizeBaseUpdated, $oversizeListed, $oversizeListedSize, $oversizeSize)

    if (-not $oversizeOk) {
        # Only claim a refusal when the report actually carries one; a bare
        # "nothing to push" line is not the reason and would mislead.
        $refusedRows = @([regex]::Matches($oversizePush.Output, '(?m)^\s+(\S.*?)\s+\[REFUSED\]\s+(.+?)\s*$'))
        if ($refusedRows.Count -gt 0) {
            Add-Step -Name 'Oversize create failure evidence' -Status 'FAIL' `
                -Detail ("REFUSED rows={0}; first reason={1}" -f `
                    $refusedRows.Count, $refusedRows[0].Groups[2].Value)
        }
        else {
            Add-Step -Name 'Oversize create failure evidence' -Status 'FAIL' `
                -Detail ("no REFUSED row in the report; exit={0}, binary rows={1}, listed={2}, listed size={3}" -f `
                    $oversizePush.ExitCode, $oversizeRows.Count, $oversizeListed, $oversizeListedSize)
        }
    }

    # ---------------------------------------------------------------------
    # Init FromRemote with an oversize file already on Studio (#82). The
    # reporter's failure was Init aborting after a successful snapshot when
    # spellCasting.fbx (or any >2 MB file) was listed but never staged.
    # ---------------------------------------------------------------------
    if ($oversizeOk) {
        $init82Dir = Join-Path $scratchRoot 'init-82-oversize-remote'
        if (Test-Path -LiteralPath $init82Dir) {
            Remove-Item -LiteralPath $init82Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType Directory -Force -Path $init82Dir | Out-Null

        $init82Result = Invoke-SyncCli -CliArgs @(
            '-ProjectId', $ProjectId, '-LocalDir', $init82Dir,
            '-Command', 'Init', '-InitMode', 'FromRemote'
        )
        $init82Output = [string]$init82Result.Output
        $init82BasePath = Join-Path $init82Dir '.rundot-sync\base-manifest.json'
        $init82OversizeLocal = ConvertTo-LocalFullPath `
            -WorkspaceRoot $init82Dir `
            -CanonicalPath $oversizeCanonical

        $init82Base = $null
        $init82BaseHasOversize = $false
        if (Test-Path -LiteralPath $init82BasePath) {
            $init82Base = Read-BaseManifest -WorkspaceRoot $init82Dir
            if ($null -ne $init82Base -and $null -ne $init82Base.files) {
                foreach ($prop in @($init82Base.files.PSObject.Properties)) {
                    if ([string]$prop.Name -eq $oversizeCanonical) {
                        $init82BaseHasOversize = $true
                    }
                }
            }
        }

        $init82Ok = ($init82Result.ExitCode -eq 0) `
            -and ($null -ne $init82Base) `
            -and ($init82Output -notmatch 'missing from staging') `
            -and ($init82Output -match '(?i)not downloaded') `
            -and ($init82Output -match '(?i)not tracked in BASE') `
            -and ($init82Output -match [regex]::Escape($oversizeCanonical)) `
            -and (-not (Test-Path -LiteralPath $init82OversizeLocal)) `
            -and (-not $init82BaseHasOversize)

        Add-Step -Name 'Init FromRemote into fresh dir with oversize on Studio (#82)' `
            -Status $(if ($init82Ok) { 'PASS' } else { 'FAIL' }) `
            -Detail ("exit={0}, BASE={1}, oversize local={2}, oversize in BASE={3}" -f `
                $init82Result.ExitCode, `
                ($(if ($null -ne $init82Base) { 'yes' } else { 'no' })), `
                (Test-Path -LiteralPath $init82OversizeLocal), `
                $init82BaseHasOversize)

        $plan82Result = Invoke-SyncCli -CliArgs @(
            '-ProjectId', $ProjectId, '-LocalDir', $init82Dir, '-Command', 'Plan'
        )
        $plan82Unverifiable = Get-PlanCount -Output $plan82Result.Output -StatusName 'unverifiable'
        $plan82Ok = ($plan82Result.ExitCode -eq 0) `
            -and ($plan82Unverifiable -ge 1) `
            -and ($plan82Result.Output -match [regex]::Escape($oversizeCanonical))

        Add-Step -Name 'Plan on #82 workspace lists oversize as unverifiable (#57)' `
            -Status $(if ($plan82Ok) { 'PASS' } else { 'FAIL' }) `
            -Detail ("exit={0}, unverifiable={1}" -f $plan82Result.ExitCode, $plan82Unverifiable)
    }
    else {
        Add-Step -Name 'Init FromRemote into fresh dir with oversize on Studio (#82)' `
            -Status 'SKIP' `
            -Detail 'oversize create did not succeed'
        Add-Step -Name 'Plan on #82 workspace lists oversize as unverifiable (#57)' `
            -Status 'SKIP' `
            -Detail 'oversize create did not succeed'
    }
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

