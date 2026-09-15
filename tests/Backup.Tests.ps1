# Backup set contracts for Safe Pull: timestamped sets, verified copies,
# restore, and best-effort retention.
#
# Do not require Pester. No network.
#
# SCOPE NOTE: tests/Run-Tests.ps1 dot-sources every *.Tests.ps1 into one
# scope, in filename order. This file sorts first (Backup < Hashing < Init),
# so helpers here are prefixed New-BackupTest* / Get-BackupTest* and never
# shadow a library function another test file needs. No remote helper is
# stubbed, so nothing leaks forward.

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "lib\Paths.ps1")
. (Join-Path $repoRoot "lib\Ignore.ps1")
. (Join-Path $repoRoot "lib\Hashing.ps1")
. (Join-Path $repoRoot "lib\Workspace.ps1")
. (Join-Path $repoRoot "lib\Manifest.ps1")
. (Join-Path $repoRoot "lib\Backup.ps1")

$backupTestUtf8 = New-Object System.Text.UTF8Encoding $false

function New-BackupTestWorkspace {
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    $workspace = Join-Path $Root ("ws-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $workspace | Out-Null
    return $workspace
}

function Write-BackupTestFile {
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath,

        [Parameter(Mandatory)]
        [byte[]]$Bytes
    )

    $parent = Split-Path -Parent $LiteralPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    [System.IO.File]::WriteAllBytes($LiteralPath, $Bytes)
}

function Get-BackupTestBytes {
    param([Parameter(Mandatory)][string]$LiteralPath)

    return [System.IO.File]::ReadAllBytes($LiteralPath)
}

