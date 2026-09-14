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
