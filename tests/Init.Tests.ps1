# Init FromRemote / Adopt, destination rules, and the no-BASE gate.
# Do not require Pester. Network is not used.
#
# SCOPE HAZARD: tests/Run-Tests.ps1 dot-sources every *.Tests.ps1 into one
# scope, in filename order. This file sorts before Manifest.Tests.ps1,
# RemoteApi.Tests.ps1, and Snapshot.Tests.ps1, so any remote helper stubbed
# below stays overwritten for those files unless it is restored. The stub
# region therefore ends by re-dot-sourcing lib/RemoteApi.ps1, and the tests
# at the bottom of this file fail loudly if that restore stops working.
# (Those downstream files re-dot-source their own libraries today, which
# would mask a leak; the assertions keep the contract explicit anyway.)

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "lib\Paths.ps1")
. (Join-Path $repoRoot "lib\Ignore.ps1")
. (Join-Path $repoRoot "lib\Hashing.ps1")
. (Join-Path $repoRoot "lib\Workspace.ps1")
. (Join-Path $repoRoot "lib\RemoteApi.ps1")
. (Join-Path $repoRoot "lib\Snapshot.ps1")
. (Join-Path $repoRoot "lib\Init.ps1")

$script:FakeListCalls = 0
$script:FakeFileCalls = 0
$script:FakeListQueue = @()
$script:FakeFilePayloads = @{}
$script:FakeFileErrors = @{}

function Reset-FakeRemote {
    param(
        [object[]]$Lists = @(),
        [hashtable]$Files = @{},
        [hashtable]$FileErrors = @{}
    )

    $script:FakeListCalls = 0
    $script:FakeFileCalls = 0
    $script:FakeListQueue = @($Lists)
    $script:FakeFilePayloads = @{}
    if ($Files) {
        $script:FakeFilePayloads = $Files
    }

    $script:FakeFileErrors = @{}
    if ($FileErrors) {
        $script:FakeFileErrors = $FileErrors
    }
}

function Get-RemoteProjectFileList {
    param(
        [string]$StudioOrigin,
        [string]$ProjectId,
        [hashtable]$Headers
    )

    $script:FakeListCalls++
    $index = $script:FakeListCalls - 1
    if ($index -ge $script:FakeListQueue.Count) {
        return $script:FakeListQueue[$script:FakeListQueue.Count - 1]
    }

    return $script:FakeListQueue[$index]
}

function Get-RemoteProjectFile {
    param(
        [string]$StudioOrigin,
        [string]$ProjectId,
        [string]$Path,
        [hashtable]$Headers
    )

    $script:FakeFileCalls++
    $lookup = $Path
    if ($lookup.StartsWith('/')) {
        $lookup = $lookup.Substring(1)
    }

    if ($script:FakeFileErrors.ContainsKey($Path)) {
        throw $script:FakeFileErrors[$Path]
    }

    if ($script:FakeFileErrors.ContainsKey($lookup)) {
        throw $script:FakeFileErrors[$lookup]
    }

    if ($script:FakeFilePayloads.ContainsKey($Path)) {
        return $script:FakeFilePayloads[$Path]
    }

    if ($script:FakeFilePayloads.ContainsKey($lookup)) {
        return $script:FakeFilePayloads[$lookup]
    }

    throw [System.InvalidOperationException]::new("No fake payload for '$Path'.")
}

# --------------------------------------------------------------------------
# Init destination: empty except allowable metadata, or refuse
#
# This gate runs BEFORE any remote call. Get-StableRemoteSnapshot creates
# .rundot-sync/ inside the destination, so checking afterwards could never
# tell an empty folder from one that just became dirty.
# --------------------------------------------------------------------------

