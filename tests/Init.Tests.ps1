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
. (Join-Path $repoRoot "lib\Manifest.ps1")
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

    # The tolerance is name-based, so a .rundot-sync that is a *file* rather
    # than a directory is also skipped rather than reported as unexpected dirt.
    $syncAsFile = Join-Path $initRoot "sync-as-file"
    New-Item -ItemType Directory -Path $syncAsFile -Force | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $syncAsFile ".rundot-sync"), [byte[]](0x61))
    Assert-RundotSyncInitDestination -LocalDir $syncAsFile
    Assert-Equal `
        0 `
        @(Get-RundotSyncInitUnexpectedEntries -LocalDir $syncAsFile).Count `
        "a .rundot-sync file must be skipped, not reported as unexpected"

    # A relative LocalDir is resolved and accepted, since the CLI passes what
    # the user typed.
    $relativeDir = "rundot-relative-dest-" + [Guid]::NewGuid().ToString("N")
    $relativeFull = Join-Path (Get-Location).Path $relativeDir
    try {
        Assert-RundotSyncInitDestination -LocalDir $relativeDir
        Assert-True `
            (Test-Path -LiteralPath $relativeFull -PathType Container) `
            "a relative init destination should be created at the resolved path"
    }
    finally {
        if (Test-Path -LiteralPath $relativeFull) {
            Remove-Item -LiteralPath $relativeFull -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

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
# Init FromRemote: verify staging, promote, re-verify, atomic BASE
#
# Any failure must leave NO BASE. A partial promotion is never trusted.
# --------------------------------------------------------------------------

function New-FakeRemoteListEntry {
    param([hashtable]$Properties)

    $entry = New-Object PSObject
    foreach ($key in $Properties.Keys) {
        $entry | Add-Member -NotePropertyName $key -NotePropertyValue $Properties[$key]
    }

    return $entry
}

function New-FakeRemoteManifest {
    param([object[]]$Files)

    return [pscustomobject]@{ files = $Files }
}

function New-FakeSnapshotEntry {
    param(
        [string]$StagingPath,
        [string]$Sha256,
        [int64]$Size,
        [string]$Kind,
        [string]$Encoding,
        $LineEnding = $null,
        $HasBom = $null
    )

    return [pscustomobject]@{
        Sha256            = $Sha256
        Size              = $Size
        LocalDetectedKind = $Kind
        LineEnding        = $LineEnding
        HasBom            = $HasBom
        RemoteKind        = (ConvertTo-RemoteKind -Encoding $Encoding)
        Encoding          = $Encoding
        StagingPath       = $StagingPath
    }
}

function New-FakeSnapshot {
    param(
        [string]$StagingRoot,
        [hashtable]$Files
    )

    return [pscustomobject]@{
        Files                    = $Files
        RemoteManifestHashBefore = 'before'
        RemoteManifestHashAfter  = 'after'
        AttemptCount             = 1
        StagingRoot              = $StagingRoot
    }
}

function New-FakeStagingRoot {
    param([string]$LocalDir)

    $stagingRoot = Join-Path $LocalDir ".rundot-sync\temp\remote-snapshot\1"
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
    return $stagingRoot
}

function Get-TestTopLevelEntries {
    param([string]$Dir)

    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $Dir -Force |
            Where-Object { $_.Name -ne '.rundot-sync' } |
            ForEach-Object { $_.Name }
    )
}

$fromRemoteRoot = Join-Path $env:TEMP ("rundot-init-remote-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $fromRemoteRoot | Out-Null

$initUtf8 = New-Object System.Text.UTF8Encoding $false
$initHeaders = @{
    Authorization = 'Bearer test-token'
    Accept        = '*/*'
}

try {
    # ----------------------------------------------------------------------
    # Happy path: empty directory becomes a trusted workspace
    # ----------------------------------------------------------------------

    $happyDir = Join-Path $fromRemoteRoot "happy"
    $textEntry = New-FakeRemoteListEntry @{
        path     = 'src/a.ts'
        type     = 'file'
        size     = 4
        encoding = 'utf8'
    }
    $binaryEntry = New-FakeRemoteListEntry @{
        path     = 'public/logo.png'
        type     = 'file'
        size     = 2
        encoding = 'base64'
    }
    $happyManifest = New-FakeRemoteManifest -Files @($textEntry, $binaryEntry)

    # 'hi' + CRLF makes the line-ending diagnostic meaningful, and 0xFF 0xFE is
    # invalid UTF-8 so the binary path is exercised rather than assumed.
    $textPayload = "hi`r`n"
    Reset-FakeRemote `
        -Lists @($happyManifest, $happyManifest) `
        -Files @{
            'src/a.ts'        = [pscustomobject]@{ encoding = 'utf8'; content = $textPayload }
            'public/logo.png' = [pscustomobject]@{ encoding = 'base64'; content = '//4=' }
        }

    $happyResult = Initialize-RundotSyncFromRemote `
        -LocalDir $happyDir `
        -ProjectId 'proj-test-1' `
        -StudioOrigin 'https://example.test' `
        -Headers $initHeaders

    Assert-Equal 2 $happyResult.FileCount "FromRemote should report the promoted file count"

    $promotedText = Join-Path $happyDir "src\a.ts"
    $promotedBinary = Join-Path $happyDir "public\logo.png"
    Assert-True (Test-Path -LiteralPath $promotedText) "utf8 content should be promoted into LocalDir"
    Assert-True (Test-Path -LiteralPath $promotedBinary) "binary content should be promoted into LocalDir"
    Assert-Equal `
        $initUtf8.GetBytes($textPayload) `
        ([System.IO.File]::ReadAllBytes($promotedText)) `
        "promoted utf8 bytes must match the remote payload exactly"
    Assert-Equal `
        ([byte[]](0xFF, 0xFE)) `
        ([System.IO.File]::ReadAllBytes($promotedBinary)) `
        "promoted binary bytes must match the remote payload exactly"

    $happyBase = Read-BaseManifest -WorkspaceRoot $happyDir
    Assert-True ($null -ne $happyBase) "FromRemote must write BASE on success"
    if ($null -ne $happyBase) {
        Assert-BaseOwnership `
            -Base $happyBase `
            -ProjectId 'proj-test-1' `
            -WorkspaceRoot $happyDir
        Assert-Equal `
            (Get-FileSha256Hex -LiteralPath $promotedText) `
            $happyBase.files.'src/a.ts'.sha256 `
            "BASE must record the hash of the bytes now on disk"
        Assert-Equal "utf8" $happyBase.files.'src/a.ts'.kind "BASE should record a byte-derived text kind"
        Assert-Equal "crlf" $happyBase.files.'src/a.ts'.lineEnding "BASE should record line endings for text"
        Assert-Equal 4 $happyBase.files.'src/a.ts'.size "BASE should record the byte-derived size"
        Assert-Equal "binary" $happyBase.files.'public/logo.png'.kind "BASE should record a binary kind"
        Assert-Null `
            $happyBase.files.'public/logo.png'.lineEnding `
            "binary BASE entries must omit lineEnding"
        Assert-Equal 2 $happyBase.files.'public/logo.png'.size "binary BASE should record the byte-derived size"
    }

    $leftoverStaging = Join-Path $happyDir ".rundot-sync\temp\remote-snapshot"
    Assert-True `
        (-not (Test-Path -LiteralPath $leftoverStaging)) `
        "a successful promotion should clear the snapshot staging folder"

    # ----------------------------------------------------------------------
    # Empty remote project: a zero-file BASE is still a success
    # ----------------------------------------------------------------------

    $emptyProjectDir = Join-Path $fromRemoteRoot "empty-project"
    $emptyManifest = New-FakeRemoteManifest -Files @()
    Reset-FakeRemote -Lists @($emptyManifest, $emptyManifest) -Files @{}

    $emptyResult = Initialize-RundotSyncFromRemote `
        -LocalDir $emptyProjectDir `
        -ProjectId 'proj-test-1' `
        -StudioOrigin 'https://example.test' `
        -Headers $initHeaders

    Assert-Equal 0 $emptyResult.FileCount "an empty remote project should promote no files"
    $emptyBase = Read-BaseManifest -WorkspaceRoot $emptyProjectDir
    Assert-True ($null -ne $emptyBase) "an empty remote project should still write BASE"
    if ($null -ne $emptyBase) {
        Assert-Equal `
            0 `
            @($emptyBase.files.PSObject.Properties).Count `
            "an empty remote project should produce a zero-entry BASE"
    }

    # ----------------------------------------------------------------------
    # Zero-byte remote file: a valid hash, not a special case
    # ----------------------------------------------------------------------

    $zeroDir = Join-Path $fromRemoteRoot "zero-byte"
    $zeroEntry = New-FakeRemoteListEntry @{
        path     = 'empty.ts'
        type     = 'file'
        size     = 0
        encoding = 'utf8'
    }
    $zeroManifest = New-FakeRemoteManifest -Files @($zeroEntry)
    Reset-FakeRemote `
        -Lists @($zeroManifest, $zeroManifest) `
        -Files @{ 'empty.ts' = [pscustomobject]@{ encoding = 'utf8'; content = '' } }

    $zeroResult = Initialize-RundotSyncFromRemote `
        -LocalDir $zeroDir `
        -ProjectId 'proj-test-1' `
        -StudioOrigin 'https://example.test' `
        -Headers $initHeaders

    Assert-Equal 1 $zeroResult.FileCount "a zero-byte remote file should still be promoted"
    $zeroBase = Read-BaseManifest -WorkspaceRoot $zeroDir
    if ($null -ne $zeroBase) {
        Assert-Equal `
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' `
            $zeroBase.files.'empty.ts'.sha256 `
            "a zero-byte file should record the empty SHA-256"
        Assert-Equal 0 $zeroBase.files.'empty.ts'.size "a zero-byte file should record size 0"
    }
    else {
        Assert-True $false "a zero-byte remote file should still write BASE"
    }

    # ----------------------------------------------------------------------
    # Unstable snapshot: the #6 idle abort propagates and writes no BASE
    # ----------------------------------------------------------------------

    $unstableDir = Join-Path $fromRemoteRoot "unstable"
    # A distinct path set is what makes Before != After. Adding an etag alone
    # would be folded into the fingerprint as well, but a changed path set
    # exercises the retry for the reason a real edit would.
    $unstableOther = New-FakeRemoteManifest -Files @(
        $textEntry,
        (New-FakeRemoteListEntry @{
            path     = 'src/added.ts'
            type     = 'file'
            size     = 1
            encoding = 'utf8'
        })
    )
    Reset-FakeRemote `
        -Lists @(
            $happyManifest, $unstableOther,
            $happyManifest, $unstableOther,
            $happyManifest, $unstableOther
        ) `
        -Files @{
            'src/a.ts'        = [pscustomobject]@{ encoding = 'utf8'; content = $textPayload }
            'public/logo.png' = [pscustomobject]@{ encoding = 'base64'; content = '//4=' }
        }

    $unstableThrown = $null
    try {
        Initialize-RundotSyncFromRemote `
            -LocalDir $unstableDir `
            -ProjectId 'proj-test-1' `
            -StudioOrigin 'https://example.test' `
            -Headers $initHeaders | Out-Null
    }
    catch {
        $unstableThrown = $_.Exception
    }
    Assert-True ($null -ne $unstableThrown) "an unstable snapshot must abort FromRemote"
    if ($null -ne $unstableThrown) {
        Assert-True `
            ($unstableThrown.Message -match [regex]::Escape('The remote project changed while being read')) `
            "an unstable snapshot should surface the #6 idle message"
    }
    Assert-Null `
        (Read-BaseManifest -WorkspaceRoot $unstableDir) `
        "an unstable snapshot must not write BASE"
    Assert-Equal `
        0 `
        @(Get-TestTopLevelEntries -Dir $unstableDir).Count `
        "an unstable snapshot must promote nothing"

    # ----------------------------------------------------------------------
    # Failed download: a listed path that 404s writes no BASE
    # ----------------------------------------------------------------------

    $failedDownloadDir = Join-Path $fromRemoteRoot "failed-download"
    Reset-FakeRemote `
        -Lists @(
            $happyManifest, $happyManifest,
            $happyManifest, $happyManifest,
            $happyManifest, $happyManifest
        ) `
        -Files @{ 'public/logo.png' = [pscustomobject]@{ encoding = 'base64'; content = '//4=' } } `
        -FileErrors @{ 'src/a.ts' = (New-RemoteHttpException -StatusCode 404) }

    $downloadThrown = $null
    try {
        Initialize-RundotSyncFromRemote `
            -LocalDir $failedDownloadDir `
            -ProjectId 'proj-test-1' `
            -StudioOrigin 'https://example.test' `
            -Headers $initHeaders | Out-Null
    }
    catch {
        $downloadThrown = $_.Exception
    }
    Assert-True ($null -ne $downloadThrown) "a 404 during download must abort FromRemote"
    Assert-Null `
        (Read-BaseManifest -WorkspaceRoot $failedDownloadDir) `
        "a failed download must not write BASE"
    Assert-Equal `
        0 `
        @(Get-TestTopLevelEntries -Dir $failedDownloadDir).Count `
        "a failed download must promote nothing"

    # ----------------------------------------------------------------------
    # Fabricated snapshot: staged bytes disagree with the recorded hash
    # ----------------------------------------------------------------------

    $mismatchDir = Join-Path $fromRemoteRoot "staging-mismatch"
    $mismatchStaging = New-FakeStagingRoot -LocalDir $mismatchDir
    New-Item -ItemType Directory -Path (Join-Path $mismatchStaging "src") -Force | Out-Null
    $mismatchFile = Join-Path $mismatchStaging "src\a.ts"
    [System.IO.File]::WriteAllBytes($mismatchFile, [byte[]](0x61, 0x62))
    $mismatchSnapshot = New-FakeSnapshot -StagingRoot $mismatchStaging -Files @{
        'src/a.ts' = New-FakeSnapshotEntry `
            -StagingPath $mismatchFile `
            -Sha256 ('0' * 64) `
            -Size 2 `
            -Kind 'utf8' `
            -Encoding 'utf8'
    }

    $mismatchThrown = $null
    try {
        Import-RundotRemoteSnapshot `
            -LocalDir $mismatchDir `
            -ProjectId 'proj-test-1' `
            -Snapshot $mismatchSnapshot | Out-Null
    }
    catch {
        $mismatchThrown = $_.Exception
    }
    Assert-True ($null -ne $mismatchThrown) "a staging hash mismatch must abort"
    if ($null -ne $mismatchThrown) {
        Assert-True `
            ($mismatchThrown.Message -match '(?i)snapshot hash|do not match') `
            "a staging hash mismatch should say the bytes disagree with the snapshot"
    }
    Assert-Null `
        (Read-BaseManifest -WorkspaceRoot $mismatchDir) `
        "a staging hash mismatch must not write BASE"
    Assert-Equal `
        0 `
        @(Get-TestTopLevelEntries -Dir $mismatchDir).Count `
        "a staging hash mismatch must promote nothing"

    # ----------------------------------------------------------------------
    # Fabricated snapshot: staging holds a file the snapshot never listed
    # ----------------------------------------------------------------------

    $extraDir = Join-Path $fromRemoteRoot "staging-extra"
    $extraStaging = New-FakeStagingRoot -LocalDir $extraDir
    New-Item -ItemType Directory -Path (Join-Path $extraStaging "src") -Force | Out-Null
    $extraListed = Join-Path $extraStaging "src\a.ts"
    [System.IO.File]::WriteAllBytes($extraListed, [byte[]](0x61, 0x62))
    [System.IO.File]::WriteAllBytes((Join-Path $extraStaging "src\smuggled.ts"), [byte[]](0x63))
    $extraSnapshot = New-FakeSnapshot -StagingRoot $extraStaging -Files @{
        'src/a.ts' = New-FakeSnapshotEntry `
            -StagingPath $extraListed `
            -Sha256 (Get-FileSha256Hex -LiteralPath $extraListed) `
            -Size 2 `
            -Kind 'utf8' `
            -Encoding 'utf8'
    }

    Assert-Throws {
        Import-RundotRemoteSnapshot `
            -LocalDir $extraDir `
            -ProjectId 'proj-test-1' `
            -Snapshot $extraSnapshot
    } "staging must not contain files the snapshot does not list"
    Assert-Null `
        (Read-BaseManifest -WorkspaceRoot $extraDir) `
        "an unexpected staging file must not write BASE"

    # ----------------------------------------------------------------------
    # Fabricated snapshot: remote path would overwrite retained .gitignore
    # ----------------------------------------------------------------------

    $collideDir = Join-Path $fromRemoteRoot "metadata-collision"
    New-Item -ItemType Directory -Path $collideDir -Force | Out-Null
    $localIgnore = Join-Path $collideDir ".gitignore"
    [System.IO.File]::WriteAllBytes($localIgnore, [byte[]](0x4B))
    $collideStaging = New-FakeStagingRoot -LocalDir $collideDir
    $collideStagedIgnore = Join-Path $collideStaging ".gitignore"
    [System.IO.File]::WriteAllBytes($collideStagedIgnore, [byte[]](0x52))
    $collideSnapshot = New-FakeSnapshot -StagingRoot $collideStaging -Files @{
        '.gitignore' = New-FakeSnapshotEntry `
            -StagingPath $collideStagedIgnore `
            -Sha256 (Get-FileSha256Hex -LiteralPath $collideStagedIgnore) `
            -Size 1 `
            -Kind 'utf8' `
            -Encoding 'utf8'
    }

    $collideThrown = $null
    try {
        Import-RundotRemoteSnapshot `
            -LocalDir $collideDir `
            -ProjectId 'proj-test-1' `
            -Snapshot $collideSnapshot | Out-Null
    }
    catch {
        $collideThrown = $_.Exception
    }
    Assert-True ($null -ne $collideThrown) "a remote path colliding with retained metadata must refuse"
    if ($null -ne $collideThrown) {
        Assert-True `
            ($collideThrown.Message -match '(?i)metadata') `
            "the collision refusal should explain that retained metadata would be overwritten"
    }
    Assert-Equal `
        ([byte[]](0x4B)) `
        ([System.IO.File]::ReadAllBytes($localIgnore)) `
        "a metadata collision must not overwrite the existing .gitignore"
    Assert-Null `
        (Read-BaseManifest -WorkspaceRoot $collideDir) `
        "a metadata collision must not write BASE"

    # ----------------------------------------------------------------------
    # Fabricated snapshot: a remote path would land inside .rundot-sync
    #
    # A remote project could legitimately list '.rundot-sync/evil.ts' and still
    # pass the destination check, because .rundot-sync is tolerated there. If
    # that were promoted it would write into sync state.
    # ----------------------------------------------------------------------

    $syncCollideDir = Join-Path $fromRemoteRoot "sync-state-collision"
    $syncCollideStaging = New-FakeStagingRoot -LocalDir $syncCollideDir
    # Mirror the canonical path, as the real snapshot staging does, so this
    # exercises the collision refusal rather than the integrity check.
    New-Item -ItemType Directory -Path (Join-Path $syncCollideStaging ".rundot-sync") -Force | Out-Null
    $syncCollideStaged = Join-Path $syncCollideStaging ".rundot-sync\evil.ts"
    [System.IO.File]::WriteAllBytes($syncCollideStaged, [byte[]](0x61))
    $syncCollideSnapshot = New-FakeSnapshot -StagingRoot $syncCollideStaging -Files @{
        '.rundot-sync/evil.ts' = New-FakeSnapshotEntry `
            -StagingPath $syncCollideStaged `
            -Sha256 (Get-FileSha256Hex -LiteralPath $syncCollideStaged) `
            -Size 1 `
            -Kind 'utf8' `
            -Encoding 'utf8'
    }

    $syncCollideThrown = $null
    try {
        Import-RundotRemoteSnapshot `
            -LocalDir $syncCollideDir `
            -ProjectId 'proj-test-1' `
            -Snapshot $syncCollideSnapshot | Out-Null
    }
    catch {
        $syncCollideThrown = $_.Exception
    }
    Assert-True ($null -ne $syncCollideThrown) "a remote path inside .rundot-sync must refuse"
    if ($null -ne $syncCollideThrown) {
        Assert-True `
            ($syncCollideThrown.Message -match [regex]::Escape('.rundot-sync')) `
            "the sync-state refusal should name .rundot-sync"
    }
    Assert-True `
        (-not (Test-Path -LiteralPath (Join-Path $syncCollideDir ".rundot-sync\evil.ts"))) `
        "a refused remote path must not be written into sync state"
    Assert-Null `
        (Read-BaseManifest -WorkspaceRoot $syncCollideDir) `
        "a sync-state collision must not write BASE"

    # ----------------------------------------------------------------------
    # Failure partway through promotion rolls back the entries already moved
    # ----------------------------------------------------------------------

    $partialDir = Join-Path $fromRemoteRoot "partial-move"
    $partialStaging = New-FakeStagingRoot -LocalDir $partialDir
    New-Item -ItemType Directory -Path (Join-Path $partialStaging "a") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $partialStaging "b") -Force | Out-Null
    $partialA = Join-Path $partialStaging "a\a.ts"
    $partialB = Join-Path $partialStaging "b\b.ts"
    [System.IO.File]::WriteAllBytes($partialA, [byte[]](0x61))
    [System.IO.File]::WriteAllBytes($partialB, [byte[]](0x62))
    $partialSnapshot = New-FakeSnapshot -StagingRoot $partialStaging -Files @{
        'a/a.ts' = New-FakeSnapshotEntry `
            -StagingPath $partialA `
            -Sha256 (Get-FileSha256Hex -LiteralPath $partialA) `
            -Size 1 `
            -Kind 'utf8' `
            -Encoding 'utf8'
        'b/b.ts' = New-FakeSnapshotEntry `
            -StagingPath $partialB `
            -Sha256 (Get-FileSha256Hex -LiteralPath $partialB) `
            -Size 1 `
            -Kind 'utf8' `
            -Encoding 'utf8'
    }

    # Shadow the cmdlet so the second rename fails, leaving a half-promoted
    # tree that must be rolled back.
    $script:InjectedMoveItemCalls = 0
    function Move-Item {
        param(
            [Parameter(ValueFromPipeline)]
            [string]$LiteralPath,

            [string]$Destination,

            [switch]$Force
        )

        $script:InjectedMoveItemCalls++
        if ($script:InjectedMoveItemCalls -eq 2) {
            throw [System.InvalidOperationException]::new("Injected rename failure.")
        }

        Microsoft.PowerShell.Management\Move-Item `
            -LiteralPath $LiteralPath `
            -Destination $Destination
    }

    $partialThrown = $null
    try {
        Import-RundotRemoteSnapshot `
            -LocalDir $partialDir `
            -ProjectId 'proj-test-1' `
            -Snapshot $partialSnapshot | Out-Null
    }
    catch {
        $partialThrown = $_.Exception
    }
    finally {
        Remove-Item -Path function:Move-Item -ErrorAction SilentlyContinue
    }

    Assert-True ($null -ne $partialThrown) "a rename failure partway through promotion must propagate"
    Assert-Equal `
        0 `
        @(Get-TestTopLevelEntries -Dir $partialDir).Count `
        "a failed promotion must not leave a half-promoted tree in LocalDir"
    Assert-True `
        ((Test-Path -LiteralPath $partialA) -or (Test-Path -LiteralPath (Join-Path $partialDir "a\a.ts"))) `
        "a failed promotion must preserve the staged data instead of destroying it"
    Assert-Null `
        (Read-BaseManifest -WorkspaceRoot $partialDir) `
        "a failed promotion must not write BASE"
    Assert-True `
        ((Get-Command Move-Item -CommandType Cmdlet) -ne $null) `
        "Init.Tests must restore the real Move-Item cmdlet"

    # ----------------------------------------------------------------------
    # Fabricated snapshot: a path the destination cannot represent
    # ----------------------------------------------------------------------

    $unsafeDir = Join-Path $fromRemoteRoot "unsafe-path"
    $unsafeStaging = New-FakeStagingRoot -LocalDir $unsafeDir
    $unsafeFile = Join-Path $unsafeStaging "unsafe.ts"
    [System.IO.File]::WriteAllBytes($unsafeFile, [byte[]](0x61))
    $unsafeSnapshot = New-FakeSnapshot -StagingRoot $unsafeStaging -Files @{
        'a<b>.ts' = New-FakeSnapshotEntry `
            -StagingPath $unsafeFile `
            -Sha256 (Get-FileSha256Hex -LiteralPath $unsafeFile) `
            -Size 1 `
            -Kind 'utf8' `
            -Encoding 'utf8'
    }

    Assert-Throws {
        Import-RundotRemoteSnapshot `
            -LocalDir $unsafeDir `
            -ProjectId 'proj-test-1' `
            -Snapshot $unsafeSnapshot
    } "a canonical path the destination cannot represent must abort before promoting"
    Assert-Null `
        (Read-BaseManifest -WorkspaceRoot $unsafeDir) `
        "an unrepresentable path must not write BASE"

    # ----------------------------------------------------------------------
    # BASE write failure: promoted files roll back so no partial tree stands
    # ----------------------------------------------------------------------

    $baseFailDir = Join-Path $fromRemoteRoot "base-write-failure"
    New-Item -ItemType Directory -Path $baseFailDir -Force | Out-Null
    $baseFailStaging = New-FakeStagingRoot -LocalDir $baseFailDir
    New-Item -ItemType Directory -Path (Join-Path $baseFailStaging "src") -Force | Out-Null
    $baseFailFile = Join-Path $baseFailStaging "src\a.ts"
    [System.IO.File]::WriteAllBytes($baseFailFile, [byte[]](0x61))
    $baseFailSnapshot = New-FakeSnapshot -StagingRoot $baseFailStaging -Files @{
        'src/a.ts' = New-FakeSnapshotEntry `
            -StagingPath $baseFailFile `
            -Sha256 (Get-FileSha256Hex -LiteralPath $baseFailFile) `
            -Size 1 `
            -Kind 'utf8' `
            -Encoding 'utf8'
    }

    $realSaveBaseManifest = ${function:Save-BaseManifest}
    function Save-BaseManifest {
        param([string]$WorkspaceRoot, [string]$ProjectId, $Files)
        throw [System.InvalidOperationException]::new("Injected BASE write failure.")
    }

    $baseFailThrown = $null
    try {
        Import-RundotRemoteSnapshot `
            -LocalDir $baseFailDir `
            -ProjectId 'proj-test-1' `
            -Snapshot $baseFailSnapshot | Out-Null
    }
    catch {
        $baseFailThrown = $_.Exception
    }
    finally {
        Set-Item -Path function:Save-BaseManifest -Value $realSaveBaseManifest
    }

    Assert-True ($null -ne $baseFailThrown) "a BASE write failure must propagate"
    if ($null -ne $baseFailThrown) {
        Assert-True `
            ($baseFailThrown.Message -match '(?i)no base was written') `
            "a BASE write failure should state that no BASE was written"
    }
    Assert-Null `
        (Read-BaseManifest -WorkspaceRoot $baseFailDir) `
        "a BASE write failure must not leave a BASE"
    Assert-Equal `
        0 `
        @(Get-TestTopLevelEntries -Dir $baseFailDir).Count `
        "a BASE write failure must roll the promoted tree back out of LocalDir"
    Assert-True `
        (Test-Path -LiteralPath (Join-Path $baseFailStaging "src\a.ts")) `
        "a rolled-back promotion should preserve the staged data instead of destroying it"

    # The injected failure must not outlive this block, for the same
    # shared-scope reason as the remote stubs above.
    Assert-True `
        ((Get-Command Save-BaseManifest -CommandType Function).Definition -match 'base-manifest\.json\.tmp') `
        "Init.Tests must restore the real Save-BaseManifest after injecting a failure"

    # ----------------------------------------------------------------------
    # Reserved-path precision: refuse only what would actually be clobbered
    #
    # The collision check keys on the leading segment of a remote path and on
    # which metadata actually exists locally. These two cases are a matched
    # pair proving it is neither too broad nor too narrow.
    # ----------------------------------------------------------------------

    # A remote .gitignore into a destination that has none is ordinary project
    # content, and must be promoted.
    $noIgnoreDir = Join-Path $fromRemoteRoot "promote-gitignore"
    $noIgnoreStaging = New-FakeStagingRoot -LocalDir $noIgnoreDir
    $noIgnoreStaged = Join-Path $noIgnoreStaging ".gitignore"
    [System.IO.File]::WriteAllBytes($noIgnoreStaged, [byte[]](0x61))
    $noIgnoreSnapshot = New-FakeSnapshot -StagingRoot $noIgnoreStaging -Files @{
        '.gitignore' = New-FakeSnapshotEntry `
            -StagingPath $noIgnoreStaged `
            -Sha256 (Get-FileSha256Hex -LiteralPath $noIgnoreStaged) `
            -Size 1 `
            -Kind 'utf8' `
            -Encoding 'utf8'
    }

    $noIgnoreResult = Import-RundotRemoteSnapshot `
        -LocalDir $noIgnoreDir `
        -ProjectId 'proj-test-1' `
        -Snapshot $noIgnoreSnapshot

    Assert-Equal 1 $noIgnoreResult.FileCount "a remote .gitignore must be promoted when no local one exists"
    Assert-True `
        (Test-Path -LiteralPath (Join-Path $noIgnoreDir ".gitignore")) `
        "the promoted .gitignore should exist in LocalDir"
    Assert-True `
        ($null -ne (Read-BaseManifest -WorkspaceRoot $noIgnoreDir)) `
        "promoting a remote .gitignore should still write BASE"

    # A remote path under a retained .git directory must refuse, not just
    # .gitignore: the check walks the leading segment for any retained name.
    $gitDirCollide = Join-Path $fromRemoteRoot "git-dir-collision"
    New-Item -ItemType Directory -Path (Join-Path $gitDirCollide ".git") -Force | Out-Null
    $gitDirStaging = New-FakeStagingRoot -LocalDir $gitDirCollide
    New-Item -ItemType Directory -Path (Join-Path $gitDirStaging ".git") -Force | Out-Null
    $gitDirStaged = Join-Path $gitDirStaging ".git\config"
    [System.IO.File]::WriteAllBytes($gitDirStaged, [byte[]](0x61))
    $gitDirSnapshot = New-FakeSnapshot -StagingRoot $gitDirStaging -Files @{
        '.git/config' = New-FakeSnapshotEntry `
            -StagingPath $gitDirStaged `
            -Sha256 (Get-FileSha256Hex -LiteralPath $gitDirStaged) `
            -Size 1 `
            -Kind 'utf8' `
            -Encoding 'utf8'
    }

    $gitDirThrown = $null
    try {
        Import-RundotRemoteSnapshot `
            -LocalDir $gitDirCollide `
            -ProjectId 'proj-test-1' `
            -Snapshot $gitDirSnapshot | Out-Null
    }
    catch {
        $gitDirThrown = $_.Exception
    }
    Assert-True ($null -ne $gitDirThrown) "a remote path under a retained .git must refuse"
    Assert-Null `
        (Read-BaseManifest -WorkspaceRoot $gitDirCollide) `
        "a .git collision must not write BASE"

    # A malformed snapshot must be rejected before any promotion.
    $badSnapshotDir = Join-Path $fromRemoteRoot "bad-snapshot"
    Assert-RundotSyncInitDestination -LocalDir $badSnapshotDir
    Assert-Throws {
        Import-RundotRemoteSnapshot `
            -LocalDir $badSnapshotDir `
            -ProjectId 'proj-test-1' `
            -Snapshot ([pscustomobject]@{ Files = @(); StagingRoot = 'unused' })
    } "a snapshot whose Files is not a file map must refuse rather than promote nothing"
    Assert-Null `
        (Read-BaseManifest -WorkspaceRoot $badSnapshotDir) `
        "a malformed snapshot must not write BASE"
}
finally {
    if (Test-Path -LiteralPath $fromRemoteRoot) {
        Remove-Item -LiteralPath $fromRemoteRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}


# --------------------------------------------------------------------------
# Init Adopt: attach metadata without claiming unproven agreement
#
# Only path+hash-identical entries may enter BASE. Everything else is
# unresolved and is reported, never recorded as a safe sync direction.
# --------------------------------------------------------------------------

function New-FakeLocalManifestEntry {
    param(
        [string]$LiteralPath,
        [string]$Kind = 'utf8'
    )

    $identity = Get-LocalFileIdentity -LiteralPath $LiteralPath
    return [pscustomobject]@{
        Sha256            = $identity.Sha256
        Size              = $identity.Size
        LocalDetectedKind = $identity.LocalDetectedKind
        LineEnding        = $identity.LineEnding
        HasBom            = $identity.HasBom
    }
}

function Get-AdoptStatusFor {
    param(
        [object[]]$Comparisons,
        [string]$Path
    )

    foreach ($row in @($Comparisons)) {
        if ([string]::Equals([string]$row.Path, $Path, [System.StringComparison]::Ordinal)) {
            return [string]$row.Status
        }
    }

    return $null
}

$adoptRoot = Join-Path $env:TEMP ("rundot-init-adopt-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $adoptRoot | Out-Null

try {
    # ----------------------------------------------------------------------
    # Comparison unit cases: the four required outcomes
    # ----------------------------------------------------------------------

    $unitDir = Join-Path $adoptRoot "unit"
    New-Item -ItemType Directory -Path (Join-Path $unitDir "src") -Force | Out-Null
    $sameFile = Join-Path $unitDir "src\same.ts"
    $editedFile = Join-Path $unitDir "src\edited.ts"
    $localOnlyFile = Join-Path $unitDir "notes.md"
    [System.IO.File]::WriteAllBytes($sameFile, $initUtf8.GetBytes('aaa'))
    [System.IO.File]::WriteAllBytes($editedFile, $initUtf8.GetBytes('local'))
    [System.IO.File]::WriteAllBytes($localOnlyFile, $initUtf8.GetBytes('local-only'))

    $unitLocal = @{
        'src/same.ts'   = New-FakeLocalManifestEntry -LiteralPath $sameFile
        'src/edited.ts' = New-FakeLocalManifestEntry -LiteralPath $editedFile
        'notes.md'      = New-FakeLocalManifestEntry -LiteralPath $localOnlyFile
    }

    # Build a remote-side map with the same shape the snapshot produces.
    function New-FakeRemoteIdentityEntry {
        param(
            [string]$StagingPath,
            [string]$Encoding = 'utf8'
        )

        $identity = Get-LocalFileIdentity -LiteralPath $StagingPath
        return New-FakeSnapshotEntry `
            -StagingPath $StagingPath `
            -Sha256 $identity.Sha256 `
            -Size $identity.Size `
            -Kind $identity.LocalDetectedKind `
            -Encoding $Encoding
    }

    $unitStaging = Join-Path $adoptRoot "unit-staging"
    New-Item -ItemType Directory -Path (Join-Path $unitStaging "src") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $unitStaging "dist") -Force | Out-Null
    $remoteSame = Join-Path $unitStaging "src\same.ts"
    $remoteEdited = Join-Path $unitStaging "src\edited.ts"
    $remoteOnly = Join-Path $unitStaging "src\new.ts"
    $remoteIgnored = Join-Path $unitStaging "dist\bundle.js"
    $remoteSyncState = Join-Path $unitStaging "dist\shadow.ts"
    [System.IO.File]::WriteAllBytes($remoteSame, $initUtf8.GetBytes('aaa'))
    [System.IO.File]::WriteAllBytes($remoteEdited, $initUtf8.GetBytes('remote'))
    [System.IO.File]::WriteAllBytes($remoteOnly, $initUtf8.GetBytes('remote-only'))
    [System.IO.File]::WriteAllBytes($remoteIgnored, $initUtf8.GetBytes('ignored'))
    [System.IO.File]::WriteAllBytes($remoteSyncState, $initUtf8.GetBytes('shadow'))

    $unitRemote = @{
        'src/same.ts'      = New-FakeRemoteIdentityEntry -StagingPath $remoteSame
        'src/edited.ts'    = New-FakeRemoteIdentityEntry -StagingPath $remoteEdited
        'src/new.ts'       = New-FakeRemoteIdentityEntry -StagingPath $remoteOnly
        'dist/bundle.js'   = New-FakeRemoteIdentityEntry -StagingPath $remoteIgnored
        '.rundot-sync/shadow.ts' = New-FakeRemoteIdentityEntry -StagingPath $remoteSyncState
    }

    $unitComparisons = @(
        Get-RundotSyncAdoptComparisons `
            -LocalManifest $unitLocal `
            -Snapshot (New-FakeSnapshot -StagingRoot $unitStaging -Files $unitRemote)
    )

    Assert-Equal `
        'Identical' `
        (Get-AdoptStatusFor -Comparisons $unitComparisons -Path 'src/same.ts') `
        "identical path+hash must classify as Identical"
    Assert-Equal `
        'Conflict' `
        (Get-AdoptStatusFor -Comparisons $unitComparisons -Path 'src/edited.ts') `
        "differing contents must classify as Conflict"
    Assert-Equal `
        'LocalOnly' `
        (Get-AdoptStatusFor -Comparisons $unitComparisons -Path 'notes.md') `
        "a local-only path must classify as LocalOnly"
    Assert-Equal `
        'RemoteOnly' `
        (Get-AdoptStatusFor -Comparisons $unitComparisons -Path 'src/new.ts') `
        "a remote-only path must classify as RemoteOnly"
    Assert-Equal `
        'IgnoredRemote' `
        (Get-AdoptStatusFor -Comparisons $unitComparisons -Path 'dist/bundle.js') `
        "a remote path matching the default ignore set must not be RemoteOnly"
    Assert-Equal `
        'IgnoredRemote' `
        (Get-AdoptStatusFor -Comparisons $unitComparisons -Path '.rundot-sync/shadow.ts') `
        "a remote path inside .rundot-sync must never be a download candidate"

    # LOCAL (3) union REMOTE (5), sharing src/same.ts and src/edited.ts -> 6.
    Assert-Equal `
        6 `
        @($unitComparisons).Count `
        "every path in LOCAL union REMOTE should get exactly one comparison row"

    # A conflict row must carry both hashes so the report can show them.
    $conflictRow = $null
    foreach ($row in @($unitComparisons)) {
        if ([string]$row.Path -eq 'src/edited.ts') { $conflictRow = $row }
    }
    Assert-True ($null -ne $conflictRow) "the conflict row should be present"
    if ($null -ne $conflictRow) {
        Assert-Equal `
            (Get-FileSha256Hex -LiteralPath $editedFile) `
            $conflictRow.LocalSha256 `
            "a conflict row should carry the local hash"
        Assert-Equal `
            (Get-FileSha256Hex -LiteralPath $remoteEdited) `
            $conflictRow.RemoteSha256 `
            "a conflict row should carry the remote hash"
        Assert-True `
            ($conflictRow.LocalSha256 -ne $conflictRow.RemoteSha256) `
            "a conflict must have genuinely different hashes"
    }

    # Identical is the only status that may enter BASE.
    $baseCandidateCount = 0
    foreach ($row in @($unitComparisons)) {
        if ([string]$row.Status -eq 'Identical') { $baseCandidateCount++ }
    }
    Assert-Equal 1 $baseCandidateCount "only Identical rows may become BASE entries"

    # ----------------------------------------------------------------------
    # End-to-end Adopt against a real tree
    # ----------------------------------------------------------------------

    $adoptDir = Join-Path $adoptRoot "tree"
    New-Item -ItemType Directory -Path (Join-Path $adoptDir "src") -Force | Out-Null
    $adoptSame = Join-Path $adoptDir "src\same.ts"
    $adoptEdited = Join-Path $adoptDir "src\edited.ts"
    $adoptLocalOnly = Join-Path $adoptDir "notes.md"
    [System.IO.File]::WriteAllBytes($adoptSame, $initUtf8.GetBytes("same`r`n"))
    [System.IO.File]::WriteAllBytes($adoptEdited, $initUtf8.GetBytes('local'))
    [System.IO.File]::WriteAllBytes($adoptLocalOnly, $initUtf8.GetBytes('notes'))

    $adoptSameEntry = New-FakeRemoteListEntry @{
        path = 'src/same.ts'; type = 'file'; size = 6; encoding = 'utf8'
    }
    $adoptEditedEntry = New-FakeRemoteListEntry @{
        path = 'src/edited.ts'; type = 'file'; size = 6; encoding = 'utf8'
    }
    $adoptNewEntry = New-FakeRemoteListEntry @{
        path = 'src/new.ts'; type = 'file'; size = 4; encoding = 'utf8'
    }
    $adoptIgnoredEntry = New-FakeRemoteListEntry @{
        path = 'dist/bundle.js'; type = 'file'; size = 7; encoding = 'utf8'
    }
    $adoptManifest = New-FakeRemoteManifest -Files @(
        $adoptSameEntry,
        $adoptEditedEntry,
        $adoptNewEntry,
        $adoptIgnoredEntry
    )

    Reset-FakeRemote `
        -Lists @($adoptManifest, $adoptManifest) `
        -Files @{
            'src/same.ts'    = [pscustomobject]@{ encoding = 'utf8'; content = "same`r`n" }
            'src/edited.ts'  = [pscustomobject]@{ encoding = 'utf8'; content = 'remote' }
            'src/new.ts'     = [pscustomobject]@{ encoding = 'utf8'; content = 'new!' }
            'dist/bundle.js' = [pscustomobject]@{ encoding = 'utf8'; content = 'ignored' }
        }

    $adoptResult = Initialize-RundotSyncByAdopt `
        -LocalDir $adoptDir `
        -ProjectId 'proj-test-1' `
        -StudioOrigin 'https://example.test' `
        -Headers $initHeaders

    Assert-Equal 1 $adoptResult.BaseFileCount "Adopt should record only the identical path in BASE"
    Assert-Equal 4 $adoptResult.UnresolvedCount "Adopt should report every unresolved path"

    $adoptBase = Read-BaseManifest -WorkspaceRoot $adoptDir
    Assert-True ($null -ne $adoptBase) "Adopt must write BASE"
    if ($null -ne $adoptBase) {
        Assert-BaseOwnership `
            -Base $adoptBase `
            -ProjectId 'proj-test-1' `
            -WorkspaceRoot $adoptDir
        Assert-True `
            ($null -ne $adoptBase.files.'src/same.ts') `
            "the identical path must be in BASE"
        Assert-Null `
            $adoptBase.files.'src/edited.ts' `
            "a conflicting path must not be in BASE"
        Assert-Null `
            $adoptBase.files.'notes.md' `
            "a local-only path must not be in BASE"
        Assert-Null `
            $adoptBase.files.'src/new.ts' `
            "a remote-only path must not be in BASE"
        Assert-Null `
            $adoptBase.files.'dist/bundle.js' `
            "an ignored remote path must not be in BASE"
        Assert-Equal `
            1 `
            @($adoptBase.files.PSObject.Properties).Count `
            "BASE must contain exactly the proven-identical entries"
        Assert-Equal `
            (Get-FileSha256Hex -LiteralPath $adoptSame) `
            $adoptBase.files.'src/same.ts'.sha256 `
            "the Adopt BASE entry should hash the local bytes that were proven identical"
        Assert-Equal `
            'crlf' `
            $adoptBase.files.'src/same.ts'.lineEnding `
            "the Adopt BASE entry should keep byte-derived diagnostics"
    }

    # The report must name the unresolved paths so the user can act on them.
    $report = [string]$adoptResult.Report
    Assert-True ($report -match [regex]::Escape('src/edited.ts')) "the report should name a conflicting path"
    Assert-True ($report -match [regex]::Escape('notes.md')) "the report should name a local-only path"
    Assert-True ($report -match [regex]::Escape('src/new.ts')) "the report should name a remote-only path"
    Assert-True ($report -match [regex]::Escape('dist/bundle.js')) "the report should name an ignored path"
    Assert-True ($report -match '(?i)conflict') "the report should label conflicts"
    Assert-True ($report -match '(?i)local-only') "the report should label local-only paths"
    Assert-True ($report -match '(?i)remote-only') "the report should label remote-only paths"
    Assert-True `
        ($report -notmatch '(?i)bearer|test-token') `
        "the Adopt report must never contain tokens"

    # Adopt must not modify the local tree it attaches to.
    Assert-Equal `
        $initUtf8.GetBytes('local') `
        ([System.IO.File]::ReadAllBytes($adoptEdited)) `
        "Adopt must not rewrite a locally-edited file"
    Assert-True `
        (-not (Test-Path -LiteralPath (Join-Path $adoptDir "src\new.ts"))) `
        "Adopt must not download remote-only files into the tree"

    # ----------------------------------------------------------------------
    # Adopt with nothing provably identical is still honest, not silent
    # ----------------------------------------------------------------------

    $noMatchDir = Join-Path $adoptRoot "no-match"
    New-Item -ItemType Directory -Path $noMatchDir -Force | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $noMatchDir "only-local.ts"), $initUtf8.GetBytes('local'))
    Reset-FakeRemote -Lists @($emptyManifest, $emptyManifest) -Files @{}

    $noMatchResult = Initialize-RundotSyncByAdopt `
        -LocalDir $noMatchDir `
        -ProjectId 'proj-test-1' `
        -StudioOrigin 'https://example.test' `
        -Headers $initHeaders

    Assert-Equal 0 $noMatchResult.BaseFileCount "Adopt with no identical paths must record no BASE entries"
    Assert-True `
        ([string]$noMatchResult.Report -match '(?i)untrusted|no proven') `
        "an all-unresolved Adopt must warn that direction is untrusted"

    $noMatchBase = Read-BaseManifest -WorkspaceRoot $noMatchDir
    Assert-True ($null -ne $noMatchBase) "Adopt should still write BASE when nothing is identical"
    if ($null -ne $noMatchBase) {
        Assert-Equal `
            0 `
            @($noMatchBase.files.PSObject.Properties).Count `
            "an all-unresolved Adopt must produce a zero-entry BASE, not guesses"
    }

    # ----------------------------------------------------------------------
    # Adopt refuses to discard an existing verified BASE
    # ----------------------------------------------------------------------

    $existingThrown = $null
    try {
        Initialize-RundotSyncByAdopt `
            -LocalDir $adoptDir `
            -ProjectId 'proj-test-1' `
            -StudioOrigin 'https://example.test' `
            -Headers $initHeaders | Out-Null
    }
    catch {
        $existingThrown = $_.Exception
    }
    Assert-True ($null -ne $existingThrown) "Adopt must refuse a tree that already has a BASE"
    if ($null -ne $existingThrown) {
        Assert-True `
            ($existingThrown.Message -match '(?i)already') `
            "the existing-BASE refusal should say the workspace is already initialized"
    }
    $stillThere = Read-BaseManifest -WorkspaceRoot $adoptDir
    if ($null -ne $stillThere) {
        Assert-True `
            ($null -ne $stillThere.files.'src/same.ts') `
            "a refused Adopt must leave the existing BASE intact"
    }
    else {
        Assert-True $false "a refused Adopt must leave the existing BASE intact"
    }
}
finally {
    if (Test-Path -LiteralPath $adoptRoot) {
        Remove-Item -LiteralPath $adoptRoot -Recurse -Force -ErrorAction SilentlyContinue
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
