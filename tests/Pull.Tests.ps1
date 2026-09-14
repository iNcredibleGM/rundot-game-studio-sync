# Pull action selection and overwrite policy contracts.
#
# Pull may write LOCAL for exactly one classification: a clean download
# (BASE=A LOCAL=A REMOTE=B). Everything else is excluded, and a download that
# replaces an existing local file is flagged as an overwrite so the caller can
# count it, confirm it, and back it up first.
#
# Do not require Pester. No network.
#
# SCOPE NOTE: tests/Run-Tests.ps1 dot-sources every *.Tests.ps1 into one
# scope, in filename order. This file sorts after Paths.Tests.ps1 and before
# RemoteApi.Tests.ps1. Helpers here are prefixed New-PullTest* /
# Get-PullTest* / Assert-PullTest* so they never shadow a library function
# another test file needs. No remote helper is stubbed here, so nothing leaks
# forward.

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "lib\Paths.ps1")
. (Join-Path $repoRoot "lib\Ignore.ps1")
. (Join-Path $repoRoot "lib\Hashing.ps1")
. (Join-Path $repoRoot "lib\Workspace.ps1")
. (Join-Path $repoRoot "lib\Manifest.ps1")
. (Join-Path $repoRoot "lib\Snapshot.ps1")
. (Join-Path $repoRoot "lib\Classifier.ps1")
. (Join-Path $repoRoot "lib\Plan.ps1")
. (Join-Path $repoRoot "lib\Backup.ps1")
. (Join-Path $repoRoot "lib\Journal.ps1")
. (Join-Path $repoRoot "lib\Pull.ps1")

$pullTestShaA = 'a' * 64
$pullTestShaB = 'b' * 64
$pullTestShaC = 'c' * 64


# --------------------------------------------------------------------------
# Fixtures in the real on-disk shapes the classifier reads
# --------------------------------------------------------------------------

function New-PullTestBaseEntry {
    param(
        [string]$Sha256,
        [int64]$Size = 0,
        [string]$Kind = 'utf8',
        $LineEnding = 'lf',
        $HasBom = $false
    )

    $entry = [pscustomobject]@{
        sha256 = $Sha256
        size   = $Size
        kind   = $Kind
    }

    if ($Kind -eq 'utf8') {
        $entry | Add-Member -NotePropertyName lineEnding -NotePropertyValue $LineEnding
        $entry | Add-Member -NotePropertyName hasBom -NotePropertyValue $HasBom
    }

    return $entry
}

function New-PullTestLocalEntry {
    param(
        [string]$Sha256,
        [int64]$Size = 0,
        [string]$Kind = 'utf8'
    )

    return [pscustomobject]@{
        Sha256            = $Sha256
        Size              = $Size
        LocalDetectedKind = $Kind
        LineEnding        = 'lf'
        HasBom            = $false
    }
}

function New-PullTestRemoteEntry {
    param(
        [string]$Sha256,
        [int64]$Size = 0,
        [string]$Kind = 'utf8',
        [string]$Encoding = 'utf8',
        [string]$StagingPath = $null
    )

    if ([string]::IsNullOrEmpty($StagingPath)) {
        $StagingPath = "C:\staging\$Sha256"
    }

    return [pscustomobject]@{
        Sha256            = $Sha256
        Size              = $Size
        LocalDetectedKind = $Kind
        RemoteKind        = $Kind
        Encoding          = $Encoding
        StagingPath       = $StagingPath
    }
}

function Get-PullTestActionForPath {
    param(
        [object[]]$Actions,
        [string]$Path
    )

    foreach ($action in @($Actions)) {
        if ([string]::Equals([string]$action.Path, $Path, [System.StringComparison]::Ordinal)) {
            return $action
        }
    }

    return $null
}

function Get-PullTestExcludedForPath {
    param(
        [object[]]$Excluded,
        [string]$Path
    )

    foreach ($row in @($Excluded)) {
        if ([string]::Equals([string]$row.Path, $Path, [System.StringComparison]::Ordinal)) {
            return $row
        }
    }

    return $null
}

function Assert-PullTestExcluded {
    param(
        [object[]]$Excluded,
        [string]$Path,
        [string]$ExpectedStatus,
        [string]$Message
    )

    $row = Get-PullTestExcludedForPath -Excluded $Excluded -Path $Path
    if ($null -eq $row) {
        Assert-True $false ("expected '$Path' to be excluded (" + $Message + ")")
        return
    }

    Assert-Equal $ExpectedStatus ([string]$row.Status) ("excluded status for '$Path': " + $Message)
    Assert-True `
        (-not [string]::IsNullOrEmpty([string]$row.Reason)) `
        ("an excluded path must explain why ('$Path': " + $Message + ")")

    return
}


# --------------------------------------------------------------------------
# The only automatic local write: a clean download
# --------------------------------------------------------------------------

$pullBaseA = New-PullTestBaseEntry -Sha256 $pullTestShaA
$pullLocalA = New-PullTestLocalEntry -Sha256 $pullTestShaA
$pullRemoteA = New-PullTestRemoteEntry -Sha256 $pullTestShaA -StagingPath 'C:\staging\a.ts'
$pullRemoteB = New-PullTestRemoteEntry -Sha256 $pullTestShaB -StagingPath 'C:\staging\b.ts'

# BASE=A LOCAL=A REMOTE=B: remote-only change, LOCAL still matches BASE.
$downloadBase = @{ 'src/a.ts' = $pullBaseA }
$downloadLocal = @{ 'src/a.ts' = $pullLocalA }
$downloadRemote = @{ 'src/a.ts' = $pullRemoteB }

$downloadSelection = Get-SyncPullSelection `
    -Base $downloadBase `
    -Local $downloadLocal `
    -Remote $downloadRemote

Assert-Equal 1 @($downloadSelection.Actions).Count "a clean download must be the one apply candidate"
Assert-Equal 0 @($downloadSelection.Excluded).Count "a clean download must not be excluded"

$downloadAction = Get-PullTestActionForPath -Actions $downloadSelection.Actions -Path 'src/a.ts'
Assert-True ($null -ne $downloadAction) "the clean download must produce an action row"
if ($null -ne $downloadAction) {
    Assert-Equal 'download' ([string]$downloadAction.Status) "an action row must carry the download status"
    Assert-Equal `
        $pullTestShaB `
        ([string]$downloadAction.RemoteSha256) `
        "an action row must carry the remote hash to verify against"
    Assert-Equal `
        $pullTestShaA `
        ([string]$downloadAction.LocalSha256) `
        "an action row must carry the local hash it is replacing"
    Assert-Equal `
        'C:\staging\b.ts' `
        ([string]$downloadAction.RemoteStagingPath) `
        "an action row must carry the staged source path to copy from"
    Assert-Equal $true $downloadAction.IsOverwrite "replacing an existing local file must be flagged an overwrite"
}

