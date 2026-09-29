# Local inventory contracts. Do not require Pester.

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "lib\Paths.ps1")
. (Join-Path $repoRoot "lib\Ignore.ps1")
. (Join-Path $repoRoot "lib\Hashing.ps1")
. (Join-Path $repoRoot "lib\Progress.ps1")
. (Join-Path $repoRoot "lib\Manifest.ps1")

$nfcE = [string][char]0x00E9
$nfdE = ([string][char]0x0065) + [char]0x0301
$testRoot = Join-Path $env:TEMP ("rundot-manifest-tests-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    # Files, not directories, are inventory entities.  Ignored paths must
    # never become inventory keys, even though they physically exist.
    $workspace = Join-Path $testRoot "workspace"
    $src = Join-Path $workspace "src"
    $emptyDirectory = Join-Path $workspace "empty-directory"
    $nodeModules = Join-Path $workspace "node_modules"
    $syncDirectory = Join-Path $workspace ".rundot-sync"
    New-Item -ItemType Directory -Path $src, $emptyDirectory, $nodeModules, $syncDirectory -Force | Out-Null

    $sourcePath = Join-Path $src "foo bar.ts"
    $zeroPath = Join-Path $workspace "zero.ts"
    $nfdPath = Join-Path $src ("caf" + $nfdE + ".ts")
    [System.IO.File]::WriteAllBytes($sourcePath, [System.Text.Encoding]::UTF8.GetBytes("export const value = 1;`n"))
    [System.IO.File]::WriteAllBytes($zeroPath, [byte[]]@())
    [System.IO.File]::WriteAllBytes($nfdPath, [byte[]](0x61))
    [System.IO.File]::WriteAllBytes((Join-Path $nodeModules "package.js"), [byte[]](0x61))
    [System.IO.File]::WriteAllBytes((Join-Path $syncDirectory "base-manifest.json"), [byte[]](0x7B, 0x7D))
    [System.IO.File]::WriteAllBytes((Join-Path $workspace "scratch.tmp"), [byte[]](0x61))

    $manifest = Get-LocalManifest -WorkspaceRoot $workspace
    $expectedNfcKey = "src/caf" + $nfcE + ".ts"

    Assert-True ($null -ne $manifest) "Get-LocalManifest should return a file map"
    Assert-True ($manifest -is [System.Collections.IDictionary]) "the local manifest should be keyed by canonical path"
    Assert-True ($null -ne $manifest -and $manifest.Contains("src/foo bar.ts")) "nested source files should be inventory entries"
    Assert-True ($null -ne $manifest -and $manifest.Contains("zero.ts")) "zero-byte files should be inventory entries"
    Assert-True ($null -ne $manifest -and $manifest.Contains($expectedNfcKey)) "local keys should use NFC canonical paths"
    Assert-True ($null -ne $manifest -and -not $manifest.Contains("node_modules/package.js")) "ignored node_modules files should not be inventoried"
    Assert-True ($null -ne $manifest -and -not $manifest.Contains(".rundot-sync/base-manifest.json")) ".rundot-sync state must never be inventoried"
    Assert-True ($null -ne $manifest -and -not $manifest.Contains("scratch.tmp")) "ignored leaf globs should not be inventoried"
    Assert-Equal 3 $(if ($null -eq $manifest) { 0 } else { $manifest.Count }) "empty directories and ignored files must not become entries"

    $sourceIdentity = if ($null -eq $manifest) { $null } else { $manifest["src/foo bar.ts"] }
    $zeroIdentity = if ($null -eq $manifest) { $null } else { $manifest["zero.ts"] }
    Assert-Equal "utf8" $sourceIdentity.LocalDetectedKind "manifest entries should retain byte-derived kind diagnostics"
    Assert-Equal "lf" $sourceIdentity.LineEnding "manifest entries should retain line-ending diagnostics"
    Assert-Equal 0 $zeroIdentity.Size "zero-byte entries should retain their exact size"
    Assert-Equal "utf8" $zeroIdentity.LocalDetectedKind "zero-byte entries should hash and classify normally"

    $hasAbsoluteKey = $false
    if ($null -ne $manifest) {
        foreach ($key in $manifest.Keys) {
            if ([System.IO.Path]::IsPathRooted([string]$key) -or $key -match '\\') {
                $hasAbsoluteKey = $true
            }
        }
    }
    Assert-True (-not $hasAbsoluteKey) "manifest keys must be relative slash paths, never Windows absolute paths"

    # -ShowProgress prints a start and final line and still inventories the
    # same map. It must never change the result.
    $script:ManifestTestProgressLines = New-Object 'System.Collections.Generic.List[string]'
    $previousWriter = $script:RundotSyncProgressWriter
    $script:RundotSyncProgressWriter = {
        param([string]$Text)
        $script:ManifestTestProgressLines.Add($Text)
    }
    try {
        $progressManifest = Get-LocalManifest -WorkspaceRoot $workspace -ShowProgress
    }
    finally {
        $script:RundotSyncProgressWriter = $previousWriter
    }

    $progressLines = @($script:ManifestTestProgressLines.ToArray())
    Assert-True ($progressLines.Count -ge 2) "hashing with -ShowProgress must print at least a start and final line"
    Assert-True `
        ($progressLines[0] -match 'Hashing local files') `
        "the hashing start line must be plain text"
    Assert-True `
        ($progressLines[$progressLines.Count - 1] -match 'Hashed 3 local file') `
        "the hashing final line must report the count"
    Assert-Equal `
        $(if ($null -eq $manifest) { 0 } else { $manifest.Count }) `
        $(if ($null -eq $progressManifest) { 0 } else { $progressManifest.Count }) `
        "progress must not change the inventory result"

    # A reparse point in a scanned directory is unsafe; it must abort rather
    # than silently follow or omit an unknown portion of the tree.
    $reparseWorkspace = Join-Path $testRoot "reparse-workspace"
    $reparseTarget = Join-Path $testRoot "reparse-target"
    New-Item -ItemType Directory -Path $reparseWorkspace, $reparseTarget | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $reparseWorkspace "app.ts"), [byte[]](0x61))
    New-Item -ItemType Junction -Path (Join-Path $reparseWorkspace "vendor") -Target $reparseTarget | Out-Null
    Assert-Throws {
        Get-LocalManifest -WorkspaceRoot $reparseWorkspace
    } "a non-ignored junction must abort the whole local inventory"

    # Progress must not soften fail-closed: a junction still aborts with
    # -ShowProgress on.
    Assert-Throws {
        Get-LocalManifest -WorkspaceRoot $reparseWorkspace -ShowProgress
    } "a non-ignored junction must still abort with -ShowProgress on"

    # An unreadable listed file must likewise abort; a partial map could later
    # be mistaken for deletion candidates.
    $lockedWorkspace = Join-Path $testRoot "locked-workspace"
    New-Item -ItemType Directory -Path $lockedWorkspace | Out-Null
    $lockedPath = Join-Path $lockedWorkspace "locked.ts"
    [System.IO.File]::WriteAllBytes($lockedPath, [byte[]](0x61))
    $lockStream = [System.IO.File]::Open(
        $lockedPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    try {
        Assert-Throws {
            Get-LocalManifest -WorkspaceRoot $lockedWorkspace
        } "an unreadable file must abort the whole local inventory"
        Assert-Throws {
            Get-LocalManifest -WorkspaceRoot $lockedWorkspace -ShowProgress
        } "an unreadable file must still abort with -ShowProgress on"
    }
    finally {
        $lockStream.Dispose()
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --------------------------------------------------------------------------
# Progress: hashing a local tree reports a start line, per-file lines, and a
# final count, without changing fail-closed behavior.
# --------------------------------------------------------------------------

$manifestProgressRoot = Join-Path $env:TEMP ("rundot-manifest-progress-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $manifestProgressRoot | Out-Null

try {
    $progressWorkspace = Join-Path $manifestProgressRoot "workspace"
    New-Item -ItemType Directory -Path $progressWorkspace | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $progressWorkspace "a.ts"), [byte[]](0x61))
    [System.IO.File]::WriteAllBytes((Join-Path $progressWorkspace "b.ts"), [byte[]](0x62))

    $manifestProgressLines = New-Object 'System.Collections.Generic.List[string]'
    $script:RundotSyncProgressWriter = {
        param([string]$Text)
        $manifestProgressLines.Add($Text)
    }

    try {
        $progressManifest = Get-LocalManifest -WorkspaceRoot $progressWorkspace -ShowProgress
        $lines = @($manifestProgressLines.ToArray())

        Assert-Equal 2 $progressManifest.Count "the manifest must still inventory every file with progress on"
        Assert-True ($lines.Count -ge 2) "progress must emit at least a start and a final line"
        Assert-True `
            ($lines[0] -match '(?i)hashing local files') `
            "the first progress line must announce that local hashing started"
        Assert-True `
            ($lines[$lines.Count - 1] -match '(?i)hashed 2 local file') `
            "the final progress line must report the hashed count"
        Assert-True `
            (-not ($lines -match '(?i)token|authorization|bearer')) `
            "progress lines must never contain credential text"
    }
    finally {
        $script:RundotSyncProgressWriter = $null
    }

    # Fail-closed with progress on: an unreadable file still aborts, and the
    # final "hashed" line is not printed as if the inventory succeeded.
    $progressLocked = Join-Path $manifestProgressRoot "locked"
    New-Item -ItemType Directory -Path $progressLocked | Out-Null
    $progressLockedPath = Join-Path $progressLocked "locked.ts"
    [System.IO.File]::WriteAllBytes($progressLockedPath, [byte[]](0x61))
    $progressLockStream = [System.IO.File]::Open(
        $progressLockedPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )

    $progressLockLines = New-Object 'System.Collections.Generic.List[string]'
    $script:RundotSyncProgressWriter = {
        param([string]$Text)
        $progressLockLines.Add($Text)
    }
    try {
        Assert-Throws {
            Get-LocalManifest -WorkspaceRoot $progressLocked -ShowProgress
        } "progress must not change the fail-closed hash behavior"
    }
    finally {
        $progressLockStream.Dispose()
        $script:RundotSyncProgressWriter = $null
    }
}
finally {
    if (Test-Path -LiteralPath $manifestProgressRoot) {
        Remove-Item -LiteralPath $manifestProgressRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
