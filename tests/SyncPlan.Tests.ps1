# Plan / Status dry-run engine contracts: the last-plan.json artifact, the
# operation rows, the human report, and BOM/newline text diagnostics.
#
# Do not require Pester.
#
# SCOPE NOTE: tests/Run-Tests.ps1 dot-sources every *.Tests.ps1 into one
# scope, in filename order. This file sorts after SyncEngine.Tests.ps1 and
# before Workspace.Tests.ps1. Helpers here are prefixed New-SyncPlanTest* /
# Get-SyncPlanTest* / Assert-SyncPlanTest* so they never shadow another test
# file. This file performs no network access and stubs no remote helper, so it
# never leaks a replacement into a later file.

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "lib\Paths.ps1")
. (Join-Path $repoRoot "lib\Ignore.ps1")
. (Join-Path $repoRoot "lib\Hashing.ps1")
. (Join-Path $repoRoot "lib\Workspace.ps1")
. (Join-Path $repoRoot "lib\Manifest.ps1")
. (Join-Path $repoRoot "lib\Snapshot.ps1")
. (Join-Path $repoRoot "lib\Classifier.ps1")
. (Join-Path $repoRoot "lib\Plan.ps1")
. (Join-Path $repoRoot "lib\RemoteDelete.ps1")

$syncPlanTestShaA = 'a' * 64
$syncPlanTestShaB = 'b' * 64
$syncPlanTestShaC = 'c' * 64


# --------------------------------------------------------------------------
# Fixtures in the real on-disk shapes the classifier reads
# --------------------------------------------------------------------------

