# Canonical path form, safety hard-fails, and default ignores.
# Do not require Pester.

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "lib\Paths.ps1")
. (Join-Path $repoRoot "lib\Ignore.ps1")

$nfcE = [string][char]0x00E9
$nfdE = ([string][char]0x0065) + [char]0x0301
$cjkName = ([string][char]0x6587) + [char]0x4EF6


# --------------------------------------------------------------------------
# Canonical form
# --------------------------------------------------------------------------

Assert-Equal `
    "src/foo bar/baz.ts" `
    (ConvertTo-CanonicalSyncPath -Path "src/foo bar/baz.ts") `
    "spaces should stay in the canonical path"

Assert-Equal `
    ("src/" + $nfcE + $cjkName + ".txt") `
    (ConvertTo-CanonicalSyncPath -Path ("src/" + $nfcE + $cjkName + ".txt")) `
    "unicode NFC and CJK should stay in the canonical path"

Assert-Equal `
    "src/foo/bar.ts" `
    (ConvertTo-CanonicalSyncPath -Path "src\foo\bar.ts") `
    "backslashes should become forward slashes"

Assert-Equal `
    "src/a.ts" `
    (ConvertTo-CanonicalSyncPath -Path "/src/a.ts") `
    "one leading slash from the remote API should be stripped"

Assert-Equal `
    "foo" `
    (ConvertTo-CanonicalSyncPath -Path "/foo") `
    "remote /foo should become relative foo, not a rooted identity"

Assert-Equal `
    "src/foo" `
    (ConvertTo-CanonicalSyncPath -Path "src/foo/") `
    "a trailing slash should be stripped from a file identity"

Assert-Equal `
    ("caf" + $nfcE + ".ts") `
    (ConvertTo-CanonicalSyncPath -Path ("caf" + $nfdE + ".ts")) `
    "NFD identity keys should normalize to NFC"

Assert-Equal `
    "foo/%2e%2e/bar" `
    (ConvertTo-CanonicalSyncPath -Path "foo/%2e%2e/bar") `
    "percent-escapes should stay literal and must not decode to .."


# --------------------------------------------------------------------------
# Hard-fail single paths
# --------------------------------------------------------------------------

Assert-Throws { ConvertTo-CanonicalSyncPath -Path "../foo" } "../foo should hard-fail"
Assert-Throws { ConvertTo-CanonicalSyncPath -Path "..\foo" } "..\foo should hard-fail"
Assert-Throws { ConvertTo-CanonicalSyncPath -Path "foo/../bar" } "foo/../bar should hard-fail"
Assert-Throws { ConvertTo-CanonicalSyncPath -Path "foo/./bar" } "foo/./bar should hard-fail"
Assert-Throws { ConvertTo-CanonicalSyncPath -Path "/" } "a path that is only a slash should hard-fail"
Assert-Throws { ConvertTo-CanonicalSyncPath -Path "C:\foo" } "C:\foo should hard-fail"
Assert-Throws { ConvertTo-CanonicalSyncPath -Path "C:/foo" } "C:/foo should hard-fail"
Assert-Throws { ConvertTo-CanonicalSyncPath -Path "\\server\share" } "UNC backslash path should hard-fail"
Assert-Throws { ConvertTo-CanonicalSyncPath -Path "//server/share" } "UNC forward-slash path should hard-fail"
Assert-Throws { ConvertTo-CanonicalSyncPath -Path ("foo" + [char]0 + "bar") } "embedded NUL should hard-fail"
Assert-Throws { ConvertTo-CanonicalSyncPath -Path "foo//bar" } "foo//bar should hard-fail instead of collapsing"

Assert-Throws { ConvertTo-CanonicalSyncPath -Path "CON" } "CON should hard-fail"
Assert-Throws { ConvertTo-CanonicalSyncPath -Path "CON.txt" } "CON.txt should hard-fail"
Assert-Throws { ConvertTo-CanonicalSyncPath -Path "foo/PRN" } "foo/PRN should hard-fail"
Assert-Throws { ConvertTo-CanonicalSyncPath -Path "foo/NUL.json" } "foo/NUL.json should hard-fail"
Assert-Throws { ConvertTo-CanonicalSyncPath -Path "com1" } "com1 should hard-fail"
Assert-Throws { ConvertTo-CanonicalSyncPath -Path "LPT9" } "LPT9 should hard-fail"
Assert-Throws { ConvertTo-CanonicalSyncPath -Path "aux.TXT" } "aux.TXT should hard-fail"