# A remote-only addition has no local file to preserve: it is a create.
$createSelection = Get-SyncPullSelection `
    -Base @{} `
    -Local @{} `
    -Remote @{ 'src/new.ts' = (New-PullTestRemoteEntry -Sha256 $pullTestShaA -StagingPath 'C:\staging\new.ts') }

Assert-Equal 1 @($createSelection.Actions).Count "a remote-only path must be an apply candidate"
$createAction = Get-PullTestActionForPath -Actions $createSelection.Actions -Path 'src/new.ts'
Assert-True ($null -ne $createAction) "a remote-only path must produce an action row"
if ($null -ne $createAction) {
    Assert-Equal `
        $false `
        $createAction.IsOverwrite `
        "creating a file that does not exist locally must not be flagged an overwrite"
}


# --------------------------------------------------------------------------
# Everything else is excluded, with a reason
#
# Neither LOCAL nor REMOTE is authoritative: an ambiguity is a conflict, never
# a guess, and Pull only ever moves REMOTE content that BASE already agrees
# LOCAL does not own.
# --------------------------------------------------------------------------

$exclusionBase = @{
    'src/upload.ts'     = $pullBaseA
    'src/conflict.ts'   = $pullBaseA
    'src/kinds.ts'      = $pullBaseA
    'src/localgone.ts'  = $pullBaseA
    'src/remotegone.ts' = $pullBaseA
    'src/settled.ts'    = $pullBaseA
    'src/synced.ts'     = $pullBaseA
}
$exclusionLocal = @{
    'src/upload.ts'    = (New-PullTestLocalEntry -Sha256 $pullTestShaB)
    'src/conflict.ts'  = (New-PullTestLocalEntry -Sha256 $pullTestShaB)
    'src/kinds.ts'     = (New-PullTestLocalEntry -Sha256 $pullTestShaB -Kind 'binary')
    'src/remotegone.ts' = $pullLocalA
    'src/settled.ts'   = $pullLocalA
    'src/newlocal.ts'  = (New-PullTestLocalEntry -Sha256 $pullTestShaA)
    'src/synced.ts'    = $pullLocalA
}
$exclusionRemote = @{
    'src/upload.ts'    = $pullRemoteA
    'src/conflict.ts'  = (New-PullTestRemoteEntry -Sha256 $pullTestShaC)
    'src/kinds.ts'     = $pullRemoteA
    'src/localgone.ts' = $pullRemoteA
    'src/settled.ts'   = $pullRemoteB
    'src/synced.ts'    = $pullRemoteA
}

$exclusionSelection = Get-SyncPullSelection `
    -Base $exclusionBase `
    -Local $exclusionLocal `
    -Remote $exclusionRemote

Assert-Equal `
    1 `
    @($exclusionSelection.Actions).Count `
    "only the clean download in the exclusion fixture may be an apply candidate"

# A local-only change must never be overwritten by a pull.
Assert-PullTestExcluded `
    -Excluded $exclusionSelection.Excluded `
    -Path 'src/upload.ts' `
    -ExpectedStatus 'upload' `
    -Message 'BASE=A LOCAL=B REMOTE=A is a local change, not a pull'
$uploadExcluded = Get-PullTestExcludedForPath -Excluded $exclusionSelection.Excluded -Path 'src/upload.ts'
if ($null -ne $uploadExcluded) {
    Assert-True `
        (([string]$uploadExcluded.Reason) -notmatch '(?i)pull may|will overwrite') `
        "the upload exclusion reason must not imply Pull will overwrite the local change"
}

# An unresolvable three-way difference is a conflict.
Assert-PullTestExcluded `
    -Excluded $exclusionSelection.Excluded `
    -Path 'src/conflict.ts' `
    -ExpectedStatus 'conflict' `
    -Message 'BASE=A LOCAL=B REMOTE=C has no safe direction'

# A text <-> binary change with differing content is unsupported.
$kindExcluded = Get-PullTestExcludedForPath -Excluded $exclusionSelection.Excluded -Path 'src/kinds.ts'
Assert-True ($null -ne $kindExcluded) "a kind change must be excluded from a pull"
if ($null -ne $kindExcluded) {
    Assert-Equal 'conflict' ([string]$kindExcluded.Status) "a kind change must classify as a conflict"
    Assert-Equal $true $kindExcluded.KindChange "a kind change must be flagged"
    Assert-True `
        (([string]$kindExcluded.Reason) -match '(?i)kind') `
        "a kind-change exclusion must name the kind change"
}

# REMOTE no longer has the path: Pull reports it and leaves the local file
# alone. Silent local deletion is not part of this milestone.
Assert-PullTestExcluded `
    -Excluded $exclusionSelection.Excluded `
    -Path 'src/remotegone.ts' `
    -ExpectedStatus 'deleteLocalCandidate' `
    -Message 'BASE=A LOCAL=A REMOTE missing must not delete anything'
$deleteLocalExcluded = Get-PullTestExcludedForPath -Excluded $exclusionSelection.Excluded -Path 'src/remotegone.ts'
if ($null -ne $deleteLocalExcluded) {
    Assert-True `
        (([string]$deleteLocalExcluded.Reason) -match '(?i)leaves the local file|local file in place') `
        "the deleteLocalCandidate exclusion must say the local file is left in place"
}

# LOCAL is gone but REMOTE still has it: a standing remote-delete candidate is
# reported, never applied by Pull.
Assert-PullTestExcluded `
    -Excluded $exclusionSelection.Excluded `
    -Path 'src/localgone.ts' `
    -ExpectedStatus 'deleteRemoteCandidate' `
    -Message 'BASE=A LOCAL missing REMOTE=A must not be pulled'

# Deletion already agreed on both sides is settled, not a pending action.
# (settled.ts in the status fixture below covers settledAbsent; in this
# fixture it is an ordinary download, asserted next.)
Assert-True `
    ($null -ne (Get-PullTestActionForPath -Actions $exclusionSelection.Actions -Path 'src/settled.ts')) `
    "BASE=A LOCAL=A REMOTE=B is a clean download even when other paths are excluded"
$settledAction = Get-PullTestActionForPath -Actions $exclusionSelection.Actions -Path 'src/settled.ts'
if ($null -ne $settledAction) {
    Assert-Equal $true $settledAction.IsOverwrite "the excluded fixture's clean download replaces an existing local file"
}

# A local-only addition is a future push candidate, not pull work.
Assert-PullTestExcluded `
    -Excluded $exclusionSelection.Excluded `
    -Path 'src/newlocal.ts' `
    -ExpectedStatus 'upload' `
    -Message 'a local-only addition must not be pulled'

# Two sides already agree on the new content: nothing to do.
Assert-PullTestExcluded `
    -Excluded $exclusionSelection.Excluded `
    -Path 'src/synced.ts' `
    -ExpectedStatus 'unchanged' `
    -Message 'an unchanged path must not be pulled'


