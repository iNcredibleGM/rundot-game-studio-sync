# Local file inventory contracts. Do not require Pester.

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "lib\Paths.ps1")
. (Join-Path $repoRoot "lib\Ignore.ps1")
. (Join-Path $repoRoot "lib\Hashing.ps1")
. (Join-Path $repoRoot "lib\Manifest.ps1")

function Test-ManifestHasPath {
    param($Manifest, [string]$Path)

    if ($null -eq $Manifest) {
        return $false
    }

    return $Manifest.Contains($Path)
}

$testRoot = Join-Path $env:TEMP ("rundot-manifest-tests-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    # A manifest is a file map: empty directories are not sync entities and
    # default-ignore paths do not enter the map.
    $workspace = Join-Path $testRoot "workspace"
    $src = Join-Path $workspace "src"
    New-Item -ItemType Directory -Path $src -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $workspace "empty") | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $workspace "node_modules\pkg") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $workspace ".rundot-sync") | Out-Null

    $sourcePath = Join-Path $src "foo bar.ts"
    $zeroPath = Join-Path $workspace "zero.bin"
    [System.IO.File]::WriteAllBytes($sourcePath, [byte[]](0xC3, 0xA9, 0x0A))
    [System.IO.File]::WriteAllBytes($zeroPath, [byte[]]@())
    [System.IO.File]::WriteAllText((Join-Path $workspace "node_modules\pkg\skip.js"), "ignored")
    [System.IO.File]::WriteAllText((Join-Path $workspace ".rundot-sync\base-manifest.json"), "ignored")

    $manifest = Get-LocalManifest -WorkspaceRoot $workspace

    Assert-True ($null -ne $manifest) "local inventory should return a path map"
    Assert-Equal 2 $manifest.Count "only the two non-ignored files should be inventoried"
    Assert-True (Test-ManifestHasPath -Manifest $manifest -Path "src/foo bar.ts") "nested files should use canonical slash-separated keys"
    Assert-True (Test-ManifestHasPath -Manifest $manifest -Path "zero.bin") "zero-byte files should be normal inventory entries"
    Assert-True (-not (Test-ManifestHasPath -Manifest $manifest -Path "node_modules/pkg/skip.js")) "node_modules contents must be ignored"
    Assert-True (-not (Test-ManifestHasPath -Manifest $manifest -Path ".rundot-sync/base-manifest.json")) ".rundot-sync metadata must never enter local inventory"

    if (Test-ManifestHasPath -Manifest $manifest -Path "src/foo bar.ts") {
        $sourceIdentity = $manifest["src/foo bar.ts"]
        Assert-Equal (Get-FileSha256Hex -LiteralPath $sourcePath) $sourceIdentity.Sha256 "manifest identities must be exact-byte hashes"
        Assert-Equal "utf8" $sourceIdentity.LocalDetectedKind "manifest identities should preserve local kind diagnostics"
    }

    if (Test-ManifestHasPath -Manifest $manifest -Path "zero.bin") {
        $zeroIdentity = $manifest["zero.bin"]
        Assert-Equal 0 $zeroIdentity.Size "zero-byte inventory identity should retain its size"
        Assert-Equal "utf8" $zeroIdentity.LocalDetectedKind "zero-byte files should classify as utf8"
    }

    foreach ($key in @($manifest.Keys)) {
        Assert-True (-not [System.IO.Path]::IsPathRooted([string]$key)) "manifest keys must never be Windows absolute paths"
        Assert-True (-not ([string]$key).Contains("\\")) "manifest keys must use forward-slash identity separators"
    }

    # Reparse points outside ignored directories make a partial local tree
    # unsafe. The scanner must refuse rather than follow the junction.
    $reparseWorkspace = Join-Path $testRoot "reparse-workspace"
    $reparseTarget = Join-Path $testRoot "reparse-target"
    New-Item -ItemType Directory -Path $reparseWorkspace | Out-Null
    New-Item -ItemType Directory -Path $reparseTarget | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $reparseWorkspace "app.ts"), "x")
    New-Item -ItemType Junction -Path (Join-Path $reparseWorkspace "vendor") -Target $reparseTarget | Out-Null

    Assert-Throws {
        Get-LocalManifest -WorkspaceRoot $reparseWorkspace
    } "a non-ignored junction must abort the entire inventory"

    # A locked file cannot be omitted; its sharing violation invalidates the
    # complete inventory.
    $lockedWorkspace = Join-Path $testRoot "locked-workspace"
    New-Item -ItemType Directory -Path $lockedWorkspace | Out-Null
    $lockedPath = Join-Path $lockedWorkspace "locked.ts"
    [System.IO.File]::WriteAllText($lockedPath, "x")
    $lockStream = [System.IO.File]::Open(
        $lockedPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    try {
        Assert-Throws {
            Get-LocalManifest -WorkspaceRoot $lockedWorkspace
        } "an unreadable file must abort the whole inventory instead of being omitted"
    }
    finally {
        $lockStream.Dispose()
    }
}
finally {
    if (Test-Path $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