Assert-Equal `
    "CONSOLE.ts" `
    (ConvertTo-CanonicalSyncPath -Path "CONSOLE.ts") `
    "CONSOLE.ts is not a reserved Win32 device name"

Assert-Throws { Assert-SafeSyncPath -Path "../foo" } "Assert-SafeSyncPath should reject ../foo"
Assert-Throws { Assert-SafeSyncPath -Path "foo//bar" } "Assert-SafeSyncPath should reject empty segments"
Assert-Throws { Assert-SafeSyncPath -Path "NUL.json" } "Assert-SafeSyncPath should reject reserved names with extensions"


# --------------------------------------------------------------------------
# Hard-fail path sets
# --------------------------------------------------------------------------

Assert-Throws {
    Assert-SafeSyncPathSet -Paths @("Foo.ts", "foo.ts")
} "case-insensitive collisions should hard-fail the set"

$nfcFile = "caf" + $nfcE + ".ts"
$nfdFile = "caf" + $nfdE + ".ts"
Assert-Throws {
    Assert-SafeSyncPathSet -Paths @($nfcFile, $nfdFile)
} "NFC/NFD identity collisions should hard-fail instead of merging"

Assert-SafeSyncPathSet -Paths @("src/a.ts", "src/b.ts")


# --------------------------------------------------------------------------
# Local full path conversion
# --------------------------------------------------------------------------

$testRoot = Join-Path $env:TEMP ("rundot-path-tests-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $workspace = Join-Path $testRoot "workspace"
    New-Item -ItemType Directory -Path $workspace | Out-Null

    $nestedDir = Join-Path $workspace "src"
    New-Item -ItemType Directory -Path $nestedDir | Out-Null
    $localFile = Join-Path $nestedDir "foo bar.ts"
    [System.IO.File]::WriteAllText($localFile, "x")

    Assert-Equal `
        "src/foo bar.ts" `
        (ConvertTo-CanonicalSyncPathFromLocal -WorkspaceRoot $workspace -FullPath $localFile) `
        "local full paths should convert relative to the workspace with / separators"

    $outside = Join-Path $testRoot "outside.ts"
    [System.IO.File]::WriteAllText($outside, "x")
    Assert-Throws {
        ConvertTo-CanonicalSyncPathFromLocal -WorkspaceRoot $workspace -FullPath $outside
    } "a path outside the workspace should hard-fail"

    $converted = ConvertTo-LocalFullPath -WorkspaceRoot $workspace -CanonicalPath "src/foo bar.ts"
    $expectedFull = [System.IO.Path]::GetFullPath($localFile)
    $actualFull = $converted
    if (-not [string]::IsNullOrEmpty($converted)) {
        $actualFull = [System.IO.Path]::GetFullPath($converted)
    }
    Assert-Equal `
        $expectedFull `
        $actualFull `
        "canonical paths should convert back to a full path under the workspace"

    Assert-Throws {
        ConvertTo-LocalFullPath -WorkspaceRoot $workspace -CanonicalPath "../secret.ts"
    } "ConvertTo-LocalFullPath should refuse to escape the workspace"


    # ----------------------------------------------------------------------
    # Representability
    # ----------------------------------------------------------------------

    Assert-Throws {
        Assert-SyncPathRepresentable -WorkspaceRoot $workspace -CanonicalPath "a<b>.txt"
    } "invalid Win32 filename characters should hard-fail"

    $longName = ("x" * 300) + ".txt"
    Assert-Throws {
        Assert-SyncPathRepresentable -WorkspaceRoot $workspace -CanonicalPath $longName
    } "a ~300 character path the runtime cannot represent should hard-fail, not skip"


    # ----------------------------------------------------------------------
    # Reparse points
    # ----------------------------------------------------------------------

    $reparseWs = Join-Path $testRoot "reparse-ws"
    $reparseTarget = Join-Path $testRoot "reparse-target"
    New-Item -ItemType Directory -Path $reparseWs | Out-Null
    New-Item -ItemType Directory -Path $reparseTarget | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $reparseWs "ok.ts"), "x")
    New-Item `
        -ItemType Junction `
        -Path (Join-Path $reparseWs "vendor") `
        -Target $reparseTarget | Out-Null

    Assert-Throws {
        Assert-LocalWorkspaceTreeSafe -WorkspaceRoot $reparseWs
    } "a junction under a non-ignored folder should abort"

    $ignoredReparseWs = Join-Path $testRoot "ignored-reparse-ws"
    New-Item -ItemType Directory -Path $ignoredReparseWs | Out-Null
    $nodeModules = Join-Path $ignoredReparseWs "node_modules"
    New-Item -ItemType Directory -Path $nodeModules | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $ignoredReparseWs "app.ts"), "x")
    New-Item `
        -ItemType Junction `
        -Path (Join-Path $nodeModules "pkg") `
        -Target $reparseTarget | Out-Null

    Assert-LocalWorkspaceTreeSafe -WorkspaceRoot $ignoredReparseWs

    $reparseFlag = [int][System.IO.FileAttributes]::ReparsePoint
    $offlineFlag = [int][System.IO.FileAttributes]::Offline
    $recallOnDataAccess = 0x400000
    $recallOnOpen = 0x40000
    $archiveFlag = [int][System.IO.FileAttributes]::Archive

    Assert-True (Test-UnsafeSyncFileAttributes -Attributes $reparseFlag) "ReparsePoint should be unsafe"
    Assert-True (Test-UnsafeSyncFileAttributes -Attributes $offlineFlag) "Offline should be unsafe"
    Assert-True (Test-UnsafeSyncFileAttributes -Attributes $recallOnDataAccess) "recall-on-data-access should be unsafe"
    Assert-True (Test-UnsafeSyncFileAttributes -Attributes $recallOnOpen) "recall-on-open should be unsafe"
    Assert-True (-not (Test-UnsafeSyncFileAttributes -Attributes $archiveFlag)) "Archive alone should be safe"
}
finally {
    if (Test-Path $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}


# --------------------------------------------------------------------------
# Default ignore matcher
# --------------------------------------------------------------------------

$expectedIgnorePatterns = @(
    ".git/",
    ".rundot-sync/",
    "node_modules/",
    "dist/",
    "build/",
    "out/",
    ".vs/",
    ".idea/",
    ".vscode/",
    ".rundot-studio-export/",
    "Thumbs.db",
    "desktop.ini",
    ".DS_Store",
    "*.swp",
    "*~",
    "*.tmp",
    "*.bak"
)

Assert-Equal `
    $expectedIgnorePatterns `
    @(Get-DefaultSyncIgnorePatterns) `
    "the documented default ignore set should be complete and ordered"