# --------------------------------------------------------------------------
# Remaining statuses: no-op, ignored, and settled-absent are never applied
# --------------------------------------------------------------------------

$statusSelection = Get-SyncPullSelection `
    -Base @{
        'src/same.ts'    = $pullBaseA
        'src/both.ts'    = $pullBaseA
        'src/settled.ts' = $pullBaseA
        'dist/bundle.js' = $pullBaseA
    } `
    -Local @{
        'src/same.ts'  = $pullLocalA
        'src/both.ts'  = (New-PullTestLocalEntry -Sha256 $pullTestShaB)
        'dist/bundle.js' = (New-PullTestLocalEntry -Sha256 $pullTestShaB)
    } `
    -Remote @{
        'src/same.ts'    = (New-PullTestRemoteEntry -Sha256 $pullTestShaA)
        'src/both.ts'    = (New-PullTestRemoteEntry -Sha256 $pullTestShaB)
        'src/added.ts'   = (New-PullTestRemoteEntry -Sha256 $pullTestShaA)
    }

Assert-Equal 1 @($statusSelection.Actions).Count "only the remote-only path is pull work here"

Assert-PullTestExcluded `
    -Excluded $statusSelection.Excluded `
    -Path 'src/same.ts' `
    -ExpectedStatus 'unchanged' `
    -Message 'BASE=LOCAL=REMOTE is a no-op'
Assert-PullTestExcluded `
    -Excluded $statusSelection.Excluded `
    -Path 'src/both.ts' `
    -ExpectedStatus 'synchronized-change' `
    -Message 'LOCAL and REMOTE changed identically, so there is nothing to pull'
Assert-PullTestExcluded `
    -Excluded $statusSelection.Excluded `
    -Path 'src/settled.ts' `
    -ExpectedStatus 'settledAbsent' `
    -Message 'a deletion agreed on both sides is not a pending action'
Assert-PullTestExcluded `
    -Excluded $statusSelection.Excluded `
    -Path 'dist/bundle.js' `
    -ExpectedStatus 'ignored' `
    -Message 'an ignored path is out of sync scope'

$ignoredExcluded = Get-PullTestExcludedForPath -Excluded $statusSelection.Excluded -Path 'dist/bundle.js'
if ($null -ne $ignoredExcluded) {
    Assert-Equal $true $ignoredExcluded.Ignored "an ignored exclusion must carry the ignored flag"
}

# A synchronized addition (no BASE, both sides present and equal) is settled.
$syncAdditionSelection = Get-SyncPullSelection `
    -Base @{} `
    -Local @{ 'src/both.ts' = (New-PullTestLocalEntry -Sha256 $pullTestShaA) } `
    -Remote @{ 'src/both.ts' = (New-PullTestRemoteEntry -Sha256 $pullTestShaA) }

Assert-Equal 0 @($syncAdditionSelection.Actions).Count "a synchronized addition is not pull work"
Assert-PullTestExcluded `
    -Excluded $syncAdditionSelection.Excluded `
    -Path 'src/both.ts' `
    -ExpectedStatus 'synchronized-addition' `
    -Message 'untracked but identical on both sides'


# --------------------------------------------------------------------------
# The invariant that matters: an action is always a download, and an excluded
# path is never applied
# --------------------------------------------------------------------------

