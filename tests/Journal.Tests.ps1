# Journal contracts for Safe Pull: append-only, metadata-only JSONL.
#
# Do not require Pester. No network.
#
# SCOPE NOTE: tests/Run-Tests.ps1 dot-sources every *.Tests.ps1 into one
# scope, in filename order. This file sorts after Init.Tests.ps1 and before
# Manifest.Tests.ps1. Helpers here are prefixed New-JournalTest* /
# Get-JournalTest* so they never shadow a library function another test file
# needs. No remote helper is stubbed, so nothing leaks forward.

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "lib\Paths.ps1")
. (Join-Path $repoRoot "lib\Ignore.ps1")
. (Join-Path $repoRoot "lib\Hashing.ps1")
. (Join-Path $repoRoot "lib\Workspace.ps1")
. (Join-Path $repoRoot "lib\Manifest.ps1")
. (Join-Path $repoRoot "lib\Journal.ps1")

$journalTestUtf8 = New-Object System.Text.UTF8Encoding $false

function New-JournalTestWorkspace {
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    $workspace = Join-Path $Root ("ws-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $workspace | Out-Null
    return $workspace
}

function Get-JournalTestRawText {
    param([Parameter(Mandatory)][string]$WorkspaceRoot)

    $path = Get-RundotSyncJournalPath -WorkspaceRoot $WorkspaceRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return ''
    }

    return [System.IO.File]::ReadAllText($path)
}

function Get-JournalTestLines {
    param([Parameter(Mandatory)][string]$WorkspaceRoot)

    $raw = Get-JournalTestRawText -WorkspaceRoot $WorkspaceRoot
    if ([string]::IsNullOrEmpty($raw)) {
        return @()
    }

    return @($raw -split "`n" | Where-Object { $_.Length -gt 0 })
}

