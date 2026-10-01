# Root .gitignore layer (#64): an additive floor over the built-in ignore set.
#
# Do not require Pester.
#
# SCOPE NOTE: tests/Run-Tests.ps1 dot-sources every *.Tests.ps1 into one
# scope. The ignore context is per-run state, so this file clears it in a
# finally block and never leaves a rule set for a later file.

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "lib\Paths.ps1")
. (Join-Path $repoRoot "lib\Ignore.ps1")
. (Join-Path $repoRoot "lib\Hashing.ps1")
. (Join-Path $repoRoot "lib\Progress.ps1")
. (Join-Path $repoRoot "lib\Workspace.ps1")
. (Join-Path $repoRoot "lib\Manifest.ps1")
. (Join-Path $repoRoot "lib\Classifier.ps1")


# --------------------------------------------------------------------------
# Parsing: comments, blanks, negation, and normalization
# --------------------------------------------------------------------------

$parsed = @(Get-SyncGitIgnoreRules -Text "`n# comment`n`n*.log`n!/keep.log`nbuild/`n")

Assert-Equal 3 $parsed.Count "blank lines and comments should not become rules"
Assert-Equal "*.log" ([string]$parsed[0].Text) "a plain rule should be kept"
Assert-Equal $false ([bool]$parsed[0].Negated) "a plain rule is not a negation"
Assert-Equal $true ([bool]$parsed[1].Negated) "a leading ! should be recorded as a negation"
Assert-Equal "!/keep.log" ([string]$parsed[1].Text) "the negation line text should be preserved verbatim"
Assert-Equal "build" ([string]$parsed[2].Leaf) "a trailing slash should be stripped from the leaf"

$anchored = @(Get-SyncGitIgnoreRules -Text "/config.json`nlogs/debug.log`n*.log")
Assert-Equal $true ([bool]$anchored[0].Anchored) "a leading slash should anchor the rule"
Assert-Equal $true ([bool]$anchored[1].Anchored) "an internal slash should anchor the rule"
Assert-Equal $false ([bool]$anchored[2].Anchored) "a truly slashless rule is unanchored"

