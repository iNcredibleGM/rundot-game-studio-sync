# Three-way sync classifier contracts: BASE union LOCAL union REMOTE by exact
# SHA-256 content identity. No timestamps. No network. Plan never mutates BASE.
#
# Do not require Pester.
#
# SCOPE NOTE: tests/Run-Tests.ps1 dot-sources every *.Tests.ps1 into one
# scope, in filename order. This file sorts after SyncCli.Tests.ps1 and before
# Workspace.Tests.ps1. Helpers here are prefixed New-SyncEngineTest* /
# Get-SyncEngine* / Assert-SyncEngine* so they never shadow a library function
# another test file depends on. The classifier makes no network calls, so no
# stub region or RemoteApi restore is needed.

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "lib\Paths.ps1")
. (Join-Path $repoRoot "lib\Ignore.ps1")
. (Join-Path $repoRoot "lib\Hashing.ps1")
. (Join-Path $repoRoot "lib\Workspace.ps1")
. (Join-Path $repoRoot "lib\Manifest.ps1")
. (Join-Path $repoRoot "lib\Snapshot.ps1")
. (Join-Path $repoRoot "lib\Classifier.ps1")


# --------------------------------------------------------------------------
# Fixtures: fabricated identity rows in each real on-disk shape.
#
# BASE entries are lowercase (sha256, size, kind, lineEnding, hasBom, with the
# text-only fields omitted for binary). LOCAL entries are PascalCase from
# Get-LocalFileIdentity (Sha256, Size, LocalDetectedKind, LineEnding, HasBom).
# REMOTE entries are PascalCase from the stable snapshot (plus RemoteKind and
# Encoding). The classifier must read all three without normalizing callers.
# --------------------------------------------------------------------------

$syncEngineEmptySha256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
$syncEngineShaA = 'a' * 64
$syncEngineShaB = 'b' * 64
$syncEngineShaC = 'c' * 64