foreach ($action in @($exclusionSelection.Actions)) {
    Assert-Equal `
        'download' `
        ([string]$action.Status) `
        "every pull action must be a clean download ('$($action.Path)')"
}

foreach ($row in @($exclusionSelection.Excluded)) {
    Assert-True `
        (([string]$row.Status) -ne 'download') `
        "an excluded path must never be classified as an appliable download ('$($row.Path)')"
    Assert-True `
        (-not [string]::IsNullOrEmpty([string]$row.Reason)) `
        "every excluded path must carry a reason ('$($row.Path)')"
}


# --------------------------------------------------------------------------
# Ordering, determinism, and the overwrite subset
# --------------------------------------------------------------------------

$orderSelection = Get-SyncPullSelection `
    -Base @{} `
    -Local @{} `
    -Remote @{
        'z.ts'     = (New-PullTestRemoteEntry -Sha256 $pullTestShaA -StagingPath 'C:\staging\z.ts')
        'src/b.ts' = (New-PullTestRemoteEntry -Sha256 $pullTestShaA -StagingPath 'C:\staging\b.ts')
        'src/a.ts' = (New-PullTestRemoteEntry -Sha256 $pullTestShaA -StagingPath 'C:\staging\a.ts')
    }

Assert-Equal `
    @('src/a.ts', 'src/b.ts', 'z.ts') `
    @($orderSelection.Actions | ForEach-Object { [string]$_.Path }) `
    "pull actions must be ordinal-sorted by canonical path"

$orderAgain = Get-SyncPullSelection `
    -Base @{} `
    -Local @{} `
    -Remote @{
        'z.ts'     = (New-PullTestRemoteEntry -Sha256 $pullTestShaA -StagingPath 'C:\staging\z.ts')
        'src/b.ts' = (New-PullTestRemoteEntry -Sha256 $pullTestShaA -StagingPath 'C:\staging\b.ts')
        'src/a.ts' = (New-PullTestRemoteEntry -Sha256 $pullTestShaA -StagingPath 'C:\staging\a.ts')
    }
Assert-Equal `
    @($orderSelection.Actions | ForEach-Object { [string]$_.Path }) `
    @($orderAgain.Actions | ForEach-Object { [string]$_.Path }) `
    "pull action order must be deterministic across calls"

# Overwrite detection is what drives the confirmation prompt and the backup
# set, so it must count exactly the actions that replace an existing file.
$mixedSelection = Get-SyncPullSelection `
    -Base @{ 'src/edited.ts' = $pullBaseA } `
    -Local @{ 'src/edited.ts' = $pullLocalA } `
    -Remote @{
        'src/edited.ts' = (New-PullTestRemoteEntry -Sha256 $pullTestShaB -StagingPath 'C:\staging\edited.ts')
        'src/new.ts'    = (New-PullTestRemoteEntry -Sha256 $pullTestShaA -StagingPath 'C:\staging\new.ts')
    }

Assert-Equal 2 @($mixedSelection.Actions).Count "both paths are pull work"
Assert-Equal `
    1 `
    @($mixedSelection.Overwrites).Count `
    "only the existing local file counts as an overwrite"
Assert-Equal `
    1 `
    @(Get-SyncPullOverwriteRows -Actions $mixedSelection.Actions).Count `
    "the overwrite helper must agree with the selection"
Assert-Equal `
    'src/edited.ts' `
    ([string](Get-SyncPullOverwriteRows -Actions $mixedSelection.Actions)[0].Path) `
    "the overwrite subset must name the replaced path"

# A pull with no existing local files needs no confirmation at all.
Assert-Equal `
    0 `
    @(Get-SyncPullOverwriteRows -Actions $orderSelection.Actions).Count `
    "creating new files must require no overwrite confirmation"


# --------------------------------------------------------------------------
# Selection is a pure read: it mutates no input and writes no BASE
# --------------------------------------------------------------------------

$purityRoot = Join-Path $env:TEMP ("rundot-pull-selection-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $purityRoot | Out-Null

try {
    $purityBase = @{ 'src/a.ts' = $pullBaseA; 'src/b.ts' = $pullBaseA }
    $purityLocal = @{ 'src/a.ts' = $pullLocalA }
    $purityRemote = @{
        'src/a.ts' = $pullRemoteB
        'src/c.ts' = (New-PullTestRemoteEntry -Sha256 $pullTestShaC -StagingPath 'C:\staging\c.ts')
    }

    $purityBaseCount = $purityBase.Count
    $puritySentinel = [string]$purityBase['src/a.ts'].sha256

    [void](Get-SyncPullSelection -Base $purityBase -Local $purityLocal -Remote $purityRemote)

    Assert-Equal $purityBaseCount $purityBase.Count "selection must not add or remove BASE entries"
    Assert-Equal `
        $puritySentinel `
        ([string]$purityBase['src/a.ts'].sha256) `
        "selection must not rewrite a BASE entry"
    Assert-True `
        ($purityBase.ContainsKey('src/b.ts')) `
        "selection must not drop an unvisited BASE entry"
    Assert-Null `
        (Read-BaseManifest -WorkspaceRoot $purityRoot) `
        "selection must never write BASE"
}
finally {
    if (Test-Path -LiteralPath $purityRoot) {
        Remove-Item -LiteralPath $purityRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}


# ==========================================================================
# Apply, verify, and rollback
#
# These cases use real files on disk and a real stable-snapshot fixture, so a
# local write is exercised end to end without any network access.
# ==========================================================================

$pullApplyUtf8 = New-Object System.Text.UTF8Encoding $false

function New-PullTestWorkspace {
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    $workspace = Join-Path $Root ("ws-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $workspace | Out-Null
    return $workspace
}

function Write-PullTestBytes {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    $parent = Split-Path -Parent $LiteralPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    [System.IO.File]::WriteAllBytes($LiteralPath, $Bytes)
}

function Get-PullTestBytes {
    param([Parameter(Mandatory)][string]$LiteralPath)

    return [System.IO.File]::ReadAllBytes($LiteralPath)
}

function New-PullTestLocalManifestEntry {
    param([Parameter(Mandatory)][string]$LiteralPath)

    $identity = Get-LocalFileIdentity -LiteralPath $LiteralPath
    return [pscustomobject]@{
        Sha256            = $identity.Sha256
        Size              = $identity.Size
        LocalDetectedKind = $identity.LocalDetectedKind
        LineEnding        = $identity.LineEnding
        HasBom            = $identity.HasBom
    }
}

function New-PullTestRemoteIdentityEntry {
    param(
        [Parameter(Mandatory)][string]$StagingPath,
        [Parameter(Mandatory)][string]$WorkspaceStagingRoot,
        [Parameter(Mandatory)][string]$CanonicalPath
    )

    $identity = Get-LocalFileIdentity -LiteralPath $StagingPath
    return [pscustomobject]@{
        Sha256            = $identity.Sha256
        Size              = $identity.Size
        LocalDetectedKind = $identity.LocalDetectedKind
        LineEnding        = $identity.LineEnding
        HasBom            = $identity.HasBom
        RemoteKind        = $identity.LocalDetectedKind
        Encoding          = $(if ($identity.LocalDetectedKind -eq 'binary') { 'base64' } else { 'utf8' })
        StagingPath       = $StagingPath
    }
}

function New-PullTestSnapshotFixture {
    # A stable-snapshot-shaped object whose staged bytes are the REMOTE truth.
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][hashtable]$RemoteEntries
    )

    $stagingRoot = Join-Path $WorkspaceRoot ".rundot-sync\temp\remote-snapshot\1"
    New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null

    foreach ($path in @($RemoteEntries.Keys)) {
        $staged = Join-Path $stagingRoot ($path.Replace('/', '\'))
        $source = [string]$RemoteEntries[$path].StagingPath
        $parent = Split-Path -Parent $staged
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        [System.IO.File]::Copy($source, $staged, $true)
        $RemoteEntries[$path].StagingPath = $staged
    }

    return [pscustomobject]@{
        Files                    = $RemoteEntries
        RemoteManifestHashBefore = 'before'
        RemoteManifestHashAfter  = 'after'
        AttemptCount             = 1
        StagingRoot              = $stagingRoot
    }
}

function Get-PullTestBaseEntryForLocal {
    param([Parameter(Mandatory)][string]$LiteralPath)

    $identity = Get-LocalFileIdentity -LiteralPath $LiteralPath
    $entry = [pscustomobject]@{
        sha256 = $identity.Sha256
        size   = $identity.Size
        kind   = $identity.LocalDetectedKind
    }

    if ($identity.LocalDetectedKind -eq 'utf8') {
        $entry | Add-Member -NotePropertyName lineEnding -NotePropertyValue $identity.LineEnding
        $entry | Add-Member -NotePropertyName hasBom -NotePropertyValue $identity.HasBom
    }

    return $entry
}

$pullApplyRoot = Join-Path $env:TEMP ("rundot-pull-apply-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $pullApplyRoot | Out-Null

try {
    # ----------------------------------------------------------------------
    # Clean pull: remote-only change lands byte-for-byte, backed up first
    # ----------------------------------------------------------------------

    $cleanWorkspace = New-PullTestWorkspace -Root $pullApplyRoot
    $cleanLocalBytes = $pullApplyUtf8.GetBytes("local text`n")
    $cleanRemoteBytes = $pullApplyUtf8.GetBytes("remote text`n")
    $cleanPath = Join-Path $cleanWorkspace "src\a.ts"
    Write-PullTestBytes -LiteralPath $cleanPath -Bytes $cleanLocalBytes

    $cleanStagingSource = Join-Path $pullApplyRoot "clean-remote.ts"
    Write-PullTestBytes -LiteralPath $cleanStagingSource -Bytes $cleanRemoteBytes

    $cleanLocal = @{ 'src/a.ts' = (New-PullTestLocalManifestEntry -LiteralPath $cleanPath) }
    $cleanBase = @{ 'src/a.ts' = (Get-PullTestBaseEntryForLocal -LiteralPath $cleanPath) }
    $cleanRemoteMap = @{
        'src/a.ts' = (New-PullTestRemoteIdentityEntry `
            -StagingPath $cleanStagingSource `
            -WorkspaceStagingRoot $cleanWorkspace `
            -CanonicalPath 'src/a.ts')
    }
    $cleanSnapshot = New-PullTestSnapshotFixture -WorkspaceRoot $cleanWorkspace -RemoteEntries $cleanRemoteMap
    $cleanSelection = Get-SyncPullSelection -Base $cleanBase -Local $cleanLocal -Remote $cleanSnapshot.Files

    Assert-Equal 1 @($cleanSelection.Actions).Count "the clean fixture must yield one action"

    $cleanResult = Invoke-RundotSyncPullApply `
        -WorkspaceRoot $cleanWorkspace `
        -Actions $cleanSelection.Actions `
        -Local $cleanLocal `
        -Remote $cleanSnapshot.Files `
        -BackupRoot (Get-RundotSyncBackupRoot -WorkspaceRoot $cleanWorkspace)

    Assert-Equal 1 $cleanResult.Applied "a clean pull must apply its one action"
    Assert-Equal `
        $cleanRemoteBytes `
        (Get-PullTestBytes -LiteralPath $cleanPath) `
        "a clean pull must write the remote bytes exactly"
    Assert-True `
        (Test-Path -LiteralPath $cleanResult.BackupSet.Path -PathType Container) `
        "a clean pull that overwrites must create a backup set"

    $cleanBackedUp = Join-Path $cleanResult.BackupSet.Path "src\a.ts"
    Assert-Equal `
        $cleanLocalBytes `
        (Get-PullTestBytes -LiteralPath $cleanBackedUp) `
        "the overwritten original must be recoverable from the backup set"

    # ----------------------------------------------------------------------
    # Binary and zero-byte payloads are ordinary writes
    # ----------------------------------------------------------------------

    $binaryWorkspace = New-PullTestWorkspace -Root $pullApplyRoot
    $binaryRemoteBytes = [byte[]](0xFF, 0xD8, 0xFF, 0x00, 0x01, 0x02)
    $binaryStagingSource = Join-Path $pullApplyRoot "remote.png"
    Write-PullTestBytes -LiteralPath $binaryStagingSource -Bytes $binaryRemoteBytes

    $zeroLocalPath = Join-Path $binaryWorkspace "empty.ts"
    Write-PullTestBytes -LiteralPath $zeroLocalPath -Bytes ($pullApplyUtf8.GetBytes('x'))
    $zeroStagingSource = Join-Path $pullApplyRoot "remote-empty.ts"
    Write-PullTestBytes -LiteralPath $zeroStagingSource -Bytes ([byte[]]@())

    $binaryLocalMap = @{ 'empty.ts' = (New-PullTestLocalManifestEntry -LiteralPath $zeroLocalPath) }
    # BASE must agree with LOCAL so the zero-byte file is a clean download
    # rather than a conflict. The binary path is a genuine create.
    $binaryBaseMap = @{ 'empty.ts' = (Get-PullTestBaseEntryForLocal -LiteralPath $zeroLocalPath) }
    $binaryRemoteMap = @{
        'public/logo.png' = (New-PullTestRemoteIdentityEntry -StagingPath $binaryStagingSource -WorkspaceStagingRoot $binaryWorkspace -CanonicalPath 'public/logo.png')
        'empty.ts'        = (New-PullTestRemoteIdentityEntry -StagingPath $zeroStagingSource -WorkspaceStagingRoot $binaryWorkspace -CanonicalPath 'empty.ts')
    }
    $binarySnapshot = New-PullTestSnapshotFixture -WorkspaceRoot $binaryWorkspace -RemoteEntries $binaryRemoteMap
    $binarySelection = Get-SyncPullSelection -Base $binaryBaseMap -Local $binaryLocalMap -Remote $binarySnapshot.Files

    $binaryResult = Invoke-RundotSyncPullApply `
        -WorkspaceRoot $binaryWorkspace `
        -Actions $binarySelection.Actions `
        -Local $binaryLocalMap `
        -Remote $binarySnapshot.Files `
        -BackupRoot (Get-RundotSyncBackupRoot -WorkspaceRoot $binaryWorkspace)

    Assert-Equal 2 $binaryResult.Applied "a binary and a zero-byte file must both be applied"
    Assert-Equal 1 $binaryResult.Created "the binary file is a create"
    Assert-Equal 1 $binaryResult.Overwritten "the zero-byte file replaces an existing file"
    Assert-Equal `
        $binaryRemoteBytes `
        (Get-PullTestBytes -LiteralPath (Join-Path $binaryWorkspace "public\logo.png")) `
        "a binary payload must be written byte-for-byte"
    Assert-Equal `
        0 `
        (Get-PullTestBytes -LiteralPath (Join-Path $binaryWorkspace "empty.ts")).Length `
        "a zero-byte remote file must write zero bytes"

    # ----------------------------------------------------------------------
    # A pull with no actions writes nothing and creates no backup set
    # ----------------------------------------------------------------------

    $noopWorkspace = New-PullTestWorkspace -Root $pullApplyRoot
    $noopResult = Invoke-RundotSyncPullApply `
        -WorkspaceRoot $noopWorkspace `
        -Actions @() `
        -Local @{} `
        -Remote @{} `
        -BackupRoot (Get-RundotSyncBackupRoot -WorkspaceRoot $noopWorkspace)

    Assert-Equal 0 $noopResult.Applied "an empty action list must apply nothing"
    Assert-Null $noopResult.BackupSet "an empty action list must not create a backup set"
    Assert-Equal `
        0 `
        @(Get-RundotSyncBackupSets -WorkspaceRoot $noopWorkspace).Count `
        "a no-op pull must not leave a backup set behind"

    # ----------------------------------------------------------------------
    # Backup ordering: the original is preserved before the destination changes
    # ----------------------------------------------------------------------

    $orderWorkspace = New-PullTestWorkspace -Root $pullApplyRoot
    $orderOriginalBytes = $pullApplyUtf8.GetBytes("original`n")
    $orderRemoteBytes = $pullApplyUtf8.GetBytes("pulled`n")
    $orderPath = Join-Path $orderWorkspace "src\a.ts"
    Write-PullTestBytes -LiteralPath $orderPath -Bytes $orderOriginalBytes

    $orderStagingSource = Join-Path $pullApplyRoot "order-remote.ts"
    Write-PullTestBytes -LiteralPath $orderStagingSource -Bytes $orderRemoteBytes

    $orderLocalMap = @{ 'src/a.ts' = (New-PullTestLocalManifestEntry -LiteralPath $orderPath) }
    $orderBaseMap = @{ 'src/a.ts' = (Get-PullTestBaseEntryForLocal -LiteralPath $orderPath) }
    $orderRemoteMap = @{
        'src/a.ts' = (New-PullTestRemoteIdentityEntry -StagingPath $orderStagingSource -WorkspaceStagingRoot $orderWorkspace -CanonicalPath 'src/a.ts')
    }
    $orderSnapshot = New-PullTestSnapshotFixture -WorkspaceRoot $orderWorkspace -RemoteEntries $orderRemoteMap
    $orderSelection = Get-SyncPullSelection -Base $orderBaseMap -Local $orderLocalMap -Remote $orderSnapshot.Files

    # Watch the destination: when the write happens, the backup must already
    # hold the original bytes.
    $script:PullTestBackupObservedBytes = $null
    $realWrite = ${function:Invoke-RundotSyncPullWriteAction}
    function Invoke-RundotSyncPullWriteAction {
        param($Action, $WorkspaceRoot, $LocalFullPath, $RemoteMap)

        foreach ($candidateSet in @(Get-RundotSyncBackupSets -WorkspaceRoot $WorkspaceRoot)) {
            $observedBackup = Join-Path $candidateSet.Path ($Action.Path.Replace('/', '\'))
            if (Test-Path -LiteralPath $observedBackup -PathType Leaf) {
                $script:PullTestBackupObservedBytes = [System.IO.File]::ReadAllBytes($observedBackup)
            }
        }

        & $realWrite `
            -Action $Action `
            -WorkspaceRoot $WorkspaceRoot `
            -LocalFullPath $LocalFullPath `
            -RemoteMap $RemoteMap
    }

    try {
        [void](Invoke-RundotSyncPullApply `
            -WorkspaceRoot $orderWorkspace `
            -Actions $orderSelection.Actions `
            -Local $orderLocalMap `
            -Remote $orderSnapshot.Files `
            -BackupRoot (Get-RundotSyncBackupRoot -WorkspaceRoot $orderWorkspace))
    }
    finally {
        Set-Item -Path function:Invoke-RundotSyncPullWriteAction -Value $realWrite
    }

    Assert-Equal `
        $orderOriginalBytes `
        $script:PullTestBackupObservedBytes `
        "the original must be backed up before the destination is overwritten"
    Assert-Equal `
        $orderRemoteBytes `
        (Get-PullTestBytes -LiteralPath $orderPath) `
        "the write must still land the remote bytes"

    # ----------------------------------------------------------------------
    # Backup failure aborts before any overwrite
    # ----------------------------------------------------------------------

    $backupFailWorkspace = New-PullTestWorkspace -Root $pullApplyRoot
    $backupFailOriginalBytes = $pullApplyUtf8.GetBytes("must survive`n")
    $backupFailPath = Join-Path $backupFailWorkspace "src\a.ts"
    Write-PullTestBytes -LiteralPath $backupFailPath -Bytes $backupFailOriginalBytes

    $backupFailStaging = Join-Path $pullApplyRoot "backup-fail-remote.ts"
    Write-PullTestBytes -LiteralPath $backupFailStaging -Bytes ($pullApplyUtf8.GetBytes("would overwrite`n"))

    $backupFailLocalMap = @{ 'src/a.ts' = (New-PullTestLocalManifestEntry -LiteralPath $backupFailPath) }
    $backupFailBaseMap = @{ 'src/a.ts' = (Get-PullTestBaseEntryForLocal -LiteralPath $backupFailPath) }
    $backupFailRemoteMap = @{
        'src/a.ts' = (New-PullTestRemoteIdentityEntry -StagingPath $backupFailStaging -WorkspaceStagingRoot $backupFailWorkspace -CanonicalPath 'src/a.ts')
    }
    $backupFailSnapshot = New-PullTestSnapshotFixture -WorkspaceRoot $backupFailWorkspace -RemoteEntries $backupFailRemoteMap
    $backupFailSelection = Get-SyncPullSelection -Base $backupFailBaseMap -Local $backupFailLocalMap -Remote $backupFailSnapshot.Files

    $realBackupCopy = ${function:Copy-RundotSyncBackupFile}
    function Copy-RundotSyncBackupFile {
        param($SourcePath, $DestinationPath)
        throw [System.InvalidOperationException]::new("Injected backup failure.")
    }

    $backupFailThrew = $null
    try {
        Invoke-RundotSyncPullApply `
            -WorkspaceRoot $backupFailWorkspace `
            -Actions $backupFailSelection.Actions `
            -Local $backupFailLocalMap `
            -Remote $backupFailSnapshot.Files `
            -BackupRoot (Get-RundotSyncBackupRoot -WorkspaceRoot $backupFailWorkspace) | Out-Null
    }
    catch {
        $backupFailThrew = $_.Exception
    }
    finally {
        Set-Item -Path function:Copy-RundotSyncBackupFile -Value $realBackupCopy
    }

    Assert-True ($null -ne $backupFailThrew) "a backup failure must abort the pull"
    Assert-Equal `
        $backupFailOriginalBytes `
        (Get-PullTestBytes -LiteralPath $backupFailPath) `
        "a backup failure must leave the local file untouched"
    Assert-True `
        ((Get-Command Copy-RundotSyncBackupFile -CommandType Function).Definition -match 'Invoke-RundotSyncVerifiedCopy') `
        "Pull.Tests must restore the real Copy-RundotSyncBackupFile after injecting a failure"

    # ----------------------------------------------------------------------
    # Partial write rolls back: overwritten files restored, created files gone
    # ----------------------------------------------------------------------

    $rollbackWorkspace = New-PullTestWorkspace -Root $pullApplyRoot
    $rollAOriginal = $pullApplyUtf8.GetBytes("keep A`n")
    $rollBOriginal = $pullApplyUtf8.GetBytes("keep B`n")
    $rollAPath = Join-Path $rollbackWorkspace "src\a.ts"
    $rollBPath = Join-Path $rollbackWorkspace "src\b.ts"
    Write-PullTestBytes -LiteralPath $rollAPath -Bytes $rollAOriginal
    Write-PullTestBytes -LiteralPath $rollBPath -Bytes $rollBOriginal

    $rollAStaging = Join-Path $pullApplyRoot "roll-a-remote.ts"
    $rollBStaging = Join-Path $pullApplyRoot "roll-b-remote.ts"
    $rollNewStaging = Join-Path $pullApplyRoot "roll-new-remote.ts"
    Write-PullTestBytes -LiteralPath $rollAStaging -Bytes ($pullApplyUtf8.GetBytes("new A`n"))
    Write-PullTestBytes -LiteralPath $rollBStaging -Bytes ($pullApplyUtf8.GetBytes("new B`n"))
    Write-PullTestBytes -LiteralPath $rollNewStaging -Bytes ($pullApplyUtf8.GetBytes("brand new`n"))

    $rollLocalMap = @{
        'src/a.ts' = (New-PullTestLocalManifestEntry -LiteralPath $rollAPath)
        'src/b.ts' = (New-PullTestLocalManifestEntry -LiteralPath $rollBPath)
    }
    # BASE agrees with LOCAL for the two existing files so they are clean
    # downloads (overwrites). src/new/c.ts has no local file, so it is a create.
    $rollBaseMap = @{
        'src/a.ts' = (Get-PullTestBaseEntryForLocal -LiteralPath $rollAPath)
        'src/b.ts' = (Get-PullTestBaseEntryForLocal -LiteralPath $rollBPath)
    }
    $rollRemoteMap = @{
        'src/a.ts'     = (New-PullTestRemoteIdentityEntry -StagingPath $rollAStaging -WorkspaceStagingRoot $rollbackWorkspace -CanonicalPath 'src/a.ts')
        'src/b.ts'     = (New-PullTestRemoteIdentityEntry -StagingPath $rollBStaging -WorkspaceStagingRoot $rollbackWorkspace -CanonicalPath 'src/b.ts')
        'src/new/c.ts' = (New-PullTestRemoteIdentityEntry -StagingPath $rollNewStaging -WorkspaceStagingRoot $rollbackWorkspace -CanonicalPath 'src/new/c.ts')
    }
    $rollSnapshot = New-PullTestSnapshotFixture -WorkspaceRoot $rollbackWorkspace -RemoteEntries $rollRemoteMap
    $rollSelection = Get-SyncPullSelection -Base $rollBaseMap -Local $rollLocalMap -Remote $rollSnapshot.Files
    Assert-Equal 3 @($rollSelection.Actions).Count "the rollback fixture must yield three actions"

    # Fail the second write, so one overwrite has already happened.
    $script:PullTestWriteCalls = 0
    $realWriteForRollback = ${function:Invoke-RundotSyncPullWriteAction}
    function Invoke-RundotSyncPullWriteAction {
        param($Action, $WorkspaceRoot, $LocalFullPath, $RemoteMap)

        $script:PullTestWriteCalls++
        if ($script:PullTestWriteCalls -eq 2) {
            throw [System.InvalidOperationException]::new("Injected write failure.")
        }

        & $realWriteForRollback `
            -Action $Action `
            -WorkspaceRoot $WorkspaceRoot `
            -LocalFullPath $LocalFullPath `
            -RemoteMap $RemoteMap
    }

    $rollThrew = $null
    try {
        Invoke-RundotSyncPullApply `
            -WorkspaceRoot $rollbackWorkspace `
            -Actions $rollSelection.Actions `
            -Local $rollLocalMap `
            -Remote $rollSnapshot.Files `
            -BackupRoot (Get-RundotSyncBackupRoot -WorkspaceRoot $rollbackWorkspace) | Out-Null
    }
    catch {
        $rollThrew = $_.Exception
    }
    finally {
        Set-Item -Path function:Invoke-RundotSyncPullWriteAction -Value $realWriteForRollback
    }

    Assert-True ($null -ne $rollThrew) "a write failure must abort the pull"
    Assert-Equal `
        $rollAOriginal `
        (Get-PullTestBytes -LiteralPath $rollAPath) `
        "a partial write must restore the overwritten file A"
    Assert-Equal `
        $rollBOriginal `
        (Get-PullTestBytes -LiteralPath $rollBPath) `
        "a partial write must leave the not-yet-written file B untouched"
    Assert-True `
        (-not (Test-Path -LiteralPath (Join-Path $rollbackWorkspace "src\new\c.ts"))) `
        "a partial write must not leave a half-created file"
    Assert-True `
        (-not (Test-Path -LiteralPath (Join-Path $rollbackWorkspace "src\new"))) `
        "a partial write must prune a directory it created"
    Assert-True `
        (Test-Path -LiteralPath (Join-Path $rollbackWorkspace "src") -PathType Container) `
        "rollback must not delete a pre-existing directory"
    Assert-Equal `
        ($pullApplyUtf8.GetBytes("new A`n")) `
        (Get-PullTestBytes -LiteralPath $rollAStaging) `
        "rollback must not consume or alter the staged remote source"
    Assert-Equal `
        $rollBOriginal `
        (Get-PullTestBytes -LiteralPath $rollBPath) `
        "rollback verification: file B must still hold its original bytes"

    $rollBackupSets = @(Get-RundotSyncBackupSets -WorkspaceRoot $rollbackWorkspace)
    Assert-Equal 1 $rollBackupSets.Count "a rolled-back pull still keeps the backup set it made"
    Assert-Equal `
        $rollAOriginal `
        (Get-PullTestBytes -LiteralPath (Join-Path $rollBackupSets[0].Path "src\a.ts")) `
        "the backup set must still hold the overwritten original after a rollback"

    # ----------------------------------------------------------------------
    # Verify failure: wrong bytes for the action must abort and roll back
    # ----------------------------------------------------------------------

    $verifyWorkspace = New-PullTestWorkspace -Root $pullApplyRoot
    $verifyOriginal = $pullApplyUtf8.GetBytes("verify original`n")
    $verifyPath = Join-Path $verifyWorkspace "src\a.ts"
    Write-PullTestBytes -LiteralPath $verifyPath -Bytes $verifyOriginal

    $verifyStaging = Join-Path $pullApplyRoot "verify-remote.ts"
    Write-PullTestBytes -LiteralPath $verifyStaging -Bytes ($pullApplyUtf8.GetBytes("verify remote`n"))

    $verifyLocalMap = @{ 'src/a.ts' = (New-PullTestLocalManifestEntry -LiteralPath $verifyPath) }
    $verifyBaseMap = @{ 'src/a.ts' = (Get-PullTestBaseEntryForLocal -LiteralPath $verifyPath) }
    $verifyRemoteMap = @{
        'src/a.ts' = (New-PullTestRemoteIdentityEntry -StagingPath $verifyStaging -WorkspaceStagingRoot $verifyWorkspace -CanonicalPath 'src/a.ts')
    }
    $verifySnapshot = New-PullTestSnapshotFixture -WorkspaceRoot $verifyWorkspace -RemoteEntries $verifyRemoteMap
    $verifySelection = Get-SyncPullSelection -Base $verifyBaseMap -Local $verifyLocalMap -Remote $verifySnapshot.Files

    # Corrupt the action's expected hash so the post-write verification fails.
    $verifyTampered = @(
        [pscustomobject]@{
            Path              = [string]$verifySelection.Actions[0].Path
            Status            = [string]$verifySelection.Actions[0].Status
            Kind              = [string]$verifySelection.Actions[0].Kind
            LocalSha256       = $verifySelection.Actions[0].LocalSha256
            RemoteSha256      = $pullTestShaC
            RemoteStagingPath = [string]$verifySelection.Actions[0].RemoteStagingPath
            IsOverwrite       = [bool]$verifySelection.Actions[0].IsOverwrite
        }
    )

    $verifyThrew = $null
    try {
        Invoke-RundotSyncPullApply `
            -WorkspaceRoot $verifyWorkspace `
            -Actions $verifyTampered `
            -Local $verifyLocalMap `
            -Remote $verifySnapshot.Files `
            -BackupRoot (Get-RundotSyncBackupRoot -WorkspaceRoot $verifyWorkspace) | Out-Null
    }
    catch {
        $verifyThrew = $_.Exception
    }

    Assert-True ($null -ne $verifyThrew) "a verification mismatch must abort the pull"
    Assert-Equal `
        $verifyOriginal `
        (Get-PullTestBytes -LiteralPath $verifyPath) `
        "a verification failure must restore the original bytes"

    # ----------------------------------------------------------------------
    # Concurrent edit: a file changed after the manifest was captured aborts
    # ----------------------------------------------------------------------

    $raceWorkspace = New-PullTestWorkspace -Root $pullApplyRoot
    $raceOriginal = $pullApplyUtf8.GetBytes("race original`n")
    $racePath = Join-Path $raceWorkspace "src\a.ts"
    Write-PullTestBytes -LiteralPath $racePath -Bytes $raceOriginal

    $raceStaging = Join-Path $pullApplyRoot "race-remote.ts"
    Write-PullTestBytes -LiteralPath $raceStaging -Bytes ($pullApplyUtf8.GetBytes("race remote`n"))

    $raceLocalMap = @{ 'src/a.ts' = (New-PullTestLocalManifestEntry -LiteralPath $racePath) }
    $raceBaseMap = @{ 'src/a.ts' = (Get-PullTestBaseEntryForLocal -LiteralPath $racePath) }
    $raceRemoteMap = @{
        'src/a.ts' = (New-PullTestRemoteIdentityEntry -StagingPath $raceStaging -WorkspaceStagingRoot $raceWorkspace -CanonicalPath 'src/a.ts')
    }
    $raceSnapshot = New-PullTestSnapshotFixture -WorkspaceRoot $raceWorkspace -RemoteEntries $raceRemoteMap
    $raceSelection = Get-SyncPullSelection -Base $raceBaseMap -Local $raceLocalMap -Remote $raceSnapshot.Files

    # The user edits the file between the manifest capture and the pull.
    $raceEditedBytes = $pullApplyUtf8.GetBytes("edited after scan`n")
    Write-PullTestBytes -LiteralPath $racePath -Bytes $raceEditedBytes

    $raceThrew = $null
    try {
        Invoke-RundotSyncPullApply `
            -WorkspaceRoot $raceWorkspace `
            -Actions $raceSelection.Actions `
            -Local $raceLocalMap `
            -Remote $raceSnapshot.Files `
            -BackupRoot (Get-RundotSyncBackupRoot -WorkspaceRoot $raceWorkspace) | Out-Null
    }
    catch {
        $raceThrew = $_.Exception
    }

    Assert-True ($null -ne $raceThrew) "a concurrent local edit must abort the pull"
    if ($null -ne $raceThrew) {
        Assert-True `
            (([string]$raceThrew.Message) -match '(?i)changed since') `
            "the concurrent-edit refusal should say the local file changed since it was scanned"
    }
    Assert-Equal `
        $raceEditedBytes `
        (Get-PullTestBytes -LiteralPath $racePath) `
        "a concurrent edit must never be overwritten by a pull"

    # Force never disables the concurrent-edit guard.
    $raceForcedThrew = $null
    try {
        Invoke-RundotSyncPullApply `
            -WorkspaceRoot $raceWorkspace `
            -Actions $raceSelection.Actions `
            -Local $raceLocalMap `
            -Remote $raceSnapshot.Files `
            -BackupRoot (Get-RundotSyncBackupRoot -WorkspaceRoot $raceWorkspace) | Out-Null
    }
    catch {
        $raceForcedThrew = $_.Exception
    }
    Assert-True ($null -ne $raceForcedThrew) "the concurrent-edit guard must not be skippable by force"
    Assert-Equal `
        $raceEditedBytes `
        (Get-PullTestBytes -LiteralPath $racePath) `
        "force must not overwrite a concurrently edited file"

    # ----------------------------------------------------------------------
    # Writes are atomic and never leave a destination tmp
    # ----------------------------------------------------------------------

    $atomicWorkspace = New-PullTestWorkspace -Root $pullApplyRoot
    $atomicStaging = Join-Path $pullApplyRoot "atomic-remote.ts"
    Write-PullTestBytes -LiteralPath $atomicStaging -Bytes ($pullApplyUtf8.GetBytes("atomic`n"))
    $atomicRemoteMap = @{
        'src/a.ts' = (New-PullTestRemoteIdentityEntry -StagingPath $atomicStaging -WorkspaceStagingRoot $atomicWorkspace -CanonicalPath 'src/a.ts')
    }
    $atomicSnapshot = New-PullTestSnapshotFixture -WorkspaceRoot $atomicWorkspace -RemoteEntries $atomicRemoteMap
    $atomicSelection = Get-SyncPullSelection -Base @{} -Local @{} -Remote $atomicSnapshot.Files

    [void](Invoke-RundotSyncPullApply `
        -WorkspaceRoot $atomicWorkspace `
        -Actions $atomicSelection.Actions `
        -Local @{} `
        -Remote $atomicSnapshot.Files `
        -BackupRoot (Get-RundotSyncBackupRoot -WorkspaceRoot $atomicWorkspace))

    $atomicPath = Join-Path $atomicWorkspace "src\a.ts"
    Assert-True (Test-Path -LiteralPath $atomicPath -PathType Leaf) "an atomic write must land the destination"
    Assert-True `
        (-not (Test-Path -LiteralPath ($atomicPath + '.tmp'))) `
        "an atomic write must leave no destination temp file"

    # A pull that cannot represent a path aborts before writing anything.
    $representWorkspace = New-PullTestWorkspace -Root $pullApplyRoot
    $representStaging = Join-Path $pullApplyRoot "represent-remote.ts"
    Write-PullTestBytes -LiteralPath $representStaging -Bytes ($pullApplyUtf8.GetBytes("x`n"))
    $representActions = @(
        [pscustomobject]@{
            Path              = 'a<b>.ts'
            Status            = 'download'
            Kind              = 'utf8'
            LocalSha256       = $null
            RemoteSha256      = (Get-FileSha256Hex -LiteralPath $representStaging)
            RemoteStagingPath = $representStaging
            IsOverwrite       = $false
        }
    )

    $representThrew = $null
    try {
        Invoke-RundotSyncPullApply `
            -WorkspaceRoot $representWorkspace `
            -Actions $representActions `
            -Local @{} `
            -Remote @{} `
            -BackupRoot (Get-RundotSyncBackupRoot -WorkspaceRoot $representWorkspace) | Out-Null
    }
    catch {
        $representThrew = $_.Exception
    }
    Assert-True ($null -ne $representThrew) "an unrepresentable path must abort before any write"
}
finally {
    if (Test-Path -LiteralPath $pullApplyRoot) {
        Remove-Item -LiteralPath $pullApplyRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