$backslash = @(Get-SyncGitIgnoreRules -Text "audio\cache\")
Assert-Equal "audio/cache" ([string]$backslash[0].Text) "backslashes should normalize to forward slashes"
Assert-Equal "audio/cache" (@($backslash[0].Segments) -join '/') "backslashes should split into segments"

Assert-Throws { Get-SyncGitIgnoreRules -Text ".." } "a '..' rule should fail closed"
Assert-Throws { Get-SyncGitIgnoreRules -Text "foo//bar" } "an empty segment should fail closed"
Assert-Throws { Get-SyncGitIgnoreRules -Text "/" } "a rule that is only a slash should fail closed"
Assert-Throws { Get-SyncGitIgnoreRules -Text "!" } "an empty negation should fail closed"

$bom = [char]0xFEFF
$bomRule = @(Get-SyncGitIgnoreRules -Text "$bom*.log")
Assert-Equal 1 $bomRule.Count "a BOM should not create an extra rule"
Assert-Equal "*.log" ([string]$bomRule[0].Text) "a UTF-8 BOM should be stripped from the first rule"


# --------------------------------------------------------------------------
# Matching semantics
# --------------------------------------------------------------------------

Clear-SyncIgnoreContext
[void](Set-SyncIgnoreContext -Text "*.log`nsecrets/`n/root-only.txt`nassets/img.png")

Assert-True (Test-GitIgnoredSyncPath -CanonicalPath "debug.log") "a slashless glob should match at the root"
Assert-True (Test-GitIgnoredSyncPath -CanonicalPath "src/deep/debug.log") "a slashless glob should match at any depth"
Assert-True (Test-GitIgnoredSyncPath -CanonicalPath "secrets/api.key") "a directory rule should ignore its contents"
Assert-True (Test-GitIgnoredSyncPath -CanonicalPath "a/b/secrets/api.key") "a slashless directory rule should match at any depth"
Assert-True (Test-GitIgnoredSyncPath -CanonicalPath "root-only.txt") "an anchored rule should match at the root"
Assert-True (-not (Test-GitIgnoredSyncPath -CanonicalPath "sub/root-only.txt")) "an anchored rule must not match a nested path"
Assert-True (Test-GitIgnoredSyncPath -CanonicalPath "assets/img.png") "a rule with a slash should match its exact relative path"
Assert-True (-not (Test-GitIgnoredSyncPath -CanonicalPath "other/assets/img.png")) "a rule with a slash is anchored to the root"
Assert-True (-not (Test-GitIgnoredSyncPath -CanonicalPath "keep.log.txt")) "a glob should not over-match a longer name"

# A negation is recorded but never obeyed in this patch.
Clear-SyncIgnoreContext
[void](Set-SyncIgnoreContext -Text "*.log`n!/keep.log")
Assert-True (Test-GitIgnoredSyncPath -CanonicalPath "keep.log") "a negation must not re-include a path in this patch"
$negationNotice = @(Get-SyncIgnoreLayerNotice)
Assert-True ($negationNotice.Count -ge 1) "the layer notice should be emitted when a gitignore is present"
Assert-True (([string]::Join("`n", $negationNotice)).Contains("!/keep.log")) "the notice should name the un-obeyed negation"


# --------------------------------------------------------------------------
# Additive floor: a gitignore negation cannot re-include a built-in ignore
# --------------------------------------------------------------------------

Clear-SyncIgnoreContext
[void](Set-SyncIgnoreContext -Text "!.git/`n!node_modules/")
Assert-True (Test-IgnoredSyncPath -CanonicalPath ".git/config") "a negation must not re-include the built-in .git/ ignore"
Assert-True (Test-IgnoredSyncPath -CanonicalPath "node_modules/pkg/a.js") "a negation must not re-include the built-in node_modules/ ignore"

# A gitignore can only add: an unrelated built-in still applies.
Clear-SyncIgnoreContext
[void](Set-SyncIgnoreContext -Text "*.log")
Assert-True (Test-IgnoredSyncPath -CanonicalPath "dist/bundle.js") "the built-in set still applies alongside a gitignore"
Assert-True (Test-IgnoredSyncPath -CanonicalPath "app.log") "the gitignore rule applies too"


# --------------------------------------------------------------------------
# Inventory integration: a gitignored path is not a candidate
# --------------------------------------------------------------------------

$testRoot = Join-Path $env:TEMP ("rundot-gitignore-tests-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $workspace = Join-Path $testRoot "ws"
    New-Item -ItemType Directory -Path $workspace | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $workspace "app.ts"), "export const a = 1;`n")
    [System.IO.File]::WriteAllText((Join-Path $workspace "app.log"), "noise`n")
    [System.IO.File]::WriteAllText((Join-Path $workspace ".env.local"), "SECRET=1`n")
    New-Item -ItemType Directory -Path (Join-Path $workspace "secrets") | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $workspace "secrets\api.key"), "k`n")
    [System.IO.File]::WriteAllText(
        (Join-Path $workspace ".gitignore"),
        "*.log`n.env.local`nsecrets/`n"
    )

    $manifest = Get-LocalManifest -WorkspaceRoot $workspace

    Assert-True ($manifest.Contains("app.ts")) "a tracked file should be inventoried"
    Assert-True (-not $manifest.Contains("app.log")) "a gitignored glob match should not be inventoried"
    Assert-True (-not $manifest.Contains(".env.local")) "a gitignored secret should not be inventoried"
    Assert-True (-not $manifest.Contains("secrets/api.key")) "a gitignored directory should not be inventoried"
    Assert-True ($manifest.Contains(".gitignore")) ".gitignore is not in the built-in set and should be inventoried"

    # Asymmetry guard: a BASE path hidden only by a local rule must classify
    # as ignored, never as a deleteRemoteCandidate.
    $baseEntry = [pscustomobject]@{ sha256 = ('a' * 64); size = 3; kind = 'utf8' }
    $remoteEntry = [pscustomobject]@{
        Sha256     = ('a' * 64)
        Size       = 3
        RemoteKind = 'utf8'
    }

    $status = Get-SyncPathChangeStatus `
        -Path "secrets/api.key" `
        -Base $baseEntry `
        -Local $null `
        -Remote $remoteEntry

    Assert-Equal "ignored" $status "a gitignored BASE path must classify as ignored, not a delete candidate"

    $statusUnignored = Get-SyncPathChangeStatus `
        -Path "src/gone.ts" `
        -Base $baseEntry `
        -Local $null `
        -Remote $remoteEntry

    Assert-Equal "deleteRemoteCandidate" $statusUnignored "a non-ignored absent local path still plans a delete candidate"

    # A parse failure fails the run closed before any inventory.
    [System.IO.File]::WriteAllText((Join-Path $workspace ".gitignore"), "..`n")
    Assert-Throws {
        Get-LocalManifest -WorkspaceRoot $workspace
    } "a malformed .gitignore must fail the run closed, not silently skip"
}
finally {
    Clear-SyncIgnoreContext
    if (Test-Path $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