$initRoot = Join-Path $env:TEMP ("rundot-init-dest-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $initRoot | Out-Null

try {
    Assert-Equal `
        @('.git', '.gitignore') `
        @(Get-RundotSyncInitAllowedRootMetadata) `
        "the allowable init destination metadata set is .git and .gitignore"

    # A missing LocalDir is created, not refused.
    $freshDir = Join-Path $initRoot "fresh"
    Assert-RundotSyncInitDestination -LocalDir $freshDir
    Assert-True `
        (Test-Path -LiteralPath $freshDir -PathType Container) `
        "a missing init destination should be created"

    # An empty directory passes.
    Assert-RundotSyncInitDestination -LocalDir $freshDir

    # Regression guard: an empty destination must yield zero entries, not a
    # single empty-string element from PowerShell array unrolling.
    Assert-Equal `
        0 `
        @(Get-RundotSyncInitUnexpectedEntries -LocalDir $freshDir).Count `
        "an empty destination must report zero unexpected entries, not one blank"

    # Only .git passes (as a directory), with contents present.
    $gitOnly = Join-Path $initRoot "git-only"
    New-Item -ItemType Directory -Path (Join-Path $gitOnly ".git") -Force | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $gitOnly ".git\HEAD"), [byte[]](0x61))
    Assert-RundotSyncInitDestination -LocalDir $gitOnly

    # A .git pointer file (worktree/submodule layout) also passes.
    $gitFile = Join-Path $initRoot "git-file"
    New-Item -ItemType Directory -Path $gitFile -Force | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $gitFile ".git"), [byte[]](0x61))
    Assert-RundotSyncInitDestination -LocalDir $gitFile

    # Only .gitignore passes.
    $ignoreOnly = Join-Path $initRoot "ignore-only"
    New-Item -ItemType Directory -Path $ignoreOnly -Force | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $ignoreOnly ".gitignore"), [byte[]](0x61))
    Assert-RundotSyncInitDestination -LocalDir $ignoreOnly

    # Both together pass.
    $bothMeta = Join-Path $initRoot "both-metadata"
    New-Item -ItemType Directory -Path (Join-Path $bothMeta ".git") -Force | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $bothMeta ".gitignore"), [byte[]](0x61))
    Assert-RundotSyncInitDestination -LocalDir $bothMeta

    # A leftover .rundot-sync with no BASE is tolerated, so a re-run after a
    # failed attempt does not demand a manual cleanup.
    $leftoverSync = Join-Path $initRoot "leftover-sync"
    New-Item -ItemType Directory -Path (Join-Path $leftoverSync ".rundot-sync\temp") -Force | Out-Null
    Assert-RundotSyncInitDestination -LocalDir $leftoverSync

    # Unexpected project content refuses, names the offender, and points at Adopt.
    $dirtyDir = Join-Path $initRoot "dirty"
    New-Item -ItemType Directory -Path (Join-Path $dirtyDir "src") -Force | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $dirtyDir "src\app.ts"), [byte[]](0x61))
    Assert-Equal `
        @('src') `
        @(Get-RundotSyncInitUnexpectedEntries -LocalDir $dirtyDir) `
        "unexpected entries should report the top-level offender"

    $dirtyThrown = $null
    try {
        Assert-RundotSyncInitDestination -LocalDir $dirtyDir
    }
    catch {
        $dirtyThrown = $_.Exception
    }
    Assert-True ($null -ne $dirtyThrown) "a dirty init destination must refuse"
    if ($null -ne $dirtyThrown) {
        Assert-True `
            ($dirtyThrown.Message -match 'src') `
            "the dirty refusal should name the offending entry"
        Assert-True `
            ($dirtyThrown.Message -match '\bAdopt\b') `
            "the dirty refusal should point at -InitMode Adopt"
    }

    # Refusing must not delete, move, or rewrite the user's existing file.
    $dirtyFileStillThere = Join-Path $dirtyDir "src\app.ts"
    Assert-True `
        (Test-Path -LiteralPath $dirtyFileStillThere) `
        "a refusal must leave existing files untouched"
    Assert-Equal `
        ([byte[]](0x61)) `
        ([System.IO.File]::ReadAllBytes($dirtyFileStillThere)) `
        "a refusal must not rewrite existing file bytes"

    # An already-initialized workspace refuses, and says so rather than
    # reporting generic dirt.
    $initialized = Join-Path $initRoot "initialized"
    New-Item -ItemType Directory -Path (Join-Path $initialized ".rundot-sync") -Force | Out-Null
    [System.IO.File]::WriteAllBytes(
        (Join-Path $initialized ".rundot-sync\base-manifest.json"),
        [byte[]](0x7B, 0x7D)
    )
    $initializedThrown = $null
    try {
        Assert-RundotSyncInitDestination -LocalDir $initialized
    }
    catch {
        $initializedThrown = $_.Exception
    }
    Assert-True ($null -ne $initializedThrown) "an already-initialized destination must refuse"
    if ($null -ne $initializedThrown) {
        Assert-True `
            ($initializedThrown.Message -match '(?i)already') `
            "the already-initialized refusal should say the workspace already has a BASE"
        Assert-True `
            ($initializedThrown.Message -match '\bAdopt\b') `
            "the already-initialized refusal should point at -InitMode Adopt"
    }

    # A LocalDir that exists as a file refuses with a folder-specific message.
    $notADirectory = Join-Path $initRoot "not-a-directory"
    [System.IO.File]::WriteAllBytes($notADirectory, [byte[]](0x61))
    $fileThrown = $null
    try {
        Assert-RundotSyncInitDestination -LocalDir $notADirectory
    }
    catch {
        $fileThrown = $_.Exception
    }
    Assert-True ($null -ne $fileThrown) "a LocalDir that is a file must refuse"
    if ($null -ne $fileThrown) {
        Assert-True `
            ($fileThrown.Message -match '(?i)file, not a folder') `
            "a file LocalDir should say it is not a folder"
    }

    # A destination root that is a reparse point refuses: promoting into a
    # redirected tree would write the project somewhere unexpected.
    $junctionTarget = Join-Path $initRoot "junction-target"
    New-Item -ItemType Directory -Path $junctionTarget -Force | Out-Null
    $junctionPath = Join-Path $initRoot "junction-dest"
    New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget | Out-Null
    Assert-Throws {
        Assert-RundotSyncInitDestination -LocalDir $junctionPath
    } "a destination root that is a junction must refuse"
}
finally {
    if (Test-Path -LiteralPath $initRoot) {
        Remove-Item -LiteralPath $initRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}


# --------------------------------------------------------------------------
# STUB REGION ENDS HERE
#
# Init FromRemote / Adopt tests belong above this line. Restore the real
# GET-only helpers before the next test file runs: the runner shares one
# scope, so a stubbed helper would otherwise stay installed.
#
# Manifest.Tests / RemoteApi.Tests / Snapshot.Tests happen to re-dot-source
# their libraries today, which masks a leak. These assertions keep the
# contract explicit instead of resting on that accident.
# --------------------------------------------------------------------------

. (Join-Path $repoRoot "lib\RemoteApi.ps1")

$restoredListDefinition = (Get-Command Get-RemoteProjectFileList -CommandType Function).Definition
Assert-True `
    ($restoredListDefinition -match 'Invoke-Utf8JsonGet') `
    "Init.Tests must restore the real Get-RemoteProjectFileList for later test files"

$restoredFileDefinition = (Get-Command Get-RemoteProjectFile -CommandType Function).Definition
Assert-True `
    ($restoredFileDefinition -match 'EscapeDataString') `
    "Init.Tests must restore the real Get-RemoteProjectFile for later test files"

Assert-True `
    ($restoredFileDefinition -notmatch 'FakeFilePayloads') `
    "Init.Tests must not leak its fake remote into later test files"