function Get-JournalTestPropertyValue {
    param(
        $Record,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Record) {
        return $null
    }

    $property = $Record.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

$journalTestRoot = Join-Path $env:TEMP ("rundot-journal-tests-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $journalTestRoot | Out-Null

try {
    # ----------------------------------------------------------------------
    # Path and lazy creation
    # ----------------------------------------------------------------------

    $journalWorkspace = New-JournalTestWorkspace -Root $journalTestRoot
    $journalPath = Get-RundotSyncJournalPath -WorkspaceRoot $journalWorkspace

    Assert-Equal `
        (Join-Path $journalWorkspace ".rundot-sync\journal.jsonl") `
        $journalPath `
        "the journal must live at .rundot-sync/journal.jsonl"
    Assert-True `
        (-not (Test-Path -LiteralPath $journalPath)) `
        "the journal must not exist before the first append"
    Assert-Equal `
        0 `
        @(Read-RundotSyncJournal -WorkspaceRoot $journalWorkspace).Count `
        "reading a journal that does not exist must return no records"

    # Layout initialization must never plant a journal: only a real Pull run
    # creates it.
    $layoutWorkspace = New-JournalTestWorkspace -Root $journalTestRoot
    Initialize-RundotSyncLayout -WorkspaceRoot $layoutWorkspace
    Assert-True `
        (-not (Test-Path -LiteralPath (Get-RundotSyncJournalPath -WorkspaceRoot $layoutWorkspace))) `
        "layout initialization must not plant journal.jsonl"
    Assert-True `
        (Test-Path -LiteralPath (Join-Path $layoutWorkspace ".rundot-sync\backups") -PathType Container) `
        "layout initialization must still create the backups folder"

    # Appending into a workspace with no .rundot-sync at all must create the
    # layout on demand rather than failing.
    $freshWorkspace = New-JournalTestWorkspace -Root $journalTestRoot
    [void](Add-RundotSyncJournalRecord `
        -WorkspaceRoot $freshWorkspace `
        -Event 'pull' `
        -Record @{ status = 'success' })
    Assert-True `
        (Test-Path -LiteralPath (Get-RundotSyncJournalPath -WorkspaceRoot $freshWorkspace) -PathType Leaf) `
        "the first append must create the journal"

    # ----------------------------------------------------------------------
    # Encoding: UTF-8 without a BOM, one compact JSON object per line
    # ----------------------------------------------------------------------

    $bomWorkspace = New-JournalTestWorkspace -Root $journalTestRoot
    [void](Add-RundotSyncJournalRecord `
        -WorkspaceRoot $bomWorkspace `
        -Event 'pull' `
        -Record @{ status = 'success' })

    $bomBytes = [System.IO.File]::ReadAllBytes((Get-RundotSyncJournalPath -WorkspaceRoot $bomWorkspace))
    $hasBom = (
        $bomBytes.Length -ge 3 -and
        $bomBytes[0] -eq 0xEF -and
        $bomBytes[1] -eq 0xBB -and
        $bomBytes[2] -eq 0xBF
    )
    Assert-True (-not $hasBom) "the journal must be written as UTF-8 without a BOM"

    # ----------------------------------------------------------------------
    # Append-only: earlier lines are preserved exactly
    # ----------------------------------------------------------------------

    $appendWorkspace = New-JournalTestWorkspace -Root $journalTestRoot

    $first = Add-RundotSyncJournalRecord `
        -WorkspaceRoot $appendWorkspace `
        -Event 'pull' `
        -Record @{
            status       = 'success'
            projectId    = 'proj-test-1'
            planId       = '11111111-1111-1111-1111-111111111111'
            backupSet    = '20260102T030405678Z'
            applied      = 2
            overwritten  = 2
            created      = 0
            skipped      = 1
            baseUpdated  = $true
        }

    Assert-Equal 'pull' ([string]$first.event) "an appended record must report its event"
    Assert-True `
        (-not [string]::IsNullOrEmpty([string]$first.timestamp)) `
        "an appended record must carry a timestamp"

    $firstLine = @(Get-JournalTestLines -WorkspaceRoot $appendWorkspace)[0]

    $second = Add-RundotSyncJournalRecord `
        -WorkspaceRoot $appendWorkspace `
        -Event 'pull' `
        -Record @{
            status      = 'failed'
            reason      = 'Backup failed.'
            baseUpdated = $false
        }

    $linesAfterTwo = @(Get-JournalTestLines -WorkspaceRoot $appendWorkspace)
    Assert-Equal 2 $linesAfterTwo.Count "each append must add exactly one line"
    Assert-Equal `
        $firstLine `
        $linesAfterTwo[0] `
        "appending must never rewrite an earlier journal line"

    $records = @(Read-RundotSyncJournal -WorkspaceRoot $appendWorkspace)
    Assert-Equal 2 $records.Count "every appended record must be readable"

    $firstRead = $records[0]
    Assert-Equal 'proj-test-1' ([string](Get-JournalTestPropertyValue -Record $firstRead -Name 'projectId')) "the projectId must round-trip"
    Assert-Equal `
        '11111111-1111-1111-1111-111111111111' `
        ([string](Get-JournalTestPropertyValue -Record $firstRead -Name 'planId')) `
        "the planId must round-trip"
    Assert-Equal `
        '20260102T030405678Z' `
        ([string](Get-JournalTestPropertyValue -Record $firstRead -Name 'backupSet')) `
        "the backup set name must round-trip"
    Assert-Equal 2 (Get-JournalTestPropertyValue -Record $firstRead -Name 'applied') "the applied count must round-trip"
    Assert-Equal 2 (Get-JournalTestPropertyValue -Record $firstRead -Name 'overwritten') "the overwrite count must round-trip"
    Assert-Equal 0 (Get-JournalTestPropertyValue -Record $firstRead -Name 'created') "the created count must round-trip"
    Assert-Equal 1 (Get-JournalTestPropertyValue -Record $firstRead -Name 'skipped') "the skipped count must round-trip"
    Assert-Equal $true (Get-JournalTestPropertyValue -Record $firstRead -Name 'baseUpdated') "baseUpdated must round-trip"

    $secondRead = $records[1]
    Assert-Equal 'failed' ([string](Get-JournalTestPropertyValue -Record $secondRead -Name 'status')) "a failure record must keep its status"
    Assert-Equal $false (Get-JournalTestPropertyValue -Record $secondRead -Name 'baseUpdated') "a failure record must report baseUpdated false"

    # Every line must be independently parseable JSON, not one big document.
    foreach ($line in $linesAfterTwo) {
        $parsed = $null
        $parseThrew = $false
        try {
            $parsed = $line | ConvertFrom-Json
        }
        catch {
            $parseThrew = $true
        }
        Assert-True (-not $parseThrew) "each journal line must be standalone JSON"
        Assert-True ($null -ne $parsed) "each journal line must parse to an object"
    }

    # ----------------------------------------------------------------------
    # Metadata only: tokens, contents, and headers can never be recorded
    # ----------------------------------------------------------------------

    $secretWorkspace = New-JournalTestWorkspace -Root $journalTestRoot

    # A caller that hands the journal a secret-bearing field must not get it
    # written: the field set is an allowlist, so anything else is dropped.
    [void](Add-RundotSyncJournalRecord `
        -WorkspaceRoot $secretWorkspace `
        -Event 'pull' `
        -Record @{
            status        = 'success'
            planId        = '22222222-2222-2222-2222-222222222222'
            Authorization = 'Bearer super-secret-token'
            Token         = 'super-secret-token'
            refreshToken  = 'super-secret-token'
            Content       = 'file contents that must never be journaled'
            StagingPath   = 'C:\secret\staging\a.ts'
        })

    $secretRaw = Get-JournalTestRawText -WorkspaceRoot $secretWorkspace
    Assert-True `
        ($secretRaw -notmatch '(?i)bearer|authoriz|accesstoken|refreshtoken') `
        "the journal must never record a token or an Authorization header"
    Assert-True `
        ($secretRaw -notmatch 'super-secret-token') `
        "the journal must never record a secret value passed by a caller"
    Assert-True `
        ($secretRaw -notmatch '(?i)"content"') `
        "the journal must never record file contents"
    Assert-True `
        ($secretRaw -notmatch '(?i)stagingpath') `
        "the journal must never record a staging path"

    $secretRecord = @(Read-RundotSyncJournal -WorkspaceRoot $secretWorkspace)[0]
    Assert-Null `
        (Get-JournalTestPropertyValue -Record $secretRecord -Name 'Authorization') `
        "a dropped field must not reappear in the parsed record"
    Assert-Null `
        (Get-JournalTestPropertyValue -Record $secretRecord -Name 'Content') `
        "file contents must never become a journal field"
    Assert-Equal `
        '22222222-2222-2222-2222-222222222222' `
        ([string](Get-JournalTestPropertyValue -Record $secretRecord -Name 'planId')) `
        "allowlisted metadata must still be recorded alongside a dropped secret"

    # A secret smuggled into an allowlisted field is refused rather than
    # written, so a future caller cannot accidentally leak through `reason`.
    $smuggleWorkspace = New-JournalTestWorkspace -Root $journalTestRoot
    $smuggleThrew = $null
    try {
        Add-RundotSyncJournalRecord `
            -WorkspaceRoot $smuggleWorkspace `
            -Event 'pull' `
            -Record @{ status = 'failed'; reason = 'Request used Authorization: Bearer abc.def.ghi' }
    }
    catch {
        $smuggleThrew = $_.Exception
    }
    Assert-True ($null -ne $smuggleThrew) "a journal line containing a credential must be refused"
    Assert-True `
        ([string]$smuggleThrew.Message -notmatch 'abc\.def\.ghi') `
        "the refusal must not echo the credential it rejected"
    Assert-Equal `
        0 `
        @(Get-JournalTestLines -WorkspaceRoot $smuggleWorkspace).Count `
        "a refused journal line must not be written"

    # ----------------------------------------------------------------------
    # Torn append after a crash: readable, and never rewritten
    # ----------------------------------------------------------------------

    $tornWorkspace = New-JournalTestWorkspace -Root $journalTestRoot
    [void](Add-RundotSyncJournalRecord -WorkspaceRoot $tornWorkspace -Event 'pull' -Record @{ status = 'success' })
    [void](Add-RundotSyncJournalRecord -WorkspaceRoot $tornWorkspace -Event 'pull' -Record @{ status = 'success' })

    # A crash mid-append leaves a partial trailing line.
    [System.IO.File]::AppendAllText(
        (Get-RundotSyncJournalPath -WorkspaceRoot $tornWorkspace),
        '{"timestamp":"2026-01-02T03:04:05.6780000Z","event":"pull"',
        $journalTestUtf8
    )

    $tornRecords = @(Read-RundotSyncJournal -WorkspaceRoot $tornWorkspace)
    Assert-Equal 2 $tornRecords.Count "a torn trailing line must not hide the complete records before it"

    # Reading must never repair or rewrite the journal.
    Assert-Equal `
        3 `
        @(Get-JournalTestLines -WorkspaceRoot $tornWorkspace).Count `
        "reading must leave a torn trailing line untouched"

    # A subsequent append must not resurrect or duplicate the torn line, and
    # it must not fail because of it.
    [void](Add-RundotSyncJournalRecord -WorkspaceRoot $tornWorkspace -Event 'pull' -Record @{ status = 'success' })
    Assert-Equal `
        3 `
        @(Read-RundotSyncJournal -WorkspaceRoot $tornWorkspace).Count `
        "a later append must add one readable record despite a torn line"

    # ----------------------------------------------------------------------
    # The journal is never sync content
    # ----------------------------------------------------------------------

    $inventory = Get-LocalManifest -WorkspaceRoot $appendWorkspace
    foreach ($key in @($inventory.Keys)) {
        Assert-True `
            (-not ([string]$key).StartsWith('.rundot-sync/')) `
            "a journal must never become a local inventory key ('$key')"
    }
    Assert-True `
        (-not $inventory.Contains('.rundot-sync/journal.jsonl')) `
        "the journal must never be an upload candidate"
}
finally {
    if (Test-Path -LiteralPath $journalTestRoot) {
        Remove-Item -LiteralPath $journalTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