function New-SyncPlanTestBaseEntry {
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

function New-SyncPlanTestLocalEntry {
    param(
        [string]$Sha256,
        [int64]$Size = 0,
        [string]$Kind = 'utf8',
        $LineEnding = 'lf',
        $HasBom = $false
    )

    return [pscustomobject]@{
        Sha256            = $Sha256
        Size              = $Size
        LocalDetectedKind = $Kind
        LineEnding        = $LineEnding
        HasBom            = $HasBom
    }
}

function New-SyncPlanTestRemoteEntry {
    param(
        [string]$Sha256,
        [int64]$Size = 0,
        [string]$Kind = 'utf8',
        [string]$Encoding = 'utf8',
        [string]$StagingPath = $null
    )

    return [pscustomobject]@{
        Sha256            = $Sha256
        Size              = $Size
        LocalDetectedKind = $Kind
        RemoteKind        = $Kind
        Encoding          = $Encoding
        StagingPath       = $StagingPath
    }
}

function New-SyncPlanTestLocalEntryFromFile {
    param([string]$LiteralPath)

    $identity = Get-LocalFileIdentity -LiteralPath $LiteralPath
    return [pscustomobject]@{
        Sha256            = $identity.Sha256
        Size              = $identity.Size
        LocalDetectedKind = $identity.LocalDetectedKind
        LineEnding        = $identity.LineEnding
        HasBom            = $identity.HasBom
    }
}

function New-SyncPlanTestResolution {
    param(
        $Base = $null,
        [bool]$BasePresent = $false,
        [bool]$Untrusted = $false
    )

    return [pscustomobject]@{
        Base        = $Base
        BasePresent = $BasePresent
        Untrusted   = $Untrusted
    }
}

function New-SyncPlanTestSnapshot {
    param([string]$HashBefore, [string]$HashAfter)

    return [pscustomobject]@{
        RemoteManifestHashBefore = $HashBefore
        RemoteManifestHashAfter  = $HashAfter
    }
}

function Get-SyncPlanTestRowForPath {
    param(
        [object[]]$Rows,
        [string]$Path
    )

    foreach ($row in @($Rows)) {
        if ([string]::Equals([string]$row.path, $Path, [System.StringComparison]::Ordinal)) {
            return $row
        }
    }

    return $null
}

function Write-SyncPlanTestBytes {
    param(
        [string]$LiteralPath,
        [byte[]]$Bytes
    )

    $parent = Split-Path -Parent $LiteralPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    [System.IO.File]::WriteAllBytes($LiteralPath, $Bytes)
}

function New-SyncPlanTestWorkspace {
    param([string]$Root)

    $workspace = Join-Path $Root ("ws-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $workspace | Out-Null
    return $workspace
}

function Assert-SyncPlanTestIsGuid {
    param([string]$Value)

    $parsed = [Guid]::Empty
    $ok = [Guid]::TryParse([string]$Value, [ref]$parsed)
    Assert-True $ok "planId must be a parseable GUID, got '$Value'"
}

function Get-SyncPlanTestReportLines {
    param([string]$Report)

    return @($Report -split "`n")
}

function Get-SyncPlanTestNonEmptyLines {
    param([string]$Report)

    return @(
        Get-SyncPlanTestReportLines -Report $Report |
            Where-Object { $_.Trim().Length -gt 0 }
    )
}


# --------------------------------------------------------------------------
# Remote-mutating status vocabulary
#
# The milestone has no remote mutation, so these statuses must always be
# blocked in the artifact regardless of what the classifier says about them.
# --------------------------------------------------------------------------

Assert-True (Test-SyncRemoteMutatingStatus -Status $SyncStatusUpload) "upload is remote-mutating"
Assert-True `
    (Test-SyncRemoteMutatingStatus -Status $SyncStatusDeleteRemoteCandidate) `
    "deleteRemoteCandidate is remote-mutating"
Assert-True (Test-SyncRemoteMutatingStatus -Status 'DELETE') "the literal DELETE is remote-mutating"

foreach ($nonMutating in @(
    $SyncStatusDownload,
    $SyncStatusConflict,
    $SyncStatusUnchanged,
    $SyncStatusIgnored,
    $SyncStatusDeleteLocalCandidate,
    $SyncStatusSynchronizedChange,
    $SyncStatusSynchronizedAddition,
    $SyncStatusSettledAbsent
)) {
    Assert-True `
        (-not (Test-SyncRemoteMutatingStatus -Status $nonMutating)) `
        "status '$nonMutating' must not be remote-mutating"
}


# --------------------------------------------------------------------------
# Artifact path and local manifest fingerprint
# --------------------------------------------------------------------------

$syncPlanTestRoot = Join-Path $env:TEMP ("rundot-plan-tests-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $syncPlanTestRoot | Out-Null

try {
    $artifactWorkspace = New-SyncPlanTestWorkspace -Root $syncPlanTestRoot

    $artifactPath = Get-PlanArtifactPath -WorkspaceRoot $artifactWorkspace
    Assert-Equal `
        'last-plan.json' `
        ([System.IO.Path]::GetFileName($artifactPath)) `
        "the plan artifact must be named last-plan.json"
    Assert-True `
        ($artifactPath -match [regex]::Escape('.rundot-sync')) `
        "the plan artifact must live under .rundot-sync"
    Assert-True `
        (-not (Test-Path -LiteralPath $artifactPath)) `
        "the artifact path must not exist before Plan runs"

    $fingerprintLocalA = @{
        'src/a.ts' = (New-SyncPlanTestLocalEntry -Sha256 $syncPlanTestShaA -Size 3)
    }
    $fingerprintLocalB = @{
        'src/a.ts' = (New-SyncPlanTestLocalEntry -Sha256 $syncPlanTestShaB -Size 3)
    }
    $localManifestHashA = Get-SyncLocalManifestFingerprint -Local $fingerprintLocalA
    Assert-True `
        ($localManifestHashA -match '^[0-9a-f]{64}$') `
        "the local manifest fingerprint must be 64 lowercase hex"
    Assert-Equal `
        $localManifestHashA `
        (Get-SyncLocalManifestFingerprint -Local $fingerprintLocalA) `
        "the local manifest fingerprint must be stable for the same map"
    Assert-True `
        ($localManifestHashA -ne (Get-SyncLocalManifestFingerprint -Local $fingerprintLocalB)) `
        "a different local content hash must change the manifest fingerprint"
    Assert-True `
        ((Get-SyncLocalManifestFingerprint -Local @{}) -match '^[0-9a-f]{64}$') `
        "an empty local manifest must still fingerprint"


    # --------------------------------------------------------------------------
    # Artifact shape, identifiers, and expiry
    # --------------------------------------------------------------------------

    $baseA = New-SyncPlanTestBaseEntry -Sha256 $syncPlanTestShaA
    $localA = New-SyncPlanTestLocalEntry -Sha256 $syncPlanTestShaA
    $remoteA = New-SyncPlanTestRemoteEntry -Sha256 $syncPlanTestShaA

    $resolution = New-SyncPlanTestResolution `
        -Base ([pscustomobject]@{ capturedAt = '2026-09-14T12:00:00.0000000Z' }) `
        -BasePresent $true `
        -Untrusted $false

    $baseMap = @{ 'src/a.ts' = $baseA }
    $localMap = @{ 'src/a.ts' = $localA }
    $remoteMap = @{ 'src/a.ts' = $remoteA }
    $snapshot = New-SyncPlanTestSnapshot -HashBefore $syncPlanTestShaB -HashAfter $syncPlanTestShaB

    $artifact = New-RundotSyncPlanArtifact `
        -WorkspaceRoot $artifactWorkspace `
        -ProjectId 'proj-test-1' `
        -Resolution $resolution `
        -Local $localMap `
        -Remote $remoteMap `
        -Snapshot $snapshot

    Assert-Equal 1 $artifact.schemaVersion "the artifact schemaVersion must be 1"
    Assert-Equal '0.2.0' $artifact.toolVersion "the artifact toolVersion must be the milestone"
    Assert-SyncPlanTestIsGuid -Value $artifact.planId
    Assert-Equal 'proj-test-1' $artifact.projectId "the artifact must record projectId"
    Assert-Equal `
        (Get-LocalRootFingerprint -WorkspaceRoot $artifactWorkspace) `
        $artifact.localRootFingerprint `
        "the artifact must record the workspace root fingerprint"
    Assert-Equal $true $artifact.basePresent "a verified BASE must be recorded as present"
    Assert-Equal $false $artifact.untrusted "a verified plan must not be marked untrusted"
    Assert-Equal `
        '2026-09-14T12:00:00.0000000Z' `
        $artifact.baseCapturedAt `
        "the artifact must carry BASE capturedAt"
    Assert-Equal `
        $syncPlanTestShaB `
        $artifact.remoteManifestHashBefore `
        "the artifact must carry the remote hash before"
    Assert-Equal `
        $syncPlanTestShaB `
        $artifact.remoteManifestHashAfter `
        "the artifact must carry the remote hash after"

    $createdAt = [System.DateTime]::Parse($artifact.createdAt)
    $expiresAt = [System.DateTime]::Parse($artifact.expiresAt)
    Assert-Equal `
        20 `
        ([math]::Round(($expiresAt - $createdAt).TotalMinutes, 3)) `
        "the default plan TTL must be 20 minutes"
    Assert-True ($expiresAt -gt $createdAt) "expiresAt must be after createdAt"

    $shortTtl = New-RundotSyncPlanArtifact `
        -WorkspaceRoot $artifactWorkspace `
        -ProjectId 'proj-test-1' `
        -Resolution $resolution `
        -Local $localMap `
        -Remote $remoteMap `
        -Snapshot $snapshot `
        -TtlMinutes 5
    Assert-Equal `
        5 `
        ([math]::Round(
            ([System.DateTime]::Parse($shortTtl.expiresAt) - [System.DateTime]::Parse($shortTtl.createdAt)).TotalMinutes,
            3)) `
        "an explicit TTL must control expiresAt"

    $twoArtifacts = @(
        (New-RundotSyncPlanArtifact -WorkspaceRoot $artifactWorkspace -ProjectId 'p' -Resolution $resolution -Local $localMap -Remote $remoteMap -Snapshot $snapshot),
        (New-RundotSyncPlanArtifact -WorkspaceRoot $artifactWorkspace -ProjectId 'p' -Resolution $resolution -Local $localMap -Remote $remoteMap -Snapshot $snapshot)
    )
    Assert-True `
        ($twoArtifacts[0].planId -ne $twoArtifacts[1].planId) `
        "each plan must get a fresh planId"

    Assert-PlanArtifactShape -Artifact $artifact
    Assert-Throws {
        Assert-PlanArtifactShape -Artifact ([pscustomobject]@{ planId = 'not-a-guid' })
    } "a malformed artifact must not pass the shape check"


    # --------------------------------------------------------------------------
    # Operation rows: one per union path, sorted, with future-Apply evidence
    # --------------------------------------------------------------------------

    $unionBase = @{ 'src/a.ts' = $baseA }
    $unionLocal = @{
        'src/a.ts' = $localA
        'src/b.ts' = (New-SyncPlanTestLocalEntry -Sha256 $syncPlanTestShaB)
    }
    $unionRemote = @{
        'src/a.ts' = $remoteA
        'src/c.ts' = (New-SyncPlanTestRemoteEntry -Sha256 $syncPlanTestShaC)
    }

    # BASE enters the engine only through the resolver result, so a case that
    # needs a tracked BASE builds a resolution whose manifest carries it.
    $unionResolution = New-SyncPlanTestResolution `
        -Base ([pscustomobject]@{
            capturedAt = '2026-09-14T12:00:00.0000000Z'
            files      = $unionBase
        }) `
        -BasePresent $true `
        -Untrusted $false

    $unionArtifact = New-RundotSyncPlanArtifact `
        -WorkspaceRoot $artifactWorkspace `
        -ProjectId 'proj-test-1' `
        -Resolution $unionResolution `
        -Local $unionLocal `
        -Remote $unionRemote `
        -Snapshot $snapshot

    $unionOps = @($unionArtifact.operations)
    Assert-Equal 3 $unionOps.Count "every union path must get exactly one operation row"
    Assert-Equal `
        @('src/a.ts', 'src/b.ts', 'src/c.ts') `
        @($unionOps | ForEach-Object { [string]$_.path }) `
        "operation rows must be ordinal-sorted by canonical path"

    $opA = Get-SyncPlanTestRowForPath -Rows $unionOps -Path 'src/a.ts'
    Assert-Equal $syncPlanTestShaA $opA.baseSha256 "an operation row must carry the BASE hash"
    Assert-Equal $syncPlanTestShaA $opA.localSha256 "an operation row must carry the LOCAL hash"
    Assert-Equal $syncPlanTestShaA $opA.remoteSha256 "an operation row must carry the REMOTE hash"
    Assert-Equal `
        $opA.remoteSha256 `
        $opA.expectedRemoteHash `
        "expectedRemoteHash must be the remote hash a future Apply re-verifies"

    $opB = Get-SyncPlanTestRowForPath -Rows $unionOps -Path 'src/b.ts'
    Assert-Null $opB.baseSha256 "a BASE-absent row must not invent a BASE hash"
    Assert-Null $opB.remoteSha256 "a REMOTE-absent row must not invent a REMOTE hash"
    Assert-Null $opB.expectedRemoteHash "a REMOTE-absent row has no expectedRemoteHash"


    # --------------------------------------------------------------------------
    # Publish policy: utf8 text overwrite and text create may be applicable
    # --------------------------------------------------------------------------

    $guardBase = @{
        'src/text.ts'     = (New-SyncPlanTestBaseEntry -Sha256 $syncPlanTestShaA)
        'public/x.png'    = (New-SyncPlanTestBaseEntry -Sha256 $syncPlanTestShaA -Kind 'binary')
        'src/dl.ts'       = (New-SyncPlanTestBaseEntry -Sha256 $syncPlanTestShaA)
        'src/gone.ts'     = (New-SyncPlanTestBaseEntry -Sha256 $syncPlanTestShaA)
        'src/localdel.ts' = (New-SyncPlanTestBaseEntry -Sha256 $syncPlanTestShaA)
    }
    $guardLocal = @{
        'src/text.ts'     = (New-SyncPlanTestLocalEntry -Sha256 $syncPlanTestShaB)
        'src/new.ts'      = (New-SyncPlanTestLocalEntry -Sha256 $syncPlanTestShaC)
        'public/x.png'    = (New-SyncPlanTestLocalEntry -Sha256 $syncPlanTestShaB -Kind 'binary')
        'src/dl.ts'       = (New-SyncPlanTestLocalEntry -Sha256 $syncPlanTestShaA)
        'src/localdel.ts' = (New-SyncPlanTestLocalEntry -Sha256 $syncPlanTestShaA)
    }
    $guardRemote = @{
        'src/text.ts'   = (New-SyncPlanTestRemoteEntry -Sha256 $syncPlanTestShaA)
        'public/x.png'  = (New-SyncPlanTestRemoteEntry -Sha256 $syncPlanTestShaA -Kind 'binary' -Encoding 'base64')
        'src/dl.ts'     = (New-SyncPlanTestRemoteEntry -Sha256 $syncPlanTestShaB)
        'src/gone.ts'   = (New-SyncPlanTestRemoteEntry -Sha256 $syncPlanTestShaA)
    }

    $guardResolution = New-SyncPlanTestResolution `
        -Base ([pscustomobject]@{
            capturedAt = '2026-09-14T12:00:00.0000000Z'
            files      = $guardBase
        }) `
        -BasePresent $true `
        -Untrusted $false

    $guardArtifact = New-RundotSyncPlanArtifact `
        -WorkspaceRoot $artifactWorkspace `
        -ProjectId 'proj-test-1' `
        -Resolution $guardResolution `
        -Local $guardLocal `
        -Remote $guardRemote `
        -Snapshot $snapshot

    $guardOps = @($guardArtifact.operations)

    # A second fixture for the two delete refusals the route rules own:
    # a reserved root and a directory-shaped path. Both stay delete candidates
    # at the classifier layer and both must be refused by the publish policy.
    $reservedBase = @{
        '.rundot/config' = (New-SyncPlanTestBaseEntry -Sha256 $syncPlanTestShaA)
        'src/dir'        = (New-SyncPlanTestBaseEntry -Sha256 $syncPlanTestShaA)
    }
    $reservedLocal = @{}
    $reservedRemote = @{
        '.rundot/config' = (New-SyncPlanTestRemoteEntry -Sha256 $syncPlanTestShaA)
        'src/dir'        = (New-SyncPlanTestRemoteEntry -Sha256 $syncPlanTestShaA)
        'src/dir/a.ts'   = (New-SyncPlanTestRemoteEntry -Sha256 $syncPlanTestShaB)
    }

    $reservedArtifact = New-RundotSyncPlanArtifact `
        -WorkspaceRoot $artifactWorkspace `
        -ProjectId 'proj-test-1' `
        -Resolution (New-SyncPlanTestResolution `
            -Base ([pscustomobject]@{
                capturedAt = '2026-09-14T12:00:00.0000000Z'
                files      = $reservedBase
            }) `
            -BasePresent $true `
            -Untrusted $false) `
        -Local $reservedLocal `
        -Remote $reservedRemote `
        -Snapshot $snapshot

    $reservedOps = @($reservedArtifact.operations)

    $textUpload = Get-SyncPlanTestRowForPath -Rows $guardOps -Path 'src/text.ts'
    Assert-Equal 'upload' $textUpload.status "the text upload row must keep its upload status"
    Assert-Equal $true $textUpload.remoteMutating "a text upload is remote-mutating"
    Assert-Equal $true $textUpload.applicable "a text overwrite must be applicable for Push"
    Assert-Null $textUpload.reason "a publishable text overwrite must not carry a block reason"

    $textCreate = Get-SyncPlanTestRowForPath -Rows $guardOps -Path 'src/new.ts'
    Assert-Equal 'upload' $textCreate.status "a new local text file must still display as upload"
    Assert-Equal $true $textCreate.applicable "a clean utf8 text create must be applicable"
    Assert-Null $textCreate.reason "a publishable text create must not carry a block reason"

    $blockedCreateLocal = @{
        '.rundot/blocked.txt' = (New-SyncPlanTestLocalEntry -Sha256 $syncPlanTestShaC)
    }
    $blockedCreateArtifact = New-RundotSyncPlanArtifact `
        -WorkspaceRoot $artifactWorkspace `
        -ProjectId 'proj-test-1' `
        -Resolution $guardResolution `
        -Local $blockedCreateLocal `
        -Remote @{} `
        -Snapshot $snapshot
    $blockedCreateRow = Get-SyncPlanTestRowForPath `
        -Rows @($blockedCreateArtifact.operations) `
        -Path '.rundot/blocked.txt'
    Assert-Equal $false $blockedCreateRow.applicable "a reserved-path text create must not be applicable"
    Assert-True `
        ([string]$blockedCreateRow.reason -match 'Reserved path') `
        "a reserved-path text create must explain the refusal"

    $binaryUpload = Get-SyncPlanTestRowForPath -Rows $guardOps -Path 'public/x.png'
    Assert-Equal 'upload' $binaryUpload.status "a binary upload must still display as upload"
    Assert-Equal $false $binaryUpload.applicable "a binary upload must not be applicable"
    Assert-Equal `
        'Binary placement needs upload-then-move: the upload flow ignores the requested path and a repeated name creates a sibling instead of replacing, and a replacement is delete-then-place rather than an in-place overwrite.' `
        ([string]$binaryUpload.reason) `
        "a binary upload must keep the fixed replacement-impossible reason"

    $download = Get-SyncPlanTestRowForPath -Rows $guardOps -Path 'src/dl.ts'
    Assert-Equal 'download' $download.status "a remote-only change keeps the download status"
    Assert-Equal $false $download.remoteMutating "a download is not remote-mutating"
    Assert-Equal $true $download.applicable "a download stays applicable"

    $remoteDelete = Get-SyncPlanTestRowForPath -Rows $guardOps -Path 'src/gone.ts'
    Assert-Equal 'deleteRemoteCandidate' $remoteDelete.status "a remote deletion keeps its status"
    Assert-Equal $true $remoteDelete.remoteMutating "a remote delete candidate is remote-mutating"
    Assert-Equal $true $remoteDelete.applicable "a route-allowed remote delete must be applicable for Push"
    Assert-Null $remoteDelete.reason "an applicable remote delete must not carry a block reason"

    # A reserved path and a directory-shaped path are both refused by the
    # route rules even though the classifier still calls them delete
    # candidates. The reason names why, and neither is applicable.
    $reservedDelete = Get-SyncPlanTestRowForPath -Rows $reservedOps -Path '.rundot/config'
    Assert-Equal 'deleteRemoteCandidate' $reservedDelete.status "a reserved path is still a delete candidate"
    Assert-Equal $false $reservedDelete.applicable "a reserved path must never be applicable for delete"
    Assert-True `
        (-not [string]::IsNullOrEmpty([string]$reservedDelete.reason)) `
        "a refused reserved delete must carry a reason"

    $directoryDelete = Get-SyncPlanTestRowForPath -Rows $reservedOps -Path 'src/dir'
    Assert-Equal 'deleteRemoteCandidate' $directoryDelete.status "a directory-shaped path is still a delete candidate"
    Assert-Equal $false $directoryDelete.applicable "a directory-shaped path must never be applicable for delete"
    Assert-True `
        (-not [string]::IsNullOrEmpty([string]$directoryDelete.reason)) `
        "a refused directory-shaped delete must carry a reason"

    $localDelete = Get-SyncPlanTestRowForPath -Rows $guardOps -Path 'src/localdel.ts'
    Assert-Equal 'deleteLocalCandidate' $localDelete.status "a local deletion keeps its status"
    Assert-Equal $false $localDelete.remoteMutating "a local delete candidate is not remote-mutating"
    Assert-Equal $false $localDelete.applicable "a local delete candidate must not be applicable"

    foreach ($op in $guardOps) {
        if ($op.remoteMutating -and -not $op.applicable) {
            Assert-True `
                (-not [string]::IsNullOrEmpty([string]$op.reason)) `
                "a blocked remote-mutating operation must carry a reason ('$($op.path)')"
        }
    }


    # --------------------------------------------------------------------------
    # Serialized artifact: hashes and metadata only, never contents or secrets
    # --------------------------------------------------------------------------

    $guardJson = $guardArtifact | ConvertTo-Json -Depth 8
    Assert-True `
        ($guardJson -notmatch '(?i)"content"|bearer|authoriz|stagingpath|accesstoken|refreshtoken') `
        "the plan artifact must not contain file contents, tokens, or staging paths"

    foreach ($op in $guardOps) {
        Assert-Null $op.PSObject.Properties['Content'] "an operation row must not carry file content"
        Assert-Null $op.PSObject.Properties['StagingPath'] "an operation row must not carry a staging path"
        Assert-True ($null -ne $op.kinds) "an operation row must carry the three per-side kinds"
    }

    Assert-Equal 'utf8' ([string]$textUpload.kinds.local) "the text upload local kind must be recorded"
    Assert-Equal 'binary' ([string]$binaryUpload.kinds.local) "the binary upload local kind must be recorded"


    # --------------------------------------------------------------------------
    # Atomic persistence: Plan writes, and a leftover tmp never wins
    # --------------------------------------------------------------------------

    Assert-Null `
        (Read-PlanArtifact -WorkspaceRoot $artifactWorkspace) `
        "reading a plan artifact that does not exist must return null"

    Save-PlanArtifact -WorkspaceRoot $artifactWorkspace -Artifact $guardArtifact
    Assert-True (Test-Path -LiteralPath $artifactPath) "Save-PlanArtifact must write last-plan.json"

    $artifactBytes = [System.IO.File]::ReadAllBytes($artifactPath)
    $hasBom = (
        $artifactBytes.Length -ge 3 -and
        $artifactBytes[0] -eq 0xEF -and
        $artifactBytes[1] -eq 0xBB -and
        $artifactBytes[2] -eq 0xBF
    )
    Assert-True (-not $hasBom) "the plan artifact must be written as UTF-8 without a BOM"

    $readBack = Read-PlanArtifact -WorkspaceRoot $artifactWorkspace
    Assert-Equal $guardArtifact.planId $readBack.planId "the plan artifact must round-trip"
    Assert-Equal `
        @($guardArtifact.operations).Count `
        @($readBack.operations).Count `
        "every operation row must round-trip"

    # A crashed write leaves a .tmp that must never be read as the live plan.
    $planTmpPath = Join-Path (Split-Path -Parent $artifactPath) 'last-plan.json.tmp'
    [System.IO.File]::WriteAllText($planTmpPath, '{')
    $afterTmp = Read-PlanArtifact -WorkspaceRoot $artifactWorkspace
    Assert-Equal $guardArtifact.planId $afterTmp.planId "a leftover tmp must not replace the live plan"
    if (Test-Path -LiteralPath $planTmpPath) {
        Remove-Item -LiteralPath $planTmpPath -Force
    }

    # A second save replaces the live artifact atomically.
    Save-PlanArtifact -WorkspaceRoot $artifactWorkspace -Artifact $artifact
    $replaced = Read-PlanArtifact -WorkspaceRoot $artifactWorkspace
    Assert-Equal $artifact.planId $replaced.planId "a second save must replace the live artifact"


    # --------------------------------------------------------------------------
    # Analysis: the single entrypoint the CLI calls
    # --------------------------------------------------------------------------

    $analysis = New-RundotSyncPlanAnalysis `
        -WorkspaceRoot $artifactWorkspace `
        -ProjectId 'proj-test-1' `
        -Resolution $resolution `
        -Local $unionLocal `
        -Remote $unionRemote `
        -Snapshot $snapshot `
        -Command 'Plan' `
        -PersistArtifact

    Assert-True ($null -ne $analysis.Artifact) "the analysis must expose the artifact"
    Assert-True ($null -ne $analysis.Report) "the analysis must expose the report"
    Assert-Equal 3 @($analysis.Operations).Count "the analysis must expose the operation rows"
    Assert-Equal `
        (Get-PlanArtifactPath -WorkspaceRoot $artifactWorkspace) `
        $analysis.ArtifactPath `
        "a persisted Plan must report the artifact path"
    Assert-Equal `
        $analysis.Artifact.planId `
        (Read-PlanArtifact -WorkspaceRoot $artifactWorkspace).planId `
        "a persisted Plan must write exactly the artifact it reported"

    # Status runs the same engine but must not persist.
    Save-PlanArtifact -WorkspaceRoot $artifactWorkspace -Artifact $artifact
    $beforeStatusBytes = [System.IO.File]::ReadAllBytes($artifactPath)

    $statusAnalysis = New-RundotSyncPlanAnalysis `
        -WorkspaceRoot $artifactWorkspace `
        -ProjectId 'proj-test-1' `
        -Resolution $resolution `
        -Local $unionLocal `
        -Remote $unionRemote `
        -Snapshot $snapshot `
        -Command 'Status' `
        -PersistArtifact:$false

    Assert-Equal 'Status' $statusAnalysis.Command "the analysis must record which command ran"
    Assert-True `
        ($null -eq $statusAnalysis.ArtifactPath -or $statusAnalysis.ArtifactPath -eq '') `
        "Status must not report a persisted artifact path"
    Assert-Equal `
        ([System.BitConverter]::ToString($beforeStatusBytes)) `
        ([System.BitConverter]::ToString([System.IO.File]::ReadAllBytes($artifactPath))) `
        "Status must leave an existing plan artifact byte-identical"

    # A fresh workspace proves Status writes nothing when no artifact existed.
    $statusWorkspace = New-SyncPlanTestWorkspace -Root $syncPlanTestRoot
    $statusOnly = New-RundotSyncPlanAnalysis `
        -WorkspaceRoot $statusWorkspace `
        -ProjectId 'proj-test-1' `
        -Resolution $resolution `
        -Local $unionLocal `
        -Remote $unionRemote `
        -Snapshot $snapshot `
        -Command 'Status' `
        -PersistArtifact:$false
    Assert-True `
        (-not (Test-Path -LiteralPath (Get-PlanArtifactPath -WorkspaceRoot $statusWorkspace))) `
        "Status must not create last-plan.json"


    # --------------------------------------------------------------------------
    # Plan never updates BASE, and the artifact is never sync content
    # --------------------------------------------------------------------------

    $baseWorkspace = New-SyncPlanTestWorkspace -Root $syncPlanTestRoot
    $baseFiles = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)
    $baseFiles['src/a.ts'] = (New-SyncPlanTestLocalEntry -Sha256 $syncPlanTestShaA -Size 3)
    Save-BaseManifest -WorkspaceRoot $baseWorkspace -ProjectId 'proj-test-1' -Files $baseFiles

    $liveBaseBefore = Read-BaseManifest -WorkspaceRoot $baseWorkspace
    $liveBaseBytesBefore = [System.IO.File]::ReadAllBytes(
        (Get-BaseManifestPath -WorkspaceRoot $baseWorkspace)
    )

    $baseResolution = New-SyncPlanTestResolution `
        -Base $liveBaseBefore `
        -BasePresent $true `
        -Untrusted $false

    [void](New-RundotSyncPlanAnalysis `
        -WorkspaceRoot $baseWorkspace `
        -ProjectId 'proj-test-1' `
        -Resolution $baseResolution `
        -Local $unionLocal `
        -Remote $unionRemote `
        -Snapshot $snapshot `
        -Command 'Plan' `
        -PersistArtifact)

    $liveBaseAfter = Read-BaseManifest -WorkspaceRoot $baseWorkspace
    Assert-Equal `
        $liveBaseBefore.capturedAt `
        $liveBaseAfter.capturedAt `
        "Plan must never rewrite BASE capturedAt"
    Assert-Equal `
        ([System.BitConverter]::ToString($liveBaseBytesBefore)) `
        ([System.BitConverter]::ToString([System.IO.File]::ReadAllBytes(
            (Get-BaseManifestPath -WorkspaceRoot $baseWorkspace)))) `
        "Plan must leave base-manifest.json byte-identical"

    $baseTrackedCount = @($liveBaseAfter.files.PSObject.Properties).Count
    Assert-Equal 1 $baseTrackedCount "Plan must not add or drop BASE entries"

    # .rundot-sync/last-plan.json can never become local inventory or content.
    $inventory = Get-LocalManifest -WorkspaceRoot $baseWorkspace
    Assert-True `
        (-not $inventory.Contains('.rundot-sync/last-plan.json')) `
        "the plan artifact must never be a local inventory key"

    # Initialize-RundotSyncLayout must still not plant plan state.
    $layoutWorkspace = New-SyncPlanTestWorkspace -Root $syncPlanTestRoot
    Initialize-RundotSyncLayout -WorkspaceRoot $layoutWorkspace
    Assert-True `
        (-not (Test-Path -LiteralPath (Get-PlanArtifactPath -WorkspaceRoot $layoutWorkspace))) `
        "layout initialization must not plant last-plan.json"


    # --------------------------------------------------------------------------
    # Untrusted (-AllowNoBase) plans persist, but are marked untrusted
    # --------------------------------------------------------------------------

    $untrustedWorkspace = New-SyncPlanTestWorkspace -Root $syncPlanTestRoot
    $untrustedResolution = New-SyncPlanTestResolution -Base $null -BasePresent $false -Untrusted $true

    $untrustedAnalysis = New-RundotSyncPlanAnalysis `
        -WorkspaceRoot $untrustedWorkspace `
        -ProjectId 'proj-test-1' `
        -Resolution $untrustedResolution `
        -Local $unionLocal `
        -Remote $unionRemote `
        -Snapshot $snapshot `
        -Command 'Plan' `
        -PersistArtifact

    Assert-Equal $false $untrustedAnalysis.Artifact.basePresent "an untrusted plan must record no BASE"
    Assert-Equal $true $untrustedAnalysis.Artifact.untrusted "an untrusted plan must be marked untrusted"
    Assert-Null $untrustedAnalysis.Artifact.baseCapturedAt "an untrusted plan must not invent baseCapturedAt"
    Assert-True `
        (Test-Path -LiteralPath (Get-PlanArtifactPath -WorkspaceRoot $untrustedWorkspace)) `
        "an -AllowNoBase Plan must still persist its artifact"
    Assert-True `
        (([string]$untrustedAnalysis.Report) -match '(?i)untrusted') `
        "an untrusted plan report must state that direction is untrusted"
    Assert-Equal `
        3 @($untrustedAnalysis.Artifact.operations).Count `
        "an untrusted plan must still classify every union path"


    # --------------------------------------------------------------------------
    # Plan without BASE refuses and leaves no artifact
    # --------------------------------------------------------------------------

    $refusalWorkspace = New-SyncPlanTestWorkspace -Root $syncPlanTestRoot
    Assert-Throws {
        Resolve-RundotSyncPlanBase -WorkspaceRoot $refusalWorkspace -ProjectId 'proj-test-1'
    } "Plan without BASE must refuse by default"
    Assert-True `
        (-not (Test-Path -LiteralPath (Get-PlanArtifactPath -WorkspaceRoot $refusalWorkspace))) `
        "a refused Plan must not leave a plan artifact"


    # --------------------------------------------------------------------------
    # Report layout
    # --------------------------------------------------------------------------

    $report = [string]$analysis.Report
    $reportLines = Get-SyncPlanTestReportLines -Report $report

    Assert-True `
        (($reportLines | Where-Object { $_ -match '^UPLOAD$' }).Count -eq 1) `
        "an upload row must produce exactly one UPLOAD section"
    Assert-True `
        (($reportLines | Where-Object { $_ -match '^DOWNLOAD$' }).Count -eq 1) `
        "a download row must produce exactly one DOWNLOAD section"
    Assert-True `
        (($reportLines | Where-Object { $_ -match '^SUMMARY$' }).Count -eq 1) `
        "the report must contain exactly one SUMMARY section"
    Assert-True `
        (($reportLines | Where-Object { $_ -match '^CONFLICT$' }).Count -eq 0) `
        "a plan with no conflicts must not print a CONFLICT section"
    Assert-True `
        (($reportLines | Where-Object { $_ -match '^IGNORED$' }).Count -eq 0) `
        "a plan with no ignored paths must not print an IGNORED section"
    Assert-True `
        (($reportLines | Where-Object { $_ -match '^UNSUPPORTED$' }).Count -eq 0) `
        "a plan with no kind changes must not print an UNSUPPORTED section"
    Assert-True `
        (($reportLines | Where-Object { $_ -match '^STAGED DELETES$' }).Count -eq 0) `
        "a plan with no delete candidates must not print a STAGED DELETES section"

    Assert-True `
        ($report -match [regex]::Escape([string]$analysis.Artifact.planId)) `
        "the report must show the planId"
    Assert-True `
        ($report -match [regex]::Escape([string]$analysis.Artifact.expiresAt)) `
        "the report must show expiresAt so expiry is visible"
    Assert-True `
        ($report -match [regex]::Escape([string]$analysis.ArtifactPath)) `
        "a persisted Plan report must show where the artifact landed"

    # No-op rows stay hidden unless -IncludeUnchanged is asked for.
    Assert-True `
        ($report -notmatch [regex]::Escape('src/a.ts')) `
        "an unchanged path must be omitted by default"

    $verboseAnalysis = New-RundotSyncPlanAnalysis `
        -WorkspaceRoot $artifactWorkspace `
        -ProjectId 'proj-test-1' `
        -Resolution $resolution `
        -Local $unionLocal `
        -Remote $unionRemote `
        -Snapshot $snapshot `
        -Command 'Plan' `
        -IncludeUnchanged `
        -PersistArtifact:$false

    $verboseReport = [string]$verboseAnalysis.Report
    Assert-True `
        ($verboseReport -match [regex]::Escape('src/a.ts')) `
        "an unchanged path must appear with -IncludeUnchanged"
    Assert-True `
        (($verboseReport -split "`n" | Where-Object { $_ -match '^UNCHANGED$' }).Count -eq 1) `
        "-IncludeUnchanged must add exactly one UNCHANGED section"

    # Section presence is driven by the rows, not hard-coded.
    $deleteAnalysis = New-RundotSyncPlanAnalysis `
        -WorkspaceRoot $artifactWorkspace `
        -ProjectId 'proj-test-1' `
        -Resolution $guardResolution `
        -Local $guardLocal `
        -Remote $guardRemote `
        -Snapshot $snapshot `
        -Command 'Plan' `
        -PersistArtifact:$false
    $deleteReport = [string]$deleteAnalysis.Report
    Assert-True `
        (($deleteReport -split "`n" | Where-Object { $_ -match '^STAGED DELETES$' }).Count -eq 1) `
        "delete candidates must produce a STAGED DELETES section"

    $ignoredLocal = @{ 'dist/bundle.js' = (New-SyncPlanTestLocalEntry -Sha256 $syncPlanTestShaA) }
    $ignoredRemote = @{ 'build/out.js' = (New-SyncPlanTestRemoteEntry -Sha256 $syncPlanTestShaB) }
    $ignoredAnalysis = New-RundotSyncPlanAnalysis `
        -WorkspaceRoot $artifactWorkspace `
        -ProjectId 'proj-test-1' `
        -Resolution $resolution `
        -Local $ignoredLocal `
        -Remote $ignoredRemote `
        -Snapshot $snapshot `
        -Command 'Plan' `
        -PersistArtifact:$false
    $ignoredReport = [string]$ignoredAnalysis.Report
    Assert-True `
        (($ignoredReport -split "`n" | Where-Object { $_ -match '^IGNORED$' }).Count -eq 1) `
        "ignored paths must produce an IGNORED section"

    # Summary counts must equal the row counts.
    $summaryUploadLine = @($reportLines | Where-Object { $_ -match '^\s*upload:\s*(\d+)\s*$' })
    Assert-True ($summaryUploadLine.Count -eq 1) "the SUMMARY must report the upload count once"
    Assert-Equal `
        1 `
        ([int]([regex]::Match([string]$summaryUploadLine[0], '(\d+)').Groups[1].Value)) `
        "the SUMMARY upload count must match the single upload row"
    Assert-True `
        ($report -match '(?m)^\s*total:\s*3\s*$') `
        "the SUMMARY must report the union path total"

    # Every Plan/Status report must end with the three dry-run lines.
    $nonEmpty = Get-SyncPlanTestNonEmptyLines -Report $report
    $count = $nonEmpty.Count
    Assert-Equal `
        'Dry run only. No remote files were modified.' `
        $nonEmpty[$count - 3].Trim() `
        "the report must end with the dry-run line"
    Assert-Equal `
        'This plan is a point-in-time observation, not permission to write.' `
        $nonEmpty[$count - 2].Trim() `
        "the report must end with the point-in-time line"
    Assert-Equal `
        'WARNING: This tool uses unofficial remote API routes that may change.' `
        $nonEmpty[$count - 1].Trim() `
        "the report must end with the unofficial-routes warning"

    Assert-Equal `
        3 @(Get-SyncPlanDryRunClosingLines).Count `
        "the closing lines helper must return exactly three lines"

    $statusNonEmpty = Get-SyncPlanTestNonEmptyLines -Report ([string]$statusAnalysis.Report)
    $statusCount = $statusNonEmpty.Count
    Assert-Equal `
        'Dry run only. No remote files were modified.' `
        $statusNonEmpty[$statusCount - 3].Trim() `
        "a Status report must end with the same dry-run line"


    # --------------------------------------------------------------------------
    # BOM / newline diagnostics: shown, but never a classification input
    # --------------------------------------------------------------------------

    $diagWorkspace = New-SyncPlanTestWorkspace -Root $syncPlanTestRoot
    $stagingRoot = Join-Path $syncPlanTestRoot ("staging-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    $bomBytes = [byte[]](0xEF, 0xBB, 0xBF)

    function New-SyncPlanTestDiagCase {
        param(
            [string]$Name,
            [byte[]]$LocalBytes,
            [byte[]]$RemoteBytes,
            [string]$ExpectedDifference,
            [bool]$ExpectDiagnostic
        )

        $localPath = Join-Path $diagWorkspace $Name
        Write-SyncPlanTestBytes -LiteralPath $localPath -Bytes $LocalBytes

        $stagedPath = Join-Path $stagingRoot ($Name.Replace('/', '-'))
        Write-SyncPlanTestBytes -LiteralPath $stagedPath -Bytes $RemoteBytes

        $localEntry = New-SyncPlanTestLocalEntryFromFile -LiteralPath $localPath
        $remoteEntry = New-SyncPlanTestRemoteEntry `
            -Sha256 (Get-FileSha256Hex -LiteralPath $stagedPath) `
            -Size $RemoteBytes.Length `
            -Kind $localEntry.LocalDetectedKind `
            -StagingPath $stagedPath

        $localMap = @{ $Name = $localEntry }
        $remoteMap = @{ $Name = $remoteEntry }

        $rows = @(Get-SyncPlanChanges -Base $null -Local $localMap -Remote $remoteMap)
        $diagnostics = @(Get-SyncTextDiagnostics `
            -WorkspaceRoot $diagWorkspace `
            -Changes $rows `
            -Local $localMap `
            -Remote $remoteMap)

        if ($ExpectDiagnostic) {
            Assert-Equal 1 $diagnostics.Count ("'$Name' should raise exactly one diagnostic")
            if ($diagnostics.Count -eq 1) {
                Assert-Equal $Name ([string]$diagnostics[0].Path) ("the diagnostic must name '$Name'")
                Assert-Equal `
                    $ExpectedDifference `
                    ([string]$diagnostics[0].Difference) `
                    ("'$Name' must be described as a $ExpectedDifference difference")
            }
        }
        else {
            Assert-Equal 0 $diagnostics.Count ("'$Name' must not be reported as a text-format difference")
        }

        # A diagnostic never changes classification: the bytes genuinely differ.
        Assert-Equal `
            'conflict' `
            ([string]$rows[0].Status) `
            ("'$Name' must stay classified by exact bytes, not by normalized text")

        return $diagnostics
    }

    $newlineText = "line1`nline2`n"

    [void](New-SyncPlanTestDiagCase `
        -Name 'bom-only.ts' `
        -LocalBytes ($utf8NoBom.GetBytes($newlineText)) `
        -RemoteBytes ($bomBytes + $utf8NoBom.GetBytes($newlineText)) `
        -ExpectedDifference 'bom' `
        -ExpectDiagnostic $true)

    [void](New-SyncPlanTestDiagCase `
        -Name 'newline-only.ts' `
        -LocalBytes ($utf8NoBom.GetBytes($newlineText)) `
        -RemoteBytes ($utf8NoBom.GetBytes("line1`r`nline2`r`n")) `
        -ExpectedDifference 'newline' `
        -ExpectDiagnostic $true)

    [void](New-SyncPlanTestDiagCase `
        -Name 'bom-and-newline.ts' `
        -LocalBytes ($utf8NoBom.GetBytes($newlineText)) `
        -RemoteBytes ($bomBytes + $utf8NoBom.GetBytes("line1`r`nline2`r`n")) `
        -ExpectedDifference 'bom+newline' `
        -ExpectDiagnostic $true)

    [void](New-SyncPlanTestDiagCase `
        -Name 'real-difference.ts' `
        -LocalBytes ($utf8NoBom.GetBytes($newlineText)) `
        -RemoteBytes ($utf8NoBom.GetBytes("different`n")) `
        -ExpectedDifference 'none' `
        -ExpectDiagnostic $false)

    # The diagnostic itself must appear in the report when present.
    $diagLocal = @{
        'bom-only.ts' = (New-SyncPlanTestLocalEntryFromFile (Join-Path $diagWorkspace 'bom-only.ts'))
    }
    $diagRemote = @{
        'bom-only.ts' = (New-SyncPlanTestRemoteEntry `
            -Sha256 (Get-FileSha256Hex -LiteralPath (Join-Path $stagingRoot 'bom-only.ts')) `
            -Kind 'utf8' `
            -StagingPath (Join-Path $stagingRoot 'bom-only.ts'))
    }
    $diagAnalysis = New-RundotSyncPlanAnalysis `
        -WorkspaceRoot $diagWorkspace `
        -ProjectId 'proj-test-1' `
        -Resolution $resolution `
        -Local $diagLocal `
        -Remote $diagRemote `
        -Snapshot $snapshot `
        -Command 'Plan' `
        -PersistArtifact:$false
    Assert-True `
        (([string]$diagAnalysis.Report) -match 'DIAGNOSTIC') `
        "a text-format difference must produce a DIAGNOSTIC section"
    Assert-True `
        (([string]$diagAnalysis.Report) -match [regex]::Escape('bom-only.ts')) `
        "the DIAGNOSTIC section must name the affected path"
}
finally {
    if (Test-Path -LiteralPath $syncPlanTestRoot) {
        Remove-Item -LiteralPath $syncPlanTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
