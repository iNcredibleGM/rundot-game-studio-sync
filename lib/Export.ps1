# Exporter destination gate (Option B).
#
# game-studio-export.ps1 is a raw dump into a new or empty directory. It is
# NOT a refresh command: pointing it at an initialized workspace or an
# existing tree would overwrite real work with whatever Studio currently
# holds, silently, so the exporter refuses and points at the sync CLI instead.
#
# This gate is deliberately stricter than Init's destination check:
#
#   - Init tolerates a leftover .rundot-sync/ so a re-run after a failed
#     attempt needs no manual cleanup. Export must refuse it: a .rundot-sync
#     means this directory is a sync workspace, and a raw re-dump over one is
#     exactly the destructive "export to refresh" workflow this removes.
#   - Init consults the default ignore set when scanning for unsafe paths.
#     Export must not: every ignore exception widens the set of existing files
#     the exporter would overwrite, so junk that sync would ignore is still an
#     entry worth refusing over.
#
# Callers must load Paths.ps1 before this file.

function Get-RundotExportAllowedRootMetadata {
    # The only top-level entries an otherwise-empty destination may already
    # contain. These are repository metadata rather than project content, so
    # they are not files the export would replace.
    return @('.git', '.gitignore')
}

function Test-RundotExportDestinationHasBase {
    param(
        [Parameter(Mandatory)]
        [string]$OutDir
    )

    # A .rundot-sync without a BASE is a workspace whose first run never
    # completed, so it is not initialized yet and Init can still adopt it.
    $basePath = Join-Path $OutDir ".rundot-sync\base-manifest.json"
    return (Test-Path -LiteralPath $basePath -PathType Leaf)
}

function Get-RundotExportUnexpectedEntries {
    param(
        [Parameter(Mandatory)]
        [string]$OutDir
    )

    $allowed = Get-RundotExportAllowedRootMetadata
    $unexpected = New-Object 'System.Collections.Generic.List[string]'

    if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) {
        return $unexpected.ToArray()
    }

    foreach ($item in @(Get-ChildItem -LiteralPath $OutDir -Force)) {
        $name = $item.Name
        $isAllowed = $false

        foreach ($allowedName in $allowed) {
            if ([string]::Equals($name, $allowedName, [System.StringComparison]::OrdinalIgnoreCase)) {
                $isAllowed = $true
                break
            }
        }

        if (-not $isAllowed) {
            $unexpected.Add($name)
        }
    }

    return @($unexpected | Sort-Object)
}

function Get-RundotExportDestinationRefusalMessage {
    param(
        [Parameter(Mandatory)]
        [string]$OutDir,

        [Parameter(Mandatory)]
        [string[]]$Unexpected
    )

    $listed = ($Unexpected | ForEach-Object { "  $_" }) -join "`n"

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add("game-studio-export.ps1 is a raw exporter and only writes into a new or empty directory.")
    $lines.Add("")
    $lines.Add("This destination already contains files that are not .git or .gitignore:")
    $lines.Add("  $OutDir")
    $lines.Add("")
    $lines.Add($listed.TrimEnd())
    $lines.Add("")
    $lines.Add("Refusing so nothing already on disk is overwritten. Export is not a way to refresh a workspace.")
    $lines.Add("")

    if (Test-RundotExportDestinationHasBase -OutDir $OutDir) {
        $lines.Add("This workspace is initialized. Apply remote-only changes with:")
        $lines.Add("")
        $lines.Add("  .\game-studio-sync.ps1 -ProjectId <id> -LocalDir `"$OutDir`" -Command Pull")
    }
    else {
        $lines.Add("To sync this tree with Studio, initialize a workspace here, then pull:")
        $lines.Add("")
        $lines.Add("  .\game-studio-sync.ps1 -ProjectId <id> -LocalDir `"$OutDir`" -Command Init -InitMode Adopt")
        $lines.Add("  .\game-studio-sync.ps1 -ProjectId <id> -LocalDir `"$OutDir`" -Command Pull")
        $lines.Add("")
        $lines.Add("Init -InitMode Adopt records only paths that already match Studio exactly; it never overwrites your files.")
    }

    $lines.Add("")
    $lines.Add("For a fresh raw copy, point -OutDir at a new or empty directory instead.")

    return ($lines -join "`n")
}

function Assert-RundotExportDestination {
    param(
        [Parameter(Mandatory)]
        [string]$OutDir
    )

    # Resolve relative to the caller's current location, since the CLI accepts
    # whatever the user typed.
    $resolved = [System.IO.Path]::GetFullPath($OutDir)

    if (Test-Path -LiteralPath $resolved -PathType Leaf) {
        throw [System.InvalidOperationException]::new(
            "Export destination '$resolved' is a file, not a folder."
        )
    }

    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $resolved | Out-Null
    }

    # Reject a redirected destination root before anything is written into it.
    # Writing through a junction would place project files outside the folder
    # the user named.
    $rootInfo = New-Object System.IO.DirectoryInfo $resolved
    if (Test-UnsafeSyncFileAttributes -Attributes $rootInfo.Attributes) {
        Assert-UnsafeSyncPath (
            "Export destination '$resolved' is a reparse point, symlink, or cloud placeholder."
        )
    }

    $unexpected = @(Get-RundotExportUnexpectedEntries -OutDir $resolved)
    if ($unexpected.Count -gt 0) {
        throw [System.InvalidOperationException]::new(
            (Get-RundotExportDestinationRefusalMessage -OutDir $resolved -Unexpected $unexpected)
        )
    }
}