function New-SyncEngineTestBaseEntry {
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

function New-SyncEngineTestLocalEntry {
    param(
        [string]$Sha256,
        [int64]$Size = 0,
        [string]$Kind = 'utf8',
        $LineEnding = 'lf',
        $HasBom = $false
    )

    if ($Kind -eq 'utf8') {
        return [pscustomobject]@{
            Sha256            = $Sha256
            Size              = $Size
            LocalDetectedKind = $Kind
            LineEnding        = $LineEnding
            HasBom            = $HasBom
        }
    }

    return [pscustomobject]@{
        Sha256            = $Sha256
        Size              = $Size
        LocalDetectedKind = $Kind
        LineEnding        = $null
        HasBom            = $null
    }
}

function New-SyncEngineTestRemoteEntry {
    param(
        [string]$Sha256,
        [int64]$Size = 0,
        [string]$Kind = 'utf8',
        [string]$Encoding = 'utf8'
    )

    if ([string]::IsNullOrEmpty($Encoding)) {
        $Encoding = 'utf8'
    }

    return [pscustomobject]@{
        Sha256            = $Sha256
        Size              = $Size
        LocalDetectedKind = $Kind
        RemoteKind        = $Kind
        Encoding          = $Encoding
        StagingPath       = "C:\staging\$Sha256"
    }
}

function New-SyncEngineTestLocalEntryFromFile {
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

function Write-SyncEngineTestRepeatingBytes {
    param(
        [string]$LiteralPath,
        [int64]$Length,
        [scriptblock]$FillBuffer
    )

    $buffer = New-Object byte[] 65536
    & $FillBuffer $buffer

    $out = [System.IO.File]::Open(
        $LiteralPath,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
    )
    try {
        $remaining = $Length
        while ($remaining -gt 0) {
            $chunk = $buffer.Length
            if ($chunk -gt $remaining) {
                $chunk = $remaining
            }

            $out.Write($buffer, 0, $chunk)
            $remaining -= $chunk
        }
    }
    finally {
        $out.Dispose()
    }
}

function Get-SyncEngineRowForPath {
    param(
        [object[]]$Rows,
        [string]$Path
    )

    foreach ($row in @($Rows)) {
        if ([string]::Equals([string]$row.Path, $Path, [System.StringComparison]::Ordinal)) {
            return $row
        }
    }

    return $null
}

function Assert-SyncEngineStatus {
    param(
        [object[]]$Rows,
        [string]$Path,
        [string]$ExpectedStatus,
        [string]$Message
    )

    $row = Get-SyncEngineRowForPath -Rows $Rows -Path $Path
    if ($null -eq $row) {
        Assert-True $false ("expected a classified row for '$Path' (" + $Message + ")")
        return $null
    }

    Assert-Equal $ExpectedStatus ([string]$row.Status) ("status for '$Path': " + $Message)
    return $row
}


# --------------------------------------------------------------------------
# Status vocabulary: literal strings, one source of truth for the CLI
# --------------------------------------------------------------------------

Assert-Equal 'unchanged' $SyncStatusUnchanged "the unchanged status should be the literal 'unchanged'"
Assert-Equal 'synchronized-change' $SyncStatusSynchronizedChange "the two-sided equal-change status should be 'synchronized-change'"
Assert-Equal 'synchronized-addition' $SyncStatusSynchronizedAddition "the two-sided equal-addition status should be 'synchronized-addition'"
Assert-Equal 'settledAbsent' $SyncStatusSettledAbsent "the settled-absent status should be 'settledAbsent'"
Assert-Equal 'upload' $SyncStatusUpload "the local-only-change status should be 'upload'"
Assert-Equal 'download' $SyncStatusDownload "the remote-only-change status should be 'download'"
Assert-Equal 'conflict' $SyncStatusConflict "the ambiguous status should be 'conflict'"
Assert-Equal 'ignored' $SyncStatusIgnored "the ignored status should be 'ignored'"
Assert-Equal 'deleteRemoteCandidate' $SyncStatusDeleteRemoteCandidate "the remote-deletion status should be 'deleteRemoteCandidate'"
Assert-Equal 'deleteLocalCandidate' $SyncStatusDeleteLocalCandidate "the local-deletion status should be 'deleteLocalCandidate'"


# --------------------------------------------------------------------------
# Identity readers: tolerant of BASE lowercase vs LOCAL/REMOTE PascalCase
# --------------------------------------------------------------------------

$baseA = New-SyncEngineTestBaseEntry -Sha256 $syncEngineShaA
$localA = New-SyncEngineTestLocalEntry -Sha256 $syncEngineShaA
$remoteA = New-SyncEngineTestRemoteEntry -Sha256 $syncEngineShaA

Assert-Equal $syncEngineShaA (Get-SyncEntrySha256 -Entry $baseA) "a BASE entry hash should come from sha256"
Assert-Equal $syncEngineShaA (Get-SyncEntrySha256 -Entry $localA) "a LOCAL entry hash should come from Sha256"
Assert-Equal $syncEngineShaA (Get-SyncEntrySha256 -Entry $remoteA) "a REMOTE entry hash should come from Sha256"
Assert-Null (Get-SyncEntrySha256 -Entry $null) "a missing entry has no content hash"

Assert-Equal 'utf8' (Get-SyncEntryKind -Entry $baseA) "a BASE kind should come from kind"
Assert-Equal 'utf8' (Get-SyncEntryKind -Entry $localA) "a LOCAL kind should come from LocalDetectedKind"
Assert-Equal `
    'binary' `
    (Get-SyncEntryKind -Entry (New-SyncEngineTestRemoteEntry -Sha256 $syncEngineShaB -Kind 'binary' -Encoding 'base64')) `
    "a REMOTE kind should come from RemoteKind"
Assert-Null (Get-SyncEntryKind -Entry $null) "a missing entry has no kind"


# --------------------------------------------------------------------------
# Decision table: existing cases, additions, and deletions
#
# Notation: BASE / LOCAL / REMOTE. $null means the path is missing on that
# side. Each case is one row of the issue's tables.
# --------------------------------------------------------------------------

$baseB = New-SyncEngineTestBaseEntry -Sha256 $syncEngineShaB
$baseC = New-SyncEngineTestBaseEntry -Sha256 $syncEngineShaC
$localB = New-SyncEngineTestLocalEntry -Sha256 $syncEngineShaB
$localC = New-SyncEngineTestLocalEntry -Sha256 $syncEngineShaC
$remoteB = New-SyncEngineTestRemoteEntry -Sha256 $syncEngineShaB
$remoteC = New-SyncEngineTestRemoteEntry -Sha256 $syncEngineShaC

$syncEngineStatusCases = @(
    # Existing
    @{ Name = 'A / A / A'; Base = $baseA; Local = $localA; Remote = $remoteA; Status = 'unchanged' }
    @{ Name = 'A / B / A'; Base = $baseA; Local = $localB; Remote = $remoteA; Status = 'upload' }
    @{ Name = 'A / A / B'; Base = $baseA; Local = $localA; Remote = $remoteB; Status = 'download' }
    @{ Name = 'A / B / C'; Base = $baseA; Local = $localB; Remote = $remoteC; Status = 'conflict' }
    @{ Name = 'A / B / B'; Base = $baseA; Local = $localB; Remote = $remoteB; Status = 'synchronized-change' }

    # Additions
    @{ Name = '- / A / -'; Base = $null; Local = $localA; Remote = $null; Status = 'upload' }
    @{ Name = '- / - / A'; Base = $null; Local = $null; Remote = $remoteA; Status = 'download' }
    @{ Name = '- / A / A'; Base = $null; Local = $localA; Remote = $remoteA; Status = 'synchronized-addition' }
    @{ Name = '- / A / B'; Base = $null; Local = $localA; Remote = $remoteB; Status = 'conflict' }

    # Deletions (classification only; v0.1.3 performs no delete)
    @{ Name = 'A / - / A'; Base = $baseA; Local = $null; Remote = $remoteA; Status = 'deleteRemoteCandidate' }
    @{ Name = 'A / A / -'; Base = $baseA; Local = $localA; Remote = $null; Status = 'deleteLocalCandidate' }
    @{ Name = 'A / - / B'; Base = $baseA; Local = $null; Remote = $remoteB; Status = 'conflict' }
    @{ Name = 'A / B / -'; Base = $baseA; Local = $localB; Remote = $null; Status = 'conflict' }
    @{ Name = 'A / - / -'; Base = $baseA; Local = $null; Remote = $null; Status = 'settledAbsent' }
)

foreach ($case in $syncEngineStatusCases) {
    $actualStatus = Get-SyncPathChangeStatus `
        -Path 'src/a.ts' `
        -Base $case.Base `
        -Local $case.Local `
        -Remote $case.Remote

    Assert-Equal ([string]$case.Status) ([string]$actualStatus) ("three-way table " + $case.Name)
}

# The classifier is called once per union path, so it must not depend on any
# cross-path state: the same three identities classify identically under a
# second, unrelated path.
Assert-Equal `
    (Get-SyncPathChangeStatus -Path 'src/a.ts' -Base $baseA -Local $localB -Remote $remoteA) `
    (Get-SyncPathChangeStatus -Path 'deep/nested/other.bin' -Base $baseA -Local $localB -Remote $remoteA) `
    "classification must be a pure function of the three identities, not of the path name"


# --------------------------------------------------------------------------
# Applicability and reasons: what Plan/Pull may act on
# --------------------------------------------------------------------------

$uploadRow = Get-SyncPlanChange -Path 'src/a.ts' -Base $baseA -Local $localB -Remote $remoteA
Assert-Equal 'upload' ([string]$uploadRow.Status) "a text upload candidate keeps the upload status"
Assert-Equal $true $uploadRow.Applicable "a text upload candidate is applicable"
Assert-Null $uploadRow.Reason "an applicable upload candidate carries no reason"
Assert-Equal $false $uploadRow.Ignored "an ordinary path is not ignored"

$downloadRow = Get-SyncPlanChange -Path 'src/a.ts' -Base $baseA -Local $localA -Remote $remoteB
Assert-Equal 'download' ([string]$downloadRow.Status) "a remote-only change keeps the download status"
Assert-Equal $true $downloadRow.Applicable "a download candidate is applicable"

$unchangedRow = Get-SyncPlanChange -Path 'src/a.ts' -Base $baseA -Local $localA -Remote $remoteA
Assert-Equal 'unchanged' ([string]$unchangedRow.Status) "an unchanged path keeps the unchanged status"
Assert-Equal $false $unchangedRow.Applicable "an unchanged path is not actionable"
Assert-Null $unchangedRow.Reason "an unchanged path carries no reason"

$syncChangeRow = Get-SyncPlanChange -Path 'src/a.ts' -Base $baseA -Local $localB -Remote $remoteB
Assert-Equal 'synchronized-change' ([string]$syncChangeRow.Status) "a both-sides equal change keeps its status"
Assert-Equal $false $syncChangeRow.Applicable "a synchronized change is not actionable"

$syncAdditionRow = Get-SyncPlanChange -Path 'src/a.ts' -Base $null -Local $localA -Remote $remoteA
Assert-Equal 'synchronized-addition' ([string]$syncAdditionRow.Status) "a both-sides equal addition keeps its status"
Assert-Equal $false $syncAdditionRow.Applicable "a synchronized addition is not actionable"

$conflictRow = Get-SyncPlanChange -Path 'src/a.ts' -Base $baseA -Local $localB -Remote $remoteC
Assert-Equal 'conflict' ([string]$conflictRow.Status) "a three-way difference keeps the conflict status"
Assert-Equal $false $conflictRow.Applicable "a conflict is never actionable"
Assert-True ($null -ne $conflictRow.Reason) "a conflict should explain itself"

# Deletions are classified but never applicable in v0.1.3, and the reason must
# say so rather than implying a delete will happen.
$deleteRemoteRow = Get-SyncPlanChange -Path 'src/a.ts' -Base $baseA -Local $null -Remote $remoteA
Assert-Equal 'deleteRemoteCandidate' ([string]$deleteRemoteRow.Status) "a remote deletion keeps its status"
Assert-Equal $false $deleteRemoteRow.Applicable "a delete candidate is not actionable in this milestone"
Assert-True `
    ([string]$deleteRemoteRow.Reason -match '(?i)classification-only') `
    "a delete candidate reason should say deletion is classification-only"
Assert-True `
    ([string]$deleteRemoteRow.Reason -notmatch '(?i)bearer|token') `
    "a delete candidate reason must never contain credentials"

$deleteLocalRow = Get-SyncPlanChange -Path 'src/a.ts' -Base $baseA -Local $localA -Remote $null
Assert-Equal 'deleteLocalCandidate' ([string]$deleteLocalRow.Status) "a local deletion keeps its status"
Assert-Equal $false $deleteLocalRow.Applicable "a local delete candidate is not actionable in this milestone"

$settledRow = Get-SyncPlanChange -Path 'src/a.ts' -Base $baseA -Local $null -Remote $null
Assert-Equal 'settledAbsent' ([string]$settledRow.Status) "a settled-absent path keeps its status"
Assert-Equal $false $settledRow.Applicable "a settled-absent path is not a standing delete"


# --------------------------------------------------------------------------
# Ignore precedence: ignored first, so it can never be an action or a delete
# --------------------------------------------------------------------------

# A BASE path now ignored, gone from both LOCAL and REMOTE, must not become a
# deleteRemoteCandidate. This is the exact contract in docs/path-safety.md.
foreach ($ignoredPath in @('dist/bundle.js', 'node_modules/pkg/index.js', '.rundot-sync/temp/x.ts')) {
    $ignoredRow = Get-SyncPlanChange -Path $ignoredPath -Base $baseA -Local $null -Remote $null
    Assert-Equal 'ignored' ([string]$ignoredRow.Status) ("ignored BASE path '$ignoredPath' must classify as ignored")
    Assert-Equal $true $ignoredRow.Ignored ("ignored BASE path '$ignoredPath' must set the ignored flag")
    Assert-Equal $false $ignoredRow.Applicable ("ignored BASE path '$ignoredPath' must not be actionable")
    Assert-True `
        (([string]$ignoredRow.Status) -ne 'deleteRemoteCandidate') `
        ("ignored BASE path '$ignoredPath' must never be a deleteRemoteCandidate")
}

# An ignored LOCAL-only path must not become an upload candidate.
$ignoredLocalRow = Get-SyncPlanChange -Path 'dist/scratch.tmp' -Base $null -Local $localA -Remote $null
Assert-Equal 'ignored' ([string]$ignoredLocalRow.Status) "an ignored local-only path must classify as ignored"
Assert-True `
    (([string]$ignoredLocalRow.Status) -ne 'upload') `
    "an ignored local path must never be an upload candidate"

# An ignored REMOTE-only path must not become a download candidate.
$ignoredRemoteRow = Get-SyncPlanChange -Path 'build/out.js' -Base $null -Local $null -Remote $remoteA
Assert-Equal 'ignored' ([string]$ignoredRemoteRow.Status) "an ignored remote-only path must classify as ignored"
Assert-True `
    (([string]$ignoredRemoteRow.Status) -ne 'download') `
    "an ignored remote path must never be a download candidate"

# Ignore wins even when hashes disagree: an ignored path is settled, not a
# conflict, because it is out of sync scope entirely.
$ignoredConflictRow = Get-SyncPlanChange -Path 'dist/bundle.js' -Base $baseA -Local $localB -Remote $remoteC
Assert-Equal 'ignored' ([string]$ignoredConflictRow.Status) "an ignored path must be ignored regardless of content differences"


# --------------------------------------------------------------------------
# Metadata disagreement with equal hashes: no-op plus a warning
# --------------------------------------------------------------------------

$sizeMismatchBase = New-SyncEngineTestBaseEntry -Sha256 $syncEngineShaA -Size 1
$sizeMismatchLocal = New-SyncEngineTestLocalEntry -Sha256 $syncEngineShaA -Size 2
$sizeMismatchRow = Get-SyncPlanChange `
    -Path 'src/a.ts' `
    -Base $sizeMismatchBase `
    -Local $sizeMismatchLocal `
    -Remote $remoteA

Assert-Equal 'unchanged' ([string]$sizeMismatchRow.Status) "equal hashes with a size disagreement stay unchanged"
Assert-True `
    (-not [string]::IsNullOrEmpty([string]$sizeMismatchRow.Warning)) `
    "equal hashes with a size disagreement must raise a warning"

$kindMismatchBase = New-SyncEngineTestBaseEntry -Sha256 $syncEngineShaA -Kind 'utf8'
$kindMismatchLocal = New-SyncEngineTestLocalEntry -Sha256 $syncEngineShaA -Kind 'binary'
$kindMismatchRow = Get-SyncPlanChange `
    -Path 'src/a.ts' `
    -Base $kindMismatchBase `
    -Local $kindMismatchLocal `
    -Remote $remoteA

Assert-Equal 'unchanged' ([string]$kindMismatchRow.Status) "equal hashes with a kind disagreement stay unchanged: equal bytes win"
Assert-True `
    (-not [string]::IsNullOrEmpty([string]$kindMismatchRow.Warning)) `
    "equal hashes with a kind disagreement must raise a warning"

# Equal hashes with no disagreement must not raise a warning.
Assert-True `
    ([string]::IsNullOrEmpty([string]$unchangedRow.Warning)) `
    "agreeing metadata must not raise a warning"

# Test-SyncMetadataAgreement reports the disagreeing field names, and nothing
# for an agreeing pair.
$agreeingFields = @(Test-SyncMetadataAgreement -Left $baseA -Right $localA)
Assert-Equal 0 $agreeingFields.Count "identical declared metadata must report no disagreements"

$disagreeingFields = @(Test-SyncMetadataAgreement -Left $sizeMismatchBase -Right $sizeMismatchLocal)
Assert-True ($disagreeingFields -contains 'size') "a size disagreement must name the size field"


# --------------------------------------------------------------------------
# Unsupported kind change: text <-> binary with differing content
# --------------------------------------------------------------------------

$textBase = New-SyncEngineTestBaseEntry -Sha256 $syncEngineShaA -Kind 'utf8'
$binaryLocal = New-SyncEngineTestLocalEntry -Sha256 $syncEngineShaB -Kind 'binary'
$textRemote = New-SyncEngineTestRemoteEntry -Sha256 $syncEngineShaA -Kind 'utf8'

$localKindChange = Get-SyncPlanChange -Path 'src/a.ts' -Base $textBase -Local $binaryLocal -Remote $textRemote
Assert-Equal `
    'conflict' `
    ([string]$localKindChange.Status) `
    "text -> binary with differing content must be a conflict, not an upload"
Assert-Equal $false $localKindChange.Applicable "an unsupported kind change is not actionable"
Assert-Equal $true $localKindChange.KindChange "an unsupported kind change must set the kind-change flag"
Assert-True `
    ([string]$localKindChange.Reason -match '(?i)kind') `
    "an unsupported kind change reason should name the kind change"

$binaryRemote = New-SyncEngineTestRemoteEntry -Sha256 $syncEngineShaB -Kind 'binary' -Encoding 'base64'
$remoteKindChange = Get-SyncPlanChange -Path 'src/a.ts' -Base $textBase -Local $localA -Remote $binaryRemote
Assert-Equal `
    'conflict' `
    ([string]$remoteKindChange.Status) `
    "text -> binary with differing content must be a conflict, not a download"
Assert-Equal $true $remoteKindChange.KindChange "a remote kind change must set the kind-change flag"

# A binary -> binary two-sided change is an ordinary upload, not a kind change.
$binaryBase = New-SyncEngineTestBaseEntry -Sha256 $syncEngineShaA -Kind 'binary'
$binaryLocalB = New-SyncEngineTestLocalEntry -Sha256 $syncEngineShaB -Kind 'binary'
$binaryRemoteA = New-SyncEngineTestRemoteEntry -Sha256 $syncEngineShaA -Kind 'binary' -Encoding 'base64'
$binaryChangeRow = Get-SyncPlanChange -Path 'src/a.png' -Base $binaryBase -Local $binaryLocalB -Remote $binaryRemoteA
Assert-Equal 'upload' ([string]$binaryChangeRow.Status) "a binary -> binary change is an ordinary upload"
Assert-Equal $false $binaryChangeRow.KindChange "a binary -> binary change is not a kind change"


# --------------------------------------------------------------------------
# Binary upload candidates: still UPLOAD, never relabelled skip
# --------------------------------------------------------------------------

$binaryUploadRow = Get-SyncPlanChange -Path 'public/logo.png' -Base $binaryBase -Local $binaryLocalB -Remote $binaryRemoteA
Assert-Equal 'upload' ([string]$binaryUploadRow.Status) "a binary upload candidate must still display as upload"
Assert-True `
    (([string]$binaryUploadRow.Status) -ne 'skip') `
    "a binary upload candidate must never be relabelled 'skip'"
Assert-Equal $false $binaryUploadRow.Applicable "a binary upload candidate is not applicable until #15"
Assert-Equal `
    'Remote binary replacement semantics are unverified.' `
    ([string]$binaryUploadRow.Reason) `
    "a binary upload candidate must carry the fixed unverified-semantics reason"

# A brand-new binary file is the same conservative case.
$newBinaryRow = Get-SyncPlanChange -Path 'public/new.png' -Base $null -Local $binaryLocalB -Remote $null
Assert-Equal 'upload' ([string]$newBinaryRow.Status) "a new binary file must still display as upload"
Assert-Equal $false $newBinaryRow.Applicable "a new binary file is not applicable until #15"
Assert-Equal `
    'Remote binary replacement semantics are unverified.' `
    ([string]$newBinaryRow.Reason) `
    "a new binary file must carry the fixed unverified-semantics reason"

# A text upload stays applicable, so the flag is genuinely about binaries.
$textUploadRow = Get-SyncPlanChange -Path 'src/new.ts' -Base $null -Local $localA -Remote $null
Assert-Equal 'upload' ([string]$textUploadRow.Status) "a new text file displays as upload"
Assert-Equal $true $textUploadRow.Applicable "a new text file is applicable"
Assert-Null $textUploadRow.Reason "an applicable text upload carries no reason"


# --------------------------------------------------------------------------
# Zero-byte and large binary files: ordinary classification, real hashes
# --------------------------------------------------------------------------

$syncEngineTestRoot = Join-Path $env:TEMP ("rundot-sync-engine-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $syncEngineTestRoot | Out-Null

try {
    $zeroPath = Join-Path $syncEngineTestRoot "zero.ts"
    [System.IO.File]::WriteAllBytes($zeroPath, [byte[]]@())
    $zeroLocal = New-SyncEngineTestLocalEntryFromFile -LiteralPath $zeroPath

    Assert-Equal $syncEngineEmptySha256 $zeroLocal.Sha256 "a zero-byte file must hash to the empty SHA-256"
    Assert-Equal 0 $zeroLocal.Size "a zero-byte file must report size 0"

    $zeroRemote = New-SyncEngineTestRemoteEntry -Sha256 $syncEngineEmptySha256 -Size 0
    $zeroAdditionRow = Get-SyncPlanChange -Path 'zero.ts' -Base $null -Local $zeroLocal -Remote $zeroRemote
    Assert-Equal `
        'synchronized-addition' `
        ([string]$zeroAdditionRow.Status) `
        "a zero-byte file present on both sides must classify normally"

    $zeroBase = New-SyncEngineTestBaseEntry -Sha256 $syncEngineEmptySha256 -Size 0 -LineEnding 'none'
    $zeroUnchangedRow = Get-SyncPlanChange -Path 'zero.ts' -Base $zeroBase -Local $zeroLocal -Remote $zeroRemote
    Assert-Equal `
        'unchanged' `
        ([string]$zeroUnchangedRow.Status) `
        "a zero-byte file tracked in BASE must classify as unchanged"
    Assert-True `
        ([string]::IsNullOrEmpty([string]$zeroUnchangedRow.Warning)) `
        "a zero-byte file must not raise a spurious metadata warning"

    $largePath = Join-Path $syncEngineTestRoot "large-binary.bin"
    $largeSize = 16 * 1024 * 1024
    Write-SyncEngineTestRepeatingBytes `
        -LiteralPath $largePath `
        -Length $largeSize `
        -FillBuffer {
            param($Buffer)
            for ($i = 0; $i -lt $Buffer.Length; $i++) {
                $Buffer[$i] = [byte]($i % 256)
            }
        }

    $largeLocal = New-SyncEngineTestLocalEntryFromFile -LiteralPath $largePath
    Assert-Equal 'binary' $largeLocal.LocalDetectedKind "a 16 MiB mixed-byte file must classify as binary"
    Assert-Equal `
        (Get-FileSha256Hex -LiteralPath $largePath) `
        $largeLocal.Sha256 `
        "a large binary must be hashed by the streaming helper, not loaded into memory"
    Assert-Equal $largeSize $largeLocal.Size "a large binary identity size must match its byte length"

    $largeRow = Get-SyncPlanChange -Path 'public/large-binary.bin' -Base $null -Local $largeLocal -Remote $null
    Assert-Equal 'upload' ([string]$largeRow.Status) "a large binary local-only file must classify as upload"
    Assert-Equal $false $largeRow.Applicable "a large binary upload candidate is not applicable until #15"

    # A large binary already identical on both sides is a synchronized
    # addition, proving size does not change the decision.
    $largeRemote = New-SyncEngineTestRemoteEntry `
        -Sha256 $largeLocal.Sha256 `
        -Size $largeLocal.Size `
        -Kind 'binary' `
        -Encoding 'base64'
    $largeSameRow = Get-SyncPlanChange -Path 'public/large-binary.bin' -Base $null -Local $largeLocal -Remote $largeRemote
    Assert-Equal `
        'synchronized-addition' `
        ([string]$largeSameRow.Status) `
        "a large binary identical on both sides must classify as a synchronized addition"
}
finally {
    if (Test-Path -LiteralPath $syncEngineTestRoot) {
        Remove-Item -LiteralPath $syncEngineTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}


# --------------------------------------------------------------------------
# Duplicate canonical paths from GET /files abort before classification
#
# The classifier is only ever handed validated maps. This asserts the gate
# that produces them, so a duplicate list never reaches the decision table.
# --------------------------------------------------------------------------

function New-SyncEngineTestRemoteRow {
    param(
        [string]$Path,
        [string]$Type = 'file',
        [int64]$Size = 1
    )

    return [pscustomobject]@{
        path = $Path
        type = $Type
        size = $Size
    }
}

Assert-Throws {
    Get-RemoteManifestFileRows -Manifest ([pscustomobject]@{
        files = @(
            (New-SyncEngineTestRemoteRow -Path '/foo.ts'),
            (New-SyncEngineTestRemoteRow -Path 'foo.ts')
        )
    })
} "duplicate canonical paths from GET /files must abort before classification"

Assert-Equal `
    'foo.ts' `
    (ConvertTo-CanonicalSyncPath -Path '/foo.ts') `
    "a leading API slash must canonicalize away, which is why /foo.ts and foo.ts collide"


# --------------------------------------------------------------------------
# Torn or failed snapshots are rejected, never read as "remote deleted all"
# --------------------------------------------------------------------------

$syncEngineBaseMap = @{ 'src/a.ts' = $baseA }
$syncEngineLocalMap = @{ 'src/a.ts' = $localA }
$syncEngineRemoteMap = @{ 'src/a.ts' = $remoteA }

Assert-Throws {
    Get-SyncPlanChanges -Base $syncEngineBaseMap -Local $syncEngineLocalMap -Remote $null
} "a missing REMOTE map must refuse rather than imply remote deletion"

Assert-Throws {
    Get-SyncPlanChanges -Base $syncEngineBaseMap -Local $null -Remote $syncEngineRemoteMap
} "a missing LOCAL map must refuse rather than imply local deletion"

Assert-Throws {
    Get-SyncPlanChanges -Base 'not-a-map' -Local $syncEngineLocalMap -Remote $syncEngineRemoteMap
} "a non-map BASE must refuse instead of being treated as absent"

Assert-Throws {
    Get-SyncPlanChanges -Base $syncEngineBaseMap -Local $syncEngineLocalMap -Remote 'not-a-map'
} "a non-map REMOTE must refuse instead of being treated as absent"

# The whole-BASE-absent case is legitimate under -AllowNoBase and must be
# accepted, and behaved identically to an empty BASE map.
$absentBasePlan = @(Get-SyncPlanChanges -Base $null -Local $syncEngineLocalMap -Remote $syncEngineRemoteMap)
$emptyBasePlan = @(Get-SyncPlanChanges -Base @{} -Local $syncEngineLocalMap -Remote $syncEngineRemoteMap)
Assert-Equal 1 @($absentBasePlan).Count "a null BASE must still classify every union path"
Assert-Equal `
    ([string]$absentBasePlan[0].Status) `
    ([string]$emptyBasePlan[0].Status) `
    "a null BASE and an empty BASE must classify identically"
Assert-Equal `
    'synchronized-addition' `
    ([string]$absentBasePlan[0].Status) `
    "without BASE, an identical LOCAL and REMOTE path is a synchronized addition"


# --------------------------------------------------------------------------
# Union, ordering, hashes, and row shape
# --------------------------------------------------------------------------

$unionBase = @{ 'src/a.ts' = $baseA }
$unionLocal = @{ 'src/a.ts' = $localA; 'src/b.ts' = $localB }
$unionRemote = @{ 'src/a.ts' = $remoteA; 'src/c.ts' = $remoteC }

$unionRows = @(Get-SyncPlanChanges -Base $unionBase -Local $unionLocal -Remote $unionRemote)
Assert-Equal 3 @($unionRows).Count "every path in BASE union LOCAL union REMOTE must get exactly one row"

Assert-SyncEngineStatus -Rows $unionRows -Path 'src/a.ts' -ExpectedStatus 'unchanged' -Message 'present on all three sides'
Assert-SyncEngineStatus -Rows $unionRows -Path 'src/b.ts' -ExpectedStatus 'upload' -Message 'local-only'
Assert-SyncEngineStatus -Rows $unionRows -Path 'src/c.ts' -ExpectedStatus 'download' -Message 'remote-only'

$rowA = Get-SyncEngineRowForPath -Rows $unionRows -Path 'src/a.ts'
Assert-Equal $syncEngineShaA ([string]$rowA.BaseSha256) "a row must carry the BASE hash"
Assert-Equal $syncEngineShaA ([string]$rowA.LocalSha256) "a row must carry the LOCAL hash"
Assert-Equal $syncEngineShaA ([string]$rowA.RemoteSha256) "a row must carry the REMOTE hash"

$rowB = Get-SyncEngineRowForPath -Rows $unionRows -Path 'src/b.ts'
Assert-Null $rowB.BaseSha256 "a BASE-absent row must not invent a BASE hash"
Assert-Null $rowB.RemoteSha256 "a REMOTE-absent row must not invent a REMOTE hash"

# Rows are ordinal-sorted by canonical path so Plan output is stable.
$unsortedBase = @{}
$unsortedLocal = @{ 'z.ts' = $localA; 'src/a.ts' = $localA; 'src/b.ts' = $localA }
$unsortedRemote = @{}
$sortedRows = @(Get-SyncPlanChanges -Base $unsortedBase -Local $unsortedLocal -Remote $unsortedRemote)
$sortedPaths = @($sortedRows | ForEach-Object { [string]$_.Path })
Assert-Equal `
    @('src/a.ts', 'src/b.ts', 'z.ts') `
    $sortedPaths `
    "rows must be ordinal-sorted by canonical path"

$secondOrder = @(Get-SyncPlanChanges -Base $unsortedBase -Local $unsortedLocal -Remote $unsortedRemote)
$secondPaths = @($secondOrder | ForEach-Object { [string]$_.Path })
Assert-Equal $sortedPaths $secondPaths "classification order must be deterministic across calls"


# --------------------------------------------------------------------------
# Purity: classification mutates nothing and writes no BASE
# --------------------------------------------------------------------------

$purityWorkspace = Join-Path $env:TEMP ("rundot-sync-engine-purity-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $purityWorkspace | Out-Null

try {
    $purityBase = @{ 'src/a.ts' = $baseA; 'src/b.ts' = $baseB }
    $purityLocal = @{ 'src/a.ts' = $localB }
    $purityRemote = @{ 'src/a.ts' = $remoteA; 'src/c.ts' = $remoteC }

    $purityBaseCount = $purityBase.Count
    $purityBaseSentinel = [string]$purityBase['src/a.ts'].sha256

    [void](Get-SyncPlanChanges -Base $purityBase -Local $purityLocal -Remote $purityRemote)

    Assert-Equal $purityBaseCount $purityBase.Count "classification must not add or remove BASE entries"
    Assert-Equal `
        $purityBaseSentinel `
        ([string]$purityBase['src/a.ts'].sha256) `
        "classification must not rewrite a BASE entry"
    Assert-True `
        ($purityBase.ContainsKey('src/b.ts')) `
        "classification must not drop an unvisited BASE entry"

    Assert-Null `
        (Read-BaseManifest -WorkspaceRoot $purityWorkspace) `
        "classification must never write BASE"

    # A local file appearing after a scan is visible to the next plan, and the
    # earlier result does not retroactively change.
    $scanLocal = @{ 'src/a.ts' = $localA }
    $firstPlan = @(Get-SyncPlanChanges -Base $syncEngineBaseMap -Local $scanLocal -Remote $syncEngineRemoteMap)
    Assert-Equal 1 @($firstPlan).Count "the first plan sees only the scanned local paths"

    $scanLocal['late.ts'] = $localB
    $secondPlan = @(Get-SyncPlanChanges -Base $syncEngineBaseMap -Local $scanLocal -Remote $syncEngineRemoteMap)
    Assert-Equal 2 @($secondPlan).Count "a local file added after the scan must appear in the next plan"
    Assert-SyncEngineStatus -Rows $secondPlan -Path 'late.ts' -ExpectedStatus 'upload' -Message 'added after the scan'
    Assert-Equal 1 @($firstPlan).Count "an earlier plan result must not grow when LOCAL changes later"
}
finally {
    if (Test-Path -LiteralPath $purityWorkspace) {
        Remove-Item -LiteralPath $purityWorkspace -Recurse -Force -ErrorAction SilentlyContinue
    }
}
