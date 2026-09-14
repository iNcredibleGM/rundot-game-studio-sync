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
