# BASE schema v1 ownership, layout, and atomic writes.
# Do not require Pester.

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "lib\Paths.ps1")
. (Join-Path $repoRoot "lib\Hashing.ps1")
. (Join-Path $repoRoot "lib\Workspace.ps1")

$emptySha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
$abcSha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
$testRoot = Join-Path $env:TEMP ("rundot-workspace-tests-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testRoot | Out-Null

function Get-ExpectedLocalRootFingerprint {
    param([string]$WorkspaceRoot)

    $normalized = Get-NormalizedWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $item = Get-Item -LiteralPath $normalized
    $full = $item.FullName.TrimEnd('\')
    $nfc = $full.Normalize([System.Text.NormalizationForm]::FormC)
    $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($nfc)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }

    return [System.BitConverter]::ToString($hash).Replace("-", "").ToLowerInvariant()
}

try {
    $workspace = Join-Path $testRoot "workspace"
    New-Item -ItemType Directory -Path $workspace | Out-Null
    $projectId = "proj-test-1"

    # --------------------------------------------------------------------------
    # Layout: directories only, no fake plan/journal files
    # --------------------------------------------------------------------------

    Initialize-RundotSyncLayout -WorkspaceRoot $workspace
    $syncRoot = Join-Path $workspace ".rundot-sync"
    Assert-True (Test-Path -LiteralPath (Join-Path $syncRoot "backups")) ".rundot-sync/backups should exist"
    Assert-True (Test-Path -LiteralPath (Join-Path $syncRoot "temp")) ".rundot-sync/temp should exist"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $syncRoot "last-plan.json"))) "Initialize should not plant last-plan.json"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $syncRoot "journal.jsonl"))) "Initialize should not plant journal.jsonl"
    Assert-Null (Read-BaseManifest -WorkspaceRoot $workspace) "Read-BaseManifest should return null when BASE is missing"


    # --------------------------------------------------------------------------
    # Fingerprint: on-disk path casing, NFC, no trailing slash
    # --------------------------------------------------------------------------

    $fingerprint = Get-LocalRootFingerprint -WorkspaceRoot $workspace
    Assert-Equal `
        (Get-ExpectedLocalRootFingerprint -WorkspaceRoot $workspace) `
        $fingerprint `
        "fingerprint should be SHA-256 of UTF-8 NFC of the resolved workspace path"
    Assert-Equal `
        $fingerprint `
        (Get-LocalRootFingerprint -WorkspaceRoot $workspace) `
        "fingerprint should be stable for the same on-disk path"

    $otherWorkspace = Join-Path $testRoot "other-workspace"
    New-Item -ItemType Directory -Path $otherWorkspace | Out-Null
    Assert-True `
        ($fingerprint -ne (Get-LocalRootFingerprint -WorkspaceRoot $otherWorkspace)) `
        "a different folder path must produce a different fingerprint"


    # --------------------------------------------------------------------------
    # Atomic round-trip: hashes and metadata only
    # --------------------------------------------------------------------------

    $filesV1 = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)
    $filesV1["src/foo.ts"] = [pscustomobject]@{
        Sha256            = $abcSha256
        Size              = 3
        LocalDetectedKind = "utf8"
        LineEnding        = "lf"
        HasBom            = $false
        Content           = "should-not-be-saved"
    }
    $filesV1["public/logo.png"] = [pscustomobject]@{
        Sha256            = $emptySha256
        Size              = 0
        LocalDetectedKind = "binary"
        Content           = "also-not-saved"
    }

    Save-BaseManifest -WorkspaceRoot $workspace -ProjectId $projectId -Files $filesV1
    $basePath = Join-Path $syncRoot "base-manifest.json"
    Assert-True (Test-Path -LiteralPath $basePath) "Save-BaseManifest should write base-manifest.json"

    $raw = ""
    if (Test-Path -LiteralPath $basePath) {
        $raw = [System.IO.File]::ReadAllText($basePath)
    }
    Assert-True ($raw -notmatch '(?i)token|Authorization|Bearer') "BASE JSON must not contain tokens"
    Assert-True ($raw -notmatch '(?i)"content"') "BASE JSON must not contain file contents"
    Assert-True ($raw -notmatch '(?i)mtime') "BASE JSON must not store mtime"

    $base = Read-BaseManifest -WorkspaceRoot $workspace
    Assert-Equal 1 $base.schemaVersion "BASE schemaVersion should be 1"
    Assert-Equal "0.1.2" $base.toolVersion "BASE toolVersion should be the v0.1.2 milestone"
    Assert-Equal $projectId $base.projectId "BASE should persist projectId"
    Assert-Equal $fingerprint $base.localRootFingerprint "BASE should persist the workspace fingerprint"
    Assert-True (-not [string]::IsNullOrEmpty($base.capturedAt)) "BASE should record capturedAt"

    $foo = $base.files.'src/foo.ts'
    $logo = $base.files.'public/logo.png'
    Assert-Equal $abcSha256 $foo.sha256 "text file hash should round-trip"
    Assert-Equal 3 $foo.size "text file size should round-trip"
    Assert-Equal "utf8" $foo.kind "text file kind should round-trip as kind"
    Assert-Equal "lf" $foo.lineEnding "text file lineEnding should round-trip"
    Assert-Equal $false $foo.hasBom "text file hasBom should round-trip"
    Assert-Equal $emptySha256 $logo.sha256 "binary file hash should round-trip"
    Assert-Equal "binary" $logo.kind "binary file kind should round-trip"
    Assert-Null $logo.lineEnding "binary BASE entries should omit lineEnding"
    Assert-Null $logo.hasBom "binary BASE entries should omit hasBom"
    Assert-True ($foo.sha256 -match '^[0-9a-f]{64}$') "hashes should be 64 lowercase hex chars"


    # --------------------------------------------------------------------------
    # Copied metadata cannot drive another folder or project
    # --------------------------------------------------------------------------

    $copiedWorkspace = Join-Path $testRoot "copied-workspace"
    New-Item -ItemType Directory -Path $copiedWorkspace | Out-Null
    if (Test-Path -LiteralPath $syncRoot) {
        Copy-Item -LiteralPath $syncRoot -Destination (Join-Path $copiedWorkspace ".rundot-sync") -Recurse
    }
    $copiedBase = Read-BaseManifest -WorkspaceRoot $copiedWorkspace
    if ($null -eq $copiedBase) {
        Assert-True $false "copied .rundot-sync must be readable so ownership can reject the other folder"
    }
    else {
        Assert-Throws {
            Assert-BaseOwnership -Base $copiedBase -ProjectId $projectId -WorkspaceRoot $copiedWorkspace
        } "copied .rundot-sync must not own a different workspace folder"
    }

    $owned = [pscustomobject]@{
        schemaVersion         = 1
        projectId             = $projectId
        localRootFingerprint  = $fingerprint
    }
    Assert-BaseOwnership -Base $owned -ProjectId $projectId -WorkspaceRoot $workspace
    Assert-Throws {
        Assert-BaseOwnership -Base $owned -ProjectId "other-project" -WorkspaceRoot $workspace
    } "a different projectId must hard-fail ownership"
    Assert-Throws {
        Assert-BaseOwnership -Base $owned -ProjectId $projectId -WorkspaceRoot $copiedWorkspace
    } "a BASE fingerprint from another folder must hard-fail ownership"

    $wrongSchema = [pscustomobject]@{
        schemaVersion         = 2
        projectId             = $projectId
        localRootFingerprint  = $fingerprint
    }
    Assert-Throws {
        Assert-BaseOwnership -Base $wrongSchema -ProjectId $projectId -WorkspaceRoot $workspace
    } "an unsupported schemaVersion must hard-fail ownership"


    # --------------------------------------------------------------------------
    # Crash leftover .tmp must not replace a complete BASE
    # --------------------------------------------------------------------------

    $tmpPath = Join-Path $syncRoot "base-manifest.json.tmp"
    if (Test-Path -LiteralPath $syncRoot) {
        [System.IO.File]::WriteAllText($tmpPath, "{")
    }
    $afterCrash = Read-BaseManifest -WorkspaceRoot $workspace
    Assert-Equal $projectId $afterCrash.projectId "a leftover tmp must not truncate the live BASE"
    Assert-Equal $abcSha256 $afterCrash.files.'src/foo.ts'.sha256 "live BASE v1 files must remain after a leftover tmp"
    if (Test-Path -LiteralPath $tmpPath) {
        Remove-Item -LiteralPath $tmpPath -Force
    }


    # --------------------------------------------------------------------------
    # Snapshot, not tombstone: omitted paths drop out on the next save
    # --------------------------------------------------------------------------

    $filesV2 = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)
    $filesV2["src/foo.ts"] = [pscustomobject]@{
        Sha256            = $abcSha256
        Size              = 3
        LocalDetectedKind = "utf8"
        LineEnding        = "lf"
        HasBom            = $false
    }

    Save-BaseManifest -WorkspaceRoot $workspace -ProjectId $projectId -Files $filesV2
    $baseV2 = Read-BaseManifest -WorkspaceRoot $workspace
    Assert-Equal $abcSha256 $baseV2.files.'src/foo.ts'.sha256 "atomic replace should keep the complete new BASE"
    Assert-Null $baseV2.files.'public/logo.png' "omitted paths must drop out of BASE rather than remain as tombstones"


    # --------------------------------------------------------------------------
    # No-BASE gate: plan must refuse instead of inventing a sync direction
    # --------------------------------------------------------------------------

    $refusal = Get-RundotSyncMissingBaseRefusalMessage
    Assert-True `
        ($refusal -match [regex]::Escape('-InitMode FromRemote')) `
        "the no-BASE refusal should point at Init -InitMode FromRemote"
    Assert-True `
        ($refusal -match '\bAdopt\b') `
        "the no-BASE refusal should point at Init -InitMode Adopt"
    Assert-True `
        ($refusal -match [regex]::Escape('-Command Init')) `
        "the no-BASE refusal should show a copy-pasteable Init invocation"

    $banner = Get-RundotSyncNoBaseUntrustedBanner
    Assert-True `
        ($banner -match '(?i)untrusted') `
        "the -AllowNoBase banner must say synchronization direction is untrusted"

    $noBaseWorkspace = Join-Path $testRoot "no-base-workspace"
    New-Item -ItemType Directory -Path $noBaseWorkspace | Out-Null

    Assert-Throws {
        Resolve-RundotSyncPlanBase -WorkspaceRoot $noBaseWorkspace -ProjectId $projectId
    } "planning without a BASE must refuse by default"

    Assert-Throws {
        Resolve-RundotSyncPlanBase `
            -WorkspaceRoot $noBaseWorkspace `
            -ProjectId $projectId `
            -AllowNoBase:$false
    } "an explicit -AllowNoBase:`$false must still refuse without a BASE"

    $escaped = Resolve-RundotSyncPlanBase `
        -WorkspaceRoot $noBaseWorkspace `
        -ProjectId $projectId `
        -AllowNoBase
    Assert-Equal $false $escaped.BasePresent "-AllowNoBase must report that BASE is absent"
    Assert-Equal $true $escaped.Untrusted "-AllowNoBase must report an untrusted direction"
    Assert-Null $escaped.Base "-AllowNoBase must not invent a BASE object"

    # A present BASE is returned and still fully ownership-checked.
    $ownedPlanBase = Resolve-RundotSyncPlanBase `
        -WorkspaceRoot $workspace `
        -ProjectId $projectId
    Assert-Equal $true $ownedPlanBase.BasePresent "an owned BASE should be reported as present"
    Assert-Equal $false $ownedPlanBase.Untrusted "an owned BASE should not be untrusted"
    Assert-Equal $projectId $ownedPlanBase.Base.projectId "the resolver should return the owned BASE"

    Assert-Throws {
        Resolve-RundotSyncPlanBase `
            -WorkspaceRoot $workspace `
            -ProjectId "other-project"
    } "the gate must not accept a BASE owned by a different projectId"

    Assert-Throws {
        Resolve-RundotSyncPlanBase `
            -WorkspaceRoot $copiedWorkspace `
            -ProjectId $projectId
    } "the gate must not accept a BASE fingerprinted for a different folder"

    # -AllowNoBase bypasses a *missing* BASE only. It must never launder a
    # present-but-unowned BASE into a trusted one.
    Assert-Throws {
        Resolve-RundotSyncPlanBase `
            -WorkspaceRoot $copiedWorkspace `
            -ProjectId $projectId `
            -AllowNoBase
    } "-AllowNoBase must not bypass ownership of a present BASE"

    Assert-Throws {
        Resolve-RundotSyncPlanBase `
            -WorkspaceRoot $workspace `
            -ProjectId "other-project" `
            -AllowNoBase
    } "-AllowNoBase must not bypass a projectId mismatch on a present BASE"
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