Assert-True (Test-IgnoredSyncPath -CanonicalPath ".git/config") ".git/ contents should be ignored"
Assert-True (Test-IgnoredSyncPath -CanonicalPath "src/node_modules/pkg/a.js") "node_modules should match in any segment"
Assert-True (-not (Test-IgnoredSyncPath -CanonicalPath "out.ts")) "out.ts should not match the out/ directory prefix"
Assert-True (Test-IgnoredSyncPath -CanonicalPath "out/index.js") "out/index.js should be ignored"
Assert-True (Test-IgnoredSyncPath -CanonicalPath "dist/bundle.js") "dist/ should be ignored"
Assert-True (Test-IgnoredSyncPath -CanonicalPath "build/app.js") "build/ should be ignored"
Assert-True (Test-IgnoredSyncPath -CanonicalPath ".vs/slnx.sqlite") ".vs/ should be ignored"
Assert-True (Test-IgnoredSyncPath -CanonicalPath ".idea/workspace.xml") ".idea/ should be ignored"
Assert-True (Test-IgnoredSyncPath -CanonicalPath ".vscode/settings.json") ".vscode/ should be ignored"
Assert-True (Test-IgnoredSyncPath -CanonicalPath ".rundot-studio-export/threads/a.json") ".rundot-studio-export/ should be ignored"
Assert-True (Test-IgnoredSyncPath -CanonicalPath "Thumbs.db") "Thumbs.db should be ignored"
Assert-True (Test-IgnoredSyncPath -CanonicalPath "src/desktop.ini") "desktop.ini should be ignored in subfolders"
Assert-True (Test-IgnoredSyncPath -CanonicalPath ".DS_Store") ".DS_Store should be ignored"
Assert-True (Test-IgnoredSyncPath -CanonicalPath "file.swp") "*.swp should be ignored"
Assert-True (Test-IgnoredSyncPath -CanonicalPath "notes.ts~") "*~ should be ignored"
Assert-True (Test-IgnoredSyncPath -CanonicalPath "scratch.tmp") "*.tmp should be ignored"
Assert-True (Test-IgnoredSyncPath -CanonicalPath "old.bak") "*.bak should be ignored"
Assert-True (Test-IgnoredSyncPath -CanonicalPath ".GIT/HEAD") "ignore matching should be case-insensitive"

Assert-True `
    (Test-IgnoredSyncPath -CanonicalPath ".rundot-sync/base-manifest.json") `
    ".rundot-sync/ must be ignored so it can never become an upload candidate"

Assert-True `
    (Test-IgnoredSyncPath -CanonicalPath ".rundot-sync/backups/a.ts") `
    "ignored BASE paths must match the matcher so they never become deleteRemoteCandidate"