$backupTestRoot = Join-Path $env:TEMP ("rundot-backup-tests-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $backupTestRoot | Out-Null

try {
    # ----------------------------------------------------------------------
    # Backup root lives under sync state
    # ----------------------------------------------------------------------

    $backupWorkspace = New-BackupTestWorkspace -Root $backupTestRoot
    $backupRoot = Get-RundotSyncBackupRoot -WorkspaceRoot $backupWorkspace

    Assert-Equal `
        (Join-Path $backupWorkspace ".rundot-sync\backups") `
        $backupRoot `
        "the backup root must be .rundot-sync/backups under the workspace"

    Assert-Equal `
        $backupRoot `
        (Join-Path (Get-RundotSyncRoot -WorkspaceRoot $backupWorkspace) "backups") `
        "the backup root must sit beside the other sync state"

    # A workspace with no backups yet reports none, not an error.
    Assert-Equal `
        0 `
        @(Get-RundotSyncBackupSets -WorkspaceRoot $backupWorkspace).Count `
        "a workspace without a backup root must report zero backup sets"

    # ----------------------------------------------------------------------
    # Set names: UTC, ordinal-sortable, parseable, collision-proof
    # ----------------------------------------------------------------------

    $stampA = [DateTime]::Parse('2026-01-02T03:04:05.678Z').ToUniversalTime()
    $stampB = [DateTime]::Parse('2026-01-02T03:04:05.679Z').ToUniversalTime()

    Assert-Equal `
        '20260102T030405678Z' `
        (New-RundotSyncBackupSetName -Timestamp $stampA) `
        "a backup set name must be a UTC compact timestamp"

    Assert-Equal `
        '20260102T030405678Z-1' `
        (New-RundotSyncBackupSetName -Timestamp $stampA -Suffix 1) `
        "a same-millisecond set must carry a disambiguating suffix"

    # Ordinal name order is chronological order, which retention relies on.
    Assert-True `
        ((New-RundotSyncBackupSetName -Timestamp $stampA) -lt (New-RundotSyncBackupSetName -Timestamp $stampB)) `
        "backup set names must sort chronologically by ordinal comparison"

    Assert-Equal `
        $stampA `
        (Get-RundotSyncBackupSetTimestamp -Name '20260102T030405678Z') `
        "a set name must parse back to the timestamp that produced it"

    Assert-Null `
        (Get-RundotSyncBackupSetTimestamp -Name 'not-a-timestamp') `
        "an unrecognized folder name must not parse as a backup set"
    Assert-Null `
        (Get-RundotSyncBackupSetTimestamp -Name '') `
        "an empty name must not parse as a backup set"

    # Two sets in the same millisecond must be distinct directories, so a
    # second pull can never overwrite the first pull's backups.
    $collideA = New-RundotSyncBackupSet -WorkspaceRoot $backupWorkspace -Timestamp $stampA
    $collideB = New-RundotSyncBackupSet -WorkspaceRoot $backupWorkspace -Timestamp $stampA

    Assert-True `
        ($collideA.Name -ne $collideB.Name) `
        "two sets created in the same millisecond must have distinct names"
    Assert-True `
        (Test-Path -LiteralPath $collideA.Path -PathType Container) `
        "the first same-millisecond set must exist"
    Assert-True `
        (Test-Path -LiteralPath $collideB.Path -PathType Container) `
        "the second same-millisecond set must exist"

    Assert-Equal `
        2 `
        @(Get-RundotSyncBackupSets -WorkspaceRoot $backupWorkspace).Count `
        "both same-millisecond sets must be reported"

    # ----------------------------------------------------------------------
    # Verified copy: exact bytes, nested parents, replace, no partial output
    # ----------------------------------------------------------------------

    $copyWorkspace = New-BackupTestWorkspace -Root $backupTestRoot
    $originalBytes = $backupTestUtf8.GetBytes("first`r`nsecond`r`n")
    $original = Join-Path $copyWorkspace "src\a.ts"
    Write-BackupTestFile -LiteralPath $original -Bytes $originalBytes

    $copySet = New-RundotSyncBackupSet -WorkspaceRoot $copyWorkspace
    Assert-Equal `
        (Join-Path $copySet.Path "src\a.ts") `
        (Copy-RundotSyncBackupFile `
            -SourcePath $original `
            -DestinationPath (Join-Path $copySet.Path "src\a.ts")) `
        "a backup copy must land at <set>/<canonical-path> and create parents"

    $backupOriginal = Join-Path $copySet.Path "src\a.ts"
    Assert-Equal `
        $originalBytes `
        (Get-BackupTestBytes -LiteralPath $backupOriginal) `
        "a backed-up original must be byte-identical to the source"

    # The copy must not disturb the source.
    Assert-Equal `
        $originalBytes `
        (Get-BackupTestBytes -LiteralPath $original) `
        "copying a backup must not modify the original"

    # A verified copy over an existing destination replaces it atomically and
    # leaves no .tmp behind.
    $replaceBytes = $backupTestUtf8.GetBytes('replacement')
    Write-BackupTestFile -LiteralPath $backupOriginal -Bytes $replaceBytes
    [void](Invoke-RundotSyncVerifiedCopy -SourcePath $original -DestinationPath $backupOriginal)
    Assert-Equal `
        $originalBytes `
        (Get-BackupTestBytes -LiteralPath $backupOriginal) `
        "a verified copy must replace an existing destination"
    Assert-True `
        (-not (Test-Path -LiteralPath ($backupOriginal + '.tmp'))) `
        "a verified copy must leave no temporary file behind"

    # A missing source throws and must not leave a partial destination.
    $missingSource = Join-Path $copyWorkspace "missing.ts"
    $missingDest = Join-Path $copySet.Path "missing.ts"
    $copyThrew = $null
    try {
        Copy-RundotSyncBackupFile -SourcePath $missingSource -DestinationPath $missingDest
    }
    catch {
        $copyThrew = $_.Exception
    }
    Assert-True ($null -ne $copyThrew) "backing up a missing source must throw"
    Assert-True `
        (-not (Test-Path -LiteralPath $missingDest)) `
        "a failed backup must leave no destination file"
    Assert-True `
        (-not (Test-Path -LiteralPath ($missingDest + '.tmp'))) `
        "a failed backup must leave no temporary file"

    # A copy into a not-yet-created set still works: the set path is just a
    # directory the copy creates on demand.
    $implicitSet = Join-Path (Get-RundotSyncBackupRoot -WorkspaceRoot $copyWorkspace) '20990101T000000000Z'
    [void](Copy-RundotSyncBackupFile `
        -SourcePath $original `
        -DestinationPath (Join-Path $implicitSet "src\a.ts"))
    Assert-Equal `
        $originalBytes `
        (Get-BackupTestBytes -LiteralPath (Join-Path $implicitSet "src\a.ts")) `
        "a backup copy must create its set directory when needed"

    # ----------------------------------------------------------------------
    # Restore: rollback puts the original bytes back
    # ----------------------------------------------------------------------

    $restoreWorkspace = New-BackupTestWorkspace -Root $backupTestRoot
    $restoreTarget = Join-Path $restoreWorkspace "src\a.ts"
    $restoreOriginalBytes = $backupTestUtf8.GetBytes("keep me`n")
    Write-BackupTestFile -LiteralPath $restoreTarget -Bytes $restoreOriginalBytes

    $restoreSet = New-RundotSyncBackupSet -WorkspaceRoot $restoreWorkspace
    $restoreBackup = Join-Path $restoreSet.Path "src\a.ts"
    [void](Copy-RundotSyncBackupFile -SourcePath $restoreTarget -DestinationPath $restoreBackup)

    # Simulate a pull overwrite, then roll it back.
    Write-BackupTestFile -LiteralPath $restoreTarget -Bytes ($backupTestUtf8.GetBytes('pulled remote content'))

    Assert-Equal `
        $restoreTarget `
        (Restore-RundotSyncBackupFile -BackupPath $restoreBackup -DestinationPath $restoreTarget) `
        "restoring a backup must report the destination it rewrote"
    Assert-Equal `
        $restoreOriginalBytes `
        (Get-BackupTestBytes -LiteralPath $restoreTarget) `
        "restoring a backup must put the original bytes back"

    $restoreMissingThrew = $null
    try {
        Restore-RundotSyncBackupFile `
            -BackupPath (Join-Path $restoreSet.Path "nope.ts") `
            -DestinationPath $restoreTarget
    }
    catch {
        $restoreMissingThrew = $_.Exception
    }
    Assert-True ($null -ne $restoreMissingThrew) "restoring a missing backup must throw"
    Assert-Equal `
        $restoreOriginalBytes `
        (Get-BackupTestBytes -LiteralPath $restoreTarget) `
        "a failed restore must leave the destination untouched"

    # ----------------------------------------------------------------------
    # Backups are never sync content
    # ----------------------------------------------------------------------

    $inventory = Get-LocalManifest -WorkspaceRoot $restoreWorkspace
    foreach ($key in @($inventory.Keys)) {
        Assert-True `
            (-not ([string]$key).StartsWith('.rundot-sync/')) `
            "a backup file must never become a local inventory key ('$key')"
    }
    Assert-True `
        (-not $inventory.Contains('.rundot-sync/backups/' + $restoreSet.Name + '/src/a.ts')) `
        "a backed-up copy must never be an upload candidate"

    # ----------------------------------------------------------------------
    # Retention: newest 10 sets or last 7 days, whichever gives more
    #
    # The rules are a union, never an intersection: the policy must always
    # recover at least as much as either rule alone would have kept.
    # ----------------------------------------------------------------------

    function New-BackupTestSetAt {
        param(
            [Parameter(Mandatory)][string]$Workspace,
            [Parameter(Mandatory)][DateTime]$Timestamp
        )

        return New-RundotSyncBackupSet -WorkspaceRoot $Workspace -Timestamp $Timestamp
    }

    function Get-BackupTestSetNames {
        param([Parameter(Mandatory)][string]$Workspace)

        return @(
            Get-RundotSyncBackupSets -WorkspaceRoot $Workspace |
                ForEach-Object { [string]$_.Name }
        )
    }

    $retentionNow = [DateTime]::Parse('2026-06-15T12:00:00.000Z').ToUniversalTime()

    # 12 sets, all older than the 7-day window: the newest 10 survive and the
    # 2 oldest are pruned.
    $manyWorkspace = New-BackupTestWorkspace -Root $backupTestRoot
    for ($i = 0; $i -lt 12; $i++) {
        [void](New-BackupTestSetAt `
            -Workspace $manyWorkspace `
            -Timestamp $retentionNow.AddDays(-30).AddMinutes(-$i))
    }

    $manyBefore = Get-BackupTestSetNames -Workspace $manyWorkspace
    Assert-Equal 12 $manyBefore.Count "the fixture must create twelve backup sets"

    $manyDeleted = @(
        Remove-RundotSyncExpiredBackupSets `
            -WorkspaceRoot $manyWorkspace `
            -MaxSets 10 `
            -MaxAgeDays 7 `
            -Now $retentionNow
    )
    Assert-Equal 2 $manyDeleted.Count "retention must prune exactly the sets beyond the newest ten"
    Assert-Equal 10 @(Get-BackupTestSetNames -Workspace $manyWorkspace).Count "retention must keep ten sets"
    Assert-Equal `
        $manyBefore[0] `
        $manyDeleted[0] `
        "retention must prune the oldest set first"
    Assert-Equal `
        @($manyBefore[2..11]) `
        @(Get-BackupTestSetNames -Workspace $manyWorkspace) `
        "retention must keep the newest ten sets and drop the two oldest"
    Assert-True `
        ($manyDeleted -notcontains $manyBefore[11]) `
        "retention must never prune the newest set"

    # 3 sets, all far older than the window: newest-ten keeps them because it
    # gives more recovery than the age rule alone.
    $fewWorkspace = New-BackupTestWorkspace -Root $backupTestRoot
    for ($i = 0; $i -lt 3; $i++) {
        [void](New-BackupTestSetAt `
            -Workspace $fewWorkspace `
            -Timestamp $retentionNow.AddDays(-90).AddMinutes(-$i))
    }
    Assert-Equal `
        0 `
        @(Remove-RundotSyncExpiredBackupSets -WorkspaceRoot $fewWorkspace -MaxSets 10 -MaxAgeDays 7 -Now $retentionNow).Count `
        "retention must not prune when fewer than the newest ten sets exist"
    Assert-Equal 3 @(Get-BackupTestSetNames -Workspace $fewWorkspace).Count "all three old sets must survive"

    # 15 recent sets: the age rule keeps every one, even though the count rule
    # alone would have pruned five.
    $recentWorkspace = New-BackupTestWorkspace -Root $backupTestRoot
    for ($i = 0; $i -lt 15; $i++) {
        [void](New-BackupTestSetAt `
            -Workspace $recentWorkspace `
            -Timestamp $retentionNow.AddDays(-1).AddMinutes(-$i))
    }
    Assert-Equal `
        0 `
        @(Remove-RundotSyncExpiredBackupSets -WorkspaceRoot $recentWorkspace -MaxSets 10 -MaxAgeDays 7 -Now $retentionNow).Count `
        "the age rule must keep sets newer than the window"
    Assert-Equal 15 @(Get-BackupTestSetNames -Workspace $recentWorkspace).Count "all recent sets must survive"

    # The in-flight set is never pruned, even when it is the oldest and sits
    # outside the newest ten.
    $inFlightWorkspace = New-BackupTestWorkspace -Root $backupTestRoot
    for ($i = 0; $i -lt 12; $i++) {
        [void](New-BackupTestSetAt `
            -Workspace $inFlightWorkspace `
            -Timestamp $retentionNow.AddDays(-30).AddMinutes(-$i))
    }
    $inFlightNames = Get-BackupTestSetNames -Workspace $inFlightWorkspace
    $oldest = $inFlightNames[0]

    $inFlightDeleted = @(
        Remove-RundotSyncExpiredBackupSets `
            -WorkspaceRoot $inFlightWorkspace `
            -KeepName $oldest `
            -MaxSets 10 `
            -MaxAgeDays 7 `
            -Now $retentionNow
    )
    Assert-Equal 1 $inFlightDeleted.Count "keep-name must save exactly one extra set from pruning"
    Assert-True `
        (Test-Path -LiteralPath (Join-Path (Get-RundotSyncBackupRoot -WorkspaceRoot $inFlightWorkspace) $oldest)) `
        "the in-flight backup set must never be pruned"
    Assert-True `
        ((Get-BackupTestSetNames -Workspace $inFlightWorkspace) -contains $oldest) `
        "the in-flight set must still be listed after retention"

    # A folder whose name is not a backup set is left alone: it is not ours.
    $foreignWorkspace = New-BackupTestWorkspace -Root $backupTestRoot
    [void](New-BackupTestSetAt -Workspace $foreignWorkspace -Timestamp $retentionNow.AddDays(-90))
    $foreignDir = Join-Path (Get-RundotSyncBackupRoot -WorkspaceRoot $foreignWorkspace) 'not-a-set'
    New-Item -ItemType Directory -Force -Path $foreignDir | Out-Null
    [void](Remove-RundotSyncExpiredBackupSets -WorkspaceRoot $foreignWorkspace -MaxSets 10 -MaxAgeDays 7 -Now $retentionNow)
    Assert-True `
        (Test-Path -LiteralPath $foreignDir -PathType Container) `
        "retention must never delete a folder it does not recognize as a backup set"

    # Retention is best effort: a prune failure must not fail the caller, and
    # the offending set simply stays.
    $guardedWorkspace = New-BackupTestWorkspace -Root $backupTestRoot
    for ($i = 0; $i -lt 12; $i++) {
        [void](New-BackupTestSetAt `
            -Workspace $guardedWorkspace `
            -Timestamp $retentionNow.AddDays(-30).AddMinutes(-$i))
    }
    $guardedBefore = @(Get-BackupTestSetNames -Workspace $guardedWorkspace)

    function Remove-Item {
        param(
            [Parameter(ValueFromPipeline)]
            [string]$LiteralPath,
            [switch]$Recurse,
            [switch]$Force,
            $ErrorAction
        )

        throw [System.InvalidOperationException]::new("Injected retention delete failure.")
    }

    $guardedDeleted = @()
    $guardedThrew = $null
    try {
        $guardedDeleted = @(
            Remove-RundotSyncExpiredBackupSets `
                -WorkspaceRoot $guardedWorkspace `
                -MaxSets 10 `
                -MaxAgeDays 7 `
                -Now $retentionNow
        )
    }
    catch {
        $guardedThrew = $_.Exception
    }
    finally {
        Microsoft.PowerShell.Management\Remove-Item -Path function:Remove-Item -ErrorAction SilentlyContinue
    }

    Assert-True ($null -eq $guardedThrew) "a prune failure must not fail retention"
    Assert-Equal 0 $guardedDeleted.Count "a failed prune must not claim a set was deleted"
    Assert-Equal `
        $guardedBefore.Count `
        @(Get-BackupTestSetNames -Workspace $guardedWorkspace).Count `
        "a failed prune must leave every set in place"
    Assert-True `
        ((Get-Command Remove-Item -CommandType Cmdlet) -ne $null) `
        "Backup.Tests must restore the real Remove-Item cmdlet"
}
finally {
    if (Test-Path -LiteralPath $backupTestRoot) {
        Remove-Item -LiteralPath $backupTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
