# Local inventory for sync manifests.
# Walks a workspace, skips default ignores, and records one identity per file.
# Callers must load Paths.ps1, Ignore.ps1, and Hashing.ps1 first.

function Add-LocalManifestDirectory {
    param(
        [System.IO.DirectoryInfo]$Directory,
        [string]$WorkspaceRoot,
        [string]$RelativePath,
        [System.Collections.IDictionary]$Files
    )

    foreach ($item in $Directory.GetFileSystemInfos()) {
        $childRelative = $item.Name
        if ($RelativePath) {
            $childRelative = "$RelativePath/$($item.Name)"
        }

        $isDirectory = (
            ([int]$item.Attributes -band [int][System.IO.FileAttributes]::Directory) -ne 0
        )

        if (
            Test-ShouldSkipLocalScanItem `
                -CanonicalPath $childRelative `
                -Name $item.Name `
                -IsDirectory $isDirectory
        ) {
            continue
        }

        if (Test-UnsafeSyncFileAttributes -Attributes $item.Attributes) {
            Assert-UnsafeSyncPath "Path '$childRelative' is a reparse point, symlink, or cloud placeholder."
        }

        if ($isDirectory) {
            Add-LocalManifestDirectory `
                -Directory $item `
                -WorkspaceRoot $WorkspaceRoot `
                -RelativePath $childRelative `
                -Files $Files
            continue
        }

        $canonical = ConvertTo-CanonicalSyncPathFromLocal `
            -WorkspaceRoot $WorkspaceRoot `
            -FullPath $item.FullName
        $Files[$canonical] = Get-LocalFileIdentity -LiteralPath $item.FullName
    }
}

function Get-LocalManifest {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot
    )

    Assert-LocalWorkspaceTreeSafe -WorkspaceRoot $WorkspaceRoot

    $root = Get-NormalizedWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $files = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)

    Add-LocalManifestDirectory `
        -Directory (New-Object System.IO.DirectoryInfo $root) `
        -WorkspaceRoot $root `
        -RelativePath '' `
        -Files $files

    if ($files.Count -gt 0) {
        Assert-SafeSyncPathSet -Paths @($files.Keys)
    }

    return $files
}
