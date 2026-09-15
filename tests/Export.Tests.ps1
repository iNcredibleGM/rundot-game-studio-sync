# game-studio-export.ps1 destination gate (Option B).
#
# The exporter cannot be dot-sourced for testing: it has a param() block and
# runs top to bottom starting with authentication. The destination gate is
# therefore a library contract in lib/Export.ps1, and the CLI wiring (the gate
# runs before authentication) is asserted from source text, the same way
# tests/SyncCli.Tests.ps1 checks game-studio-sync.ps1.
#
# Do not require Pester. Network is not used.

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "lib\Paths.ps1")
. (Join-Path $repoRoot "lib\Ignore.ps1")
. (Join-Path $repoRoot "lib\Export.ps1")

$exportTestRoot = Join-Path $env:TEMP ("rundot-export-dest-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $exportTestRoot | Out-Null

function New-ExportTestDirectory {
    param([string]$Name)

    $path = Join-Path $exportTestRoot $Name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Get-ExportTestRefusal {
    param([string]$OutDir)

    try {
        Assert-RundotExportDestination -OutDir $OutDir
    }
    catch {
        return $_.Exception
    }

    return $null
}

try {
    # ----------------------------------------------------------------------
    # Allowed pre-existing entries
    # ----------------------------------------------------------------------

    Assert-Equal `
        @('.git', '.gitignore') `
        @(Get-RundotExportAllowedRootMetadata) `
        "a raw export target may only already contain .git and .gitignore"

    # A missing destination is created, not refused: that is the normal
    # first-export case.
    $freshDir = Join-Path $exportTestRoot "fresh"
    Assert-RundotExportDestination -OutDir $freshDir
    Assert-True `
        (Test-Path -LiteralPath $freshDir -PathType Container) `
        "a missing export destination should be created"

    # An empty directory passes.
    Assert-RundotExportDestination -OutDir $freshDir

    # Regression guard: an empty destination must report zero entries, not a
    # single empty-string element from PowerShell array unrolling.
    Assert-Equal `
        0 `
        @(Get-RundotExportUnexpectedEntries -OutDir $freshDir).Count `
        "an empty destination must report zero unexpected entries, not one blank"

    # Only .git passes, with contents present.
    $gitOnly = New-ExportTestDirectory "git-only"
    New-Item -ItemType Directory -Path (Join-Path $gitOnly ".git") -Force | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $gitOnly ".git\HEAD"), [byte[]](0x61))
    Assert-RundotExportDestination -OutDir $gitOnly

    # A .git pointer file (worktree/submodule layout) also passes.
    $gitFile = New-ExportTestDirectory "git-file"
    [System.IO.File]::WriteAllBytes((Join-Path $gitFile ".git"), [byte[]](0x61))
    Assert-RundotExportDestination -OutDir $gitFile

    # Only .gitignore passes.
    $ignoreOnly = New-ExportTestDirectory "ignore-only"
    [System.IO.File]::WriteAllBytes((Join-Path $ignoreOnly ".gitignore"), [byte[]](0x61))
    Assert-RundotExportDestination -OutDir $ignoreOnly

    # Both together pass.
    $bothMeta = New-ExportTestDirectory "both-metadata"
    New-Item -ItemType Directory -Path (Join-Path $bothMeta ".git") -Force | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $bothMeta ".gitignore"), [byte[]](0x61))
    Assert-RundotExportDestination -OutDir $bothMeta

    # ----------------------------------------------------------------------
    # .rundot-sync is NOT tolerated here, unlike Init
    #
    # Init tolerates a leftover .rundot-sync so a re-run after a failed
    # attempt needs no manual cleanup. Export must do the opposite: a
    # .rundot-sync means this directory is a sync workspace, and dumping a
    # second copy of the project over it is the silent-refresh path Option B
    # removes.
    # ----------------------------------------------------------------------

    $syncDir = New-ExportTestDirectory "sync-dir"
    New-Item -ItemType Directory -Path (Join-Path $syncDir ".rundot-sync\temp") -Force | Out-Null
    Assert-Equal `
        @('.rundot-sync') `
        @(Get-RundotExportUnexpectedEntries -OutDir $syncDir) `
        "a .rundot-sync directory must be reported as unexpected"

    $syncDirRefusal = Get-ExportTestRefusal -OutDir $syncDir
    Assert-True ($null -ne $syncDirRefusal) "an export into a .rundot-sync workspace must refuse"
    if ($null -ne $syncDirRefusal) {
        Assert-True `
            ($syncDirRefusal.Message -match [regex]::Escape('.rundot-sync')) `
            "the refusal should name .rundot-sync as the offender"
    }

    # The tolerance in Init is name-based, so a .rundot-sync that is a *file*
    # is tolerated there. Export must refuse that too.
    $syncAsFile = New-ExportTestDirectory "sync-as-file"
    [System.IO.File]::WriteAllBytes((Join-Path $syncAsFile ".rundot-sync"), [byte[]](0x61))
    Assert-Equal `
        @('.rundot-sync') `
        @(Get-RundotExportUnexpectedEntries -OutDir $syncAsFile) `
        "a .rundot-sync file must be reported as unexpected"
    Assert-True `
        ($null -ne (Get-ExportTestRefusal -OutDir $syncAsFile)) `
        "a .rundot-sync file must refuse, unlike Init"

    # The thread archive directory is also not a raw export target.
    $threadArchive = New-ExportTestDirectory "thread-archive"
    New-Item -ItemType Directory -Path (Join-Path $threadArchive ".rundot-studio-export\threads") -Force | Out-Null
    Assert-True `
        ($null -ne (Get-ExportTestRefusal -OutDir $threadArchive)) `
        "a previous thread archive must refuse rather than be silently refreshed"

    # ----------------------------------------------------------------------
    # Unexpected project content refuses and points at sync
    # ----------------------------------------------------------------------

    $dirtyDir = New-ExportTestDirectory "dirty"
    New-Item -ItemType Directory -Path (Join-Path $dirtyDir "src") -Force | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $dirtyDir "src\app.ts"), [byte[]](0x61))

    Assert-Equal `
        @('src') `
        @(Get-RundotExportUnexpectedEntries -OutDir $dirtyDir) `
        "unexpected entries should report the top-level offender"

    $dirtyRefusal = Get-ExportTestRefusal -OutDir $dirtyDir
    Assert-True ($null -ne $dirtyRefusal) "a dirty export destination must refuse"
    if ($null -ne $dirtyRefusal) {
        Assert-True `
            ($dirtyRefusal.Message -match 'src') `
            "the dirty refusal should name the offending entry"
        Assert-True `
            ($dirtyRefusal.Message -match [regex]::Escape('game-studio-sync.ps1')) `
            "the dirty refusal should point at game-studio-sync.ps1"
        Assert-True `
            ($dirtyRefusal.Message -match [regex]::Escape('-Command Pull')) `
            "the dirty refusal should direct the user to -Command Pull"
        Assert-True `
            ($dirtyRefusal.Message -match [regex]::Escape($dirtyDir)) `
            "the dirty refusal should name the destination it refused"
        # No BASE here, so Pull alone would be a dead end; Init Adopt is the
        # way to attach sync metadata to this existing tree.
        Assert-True `
            ($dirtyRefusal.Message -match [regex]::Escape('-InitMode Adopt')) `
            "a refusal without a BASE should also offer Init -InitMode Adopt"
        Assert-True `
            ($dirtyRefusal.Message -match '(?i)\bnew or empty\b') `
            "the refusal should state the new-or-empty directory rule"
    }

    # Refusing must not delete, move, or rewrite the user's existing file, and
    # must not plant sync state either.
    $dirtyFileStillThere = Join-Path $dirtyDir "src\app.ts"
    Assert-True `
        (Test-Path -LiteralPath $dirtyFileStillThere) `
        "a refusal must leave existing files untouched"
    Assert-Equal `
        ([byte[]](0x61)) `
        ([System.IO.File]::ReadAllBytes($dirtyFileStillThere)) `
        "a refusal must not rewrite existing file bytes"
    Assert-True `
        (-not (Test-Path -LiteralPath (Join-Path $dirtyDir '.rundot-sync'))) `
        "a refusal must not plant .rundot-sync in the refused directory"

    # Several offenders are listed deterministically, independent of
    # enumeration order.
    $manyDir = New-ExportTestDirectory "many"
    New-Item -ItemType Directory -Path (Join-Path $manyDir "src") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $manyDir "public") -Force | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $manyDir "notes.md"), [byte[]](0x61))
    Assert-Equal `
        @('notes.md', 'public', 'src') `
        @(Get-RundotExportUnexpectedEntries -OutDir $manyDir) `
        "multiple offenders should be listed in a stable sorted order"

    # ----------------------------------------------------------------------
    # An already-initialized workspace is told to Pull, not to Adopt
    #
    # Init -InitMode Adopt refuses a tree that already has a BASE, so offering
    # it here would be wrong advice.
    # ----------------------------------------------------------------------

    $initializedDir = New-ExportTestDirectory "initialized"
    New-Item -ItemType Directory -Path (Join-Path $initializedDir ".rundot-sync") -Force | Out-Null
    [System.IO.File]::WriteAllBytes(
        (Join-Path $initializedDir ".rundot-sync\base-manifest.json"),
        [byte[]](0x7B, 0x7D)
    )
    Assert-True `
        (Test-RundotExportDestinationHasBase -OutDir $initializedDir) `
        "an initialized workspace should be detected by its BASE manifest"

    $initializedRefusal = Get-ExportTestRefusal -OutDir $initializedDir
    Assert-True ($null -ne $initializedRefusal) "an initialized workspace must refuse a raw export"
    if ($null -ne $initializedRefusal) {
        Assert-True `
            ($initializedRefusal.Message -match [regex]::Escape('-Command Pull')) `
            "an initialized workspace should be directed to -Command Pull"
        Assert-True `
            ($initializedRefusal.Message -notmatch [regex]::Escape('-InitMode Adopt')) `
            "an initialized workspace must not be told to Adopt, which would refuse"
    }

    # A .rundot-sync with no BASE is not initialized yet.
    Assert-True `
        (-not (Test-RundotExportDestinationHasBase -OutDir $syncDir)) `
        "a .rundot-sync without a BASE manifest is not initialized"

    # ----------------------------------------------------------------------
    # Export does not consult the default ignore set
    #
    # Option B is "new or empty directories", and every ignore exception would
    # widen the destructive surface. Junk that sync would ignore is still an
    # entry the exporter would overwrite, so it must refuse.
    # ----------------------------------------------------------------------

    Assert-True `
        (Test-IgnoredSyncPath -CanonicalPath 'Thumbs.db') `
        "Thumbs.db is in the default ignore set"

    $junkDir = New-ExportTestDirectory "junk"
    [System.IO.File]::WriteAllBytes((Join-Path $junkDir "Thumbs.db"), [byte[]](0x61))
    Assert-Equal `
        @('Thumbs.db') `
        @(Get-RundotExportUnexpectedEntries -OutDir $junkDir) `
        "export must not apply the sync ignore set to its destination"

    # ----------------------------------------------------------------------
    # Destination shape
    # ----------------------------------------------------------------------

    # A destination that is a file cannot be an export root.
    $fileAsOutDir = Join-Path $exportTestRoot "outdir-is-a-file"
    [System.IO.File]::WriteAllBytes($fileAsOutDir, [byte[]](0x61))
    $fileRefusal = Get-ExportTestRefusal -OutDir $fileAsOutDir
    Assert-True ($null -ne $fileRefusal) "an -OutDir that is a file must refuse"
    if ($null -ne $fileRefusal) {
        Assert-True `
            ($fileRefusal.Message -match '(?i)not a folder') `
            "the file-as-destination refusal should say it is not a folder"
    }

    # A relative destination is resolved and created, since the CLI passes what
    # the user typed.
    $relativeName = "rundot-relative-export-" + [Guid]::NewGuid().ToString("N")
    $relativeFull = Join-Path (Get-Location).Path $relativeName
    try {
        Assert-RundotExportDestination -OutDir $relativeName
        Assert-True `
            (Test-Path -LiteralPath $relativeFull -PathType Container) `
            "a relative export destination should be created at the resolved path"
    }
    finally {
        if (Test-Path -LiteralPath $relativeFull) {
            Remove-Item -LiteralPath $relativeFull -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # ----------------------------------------------------------------------
    # CLI wiring
    #
    # The gate must run before authentication, so a refused export never asks
    # for a token and never touches the network.
    # ----------------------------------------------------------------------

    $exportCliPath = Join-Path $repoRoot "game-studio-export.ps1"
    Assert-True (Test-Path -LiteralPath $exportCliPath) "game-studio-export.ps1 must exist"

    if (Test-Path -LiteralPath $exportCliPath) {
        $exportCliSource = [System.IO.File]::ReadAllText($exportCliPath)

        Assert-True `
            ($exportCliSource -match [regex]::Escape('lib\Export.ps1')) `
            "the exporter should load lib/Export.ps1"

        $gateIndex = $exportCliSource.IndexOf('Assert-RundotExportDestination')
        $authIndex = $exportCliSource.IndexOf('Get-RundotAccessToken')

        Assert-True ($gateIndex -ge 0) "the exporter should call Assert-RundotExportDestination"
        Assert-True ($authIndex -ge 0) "the exporter should still call Get-RundotAccessToken"
        Assert-True `
            ($gateIndex -lt $authIndex) `
            "the destination gate must run before authentication"

        # Option B: no force flag may turn the refusal into a silent overwrite.
        Assert-True `
            ($exportCliSource -notmatch 'ForceExport') `
            "the exporter must not grow a force-export override"

        # The existing path-safety checks stay.
        Assert-True `
            ($exportCliSource -match [regex]::Escape('Assert-SafeSyncPathSet')) `
            "the exporter should still validate the remote path set"
        Assert-True `
            ($exportCliSource -match [regex]::Escape('Assert-SyncPathRepresentable')) `
            "the exporter should still check that every remote path is representable"
        Assert-True `
            ($exportCliSource -match [regex]::Escape('Assert-LocalWorkspaceTreeSafe')) `
            "the exporter should still check the destination tree for reparse points"
    }
}
finally {
    if (Test-Path -LiteralPath $exportTestRoot) {
        Remove-Item -LiteralPath $exportTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
