# Local inventory for sync manifests.
# Walks a workspace, skips default ignores, and records one identity per file.
# Callers must load Paths.ps1, Ignore.ps1, Hashing.ps1, and Progress.ps1 first.

function Add-LocalManifestDirectory {
    param(
        [System.IO.DirectoryInfo]$Directory,
        [string]$WorkspaceRoot,
        [string]$RelativePath,
        [System.Collections.IDictionary]$Files,

        [AllowNull()]
        $ProgressState = $null
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
                -Files $Files `
                -ProgressState $ProgressState
            continue
        }

        $canonical = ConvertTo-CanonicalSyncPathFromLocal `
            -WorkspaceRoot $WorkspaceRoot `
            -FullPath $item.FullName
        $Files[$canonical] = Get-LocalFileIdentity -LiteralPath $item.FullName

        if ($null -ne $ProgressState) {
            Write-RundotSyncProgress -State $ProgressState -Index $Files.Count -Path $canonical
        }
    }
}

function Get-LocalManifest {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [switch]$ShowProgress
    )

    Assert-LocalWorkspaceTreeSafe -WorkspaceRoot $WorkspaceRoot

    $root = Get-NormalizedWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $files = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)

    $progressState = $null
    if ($ShowProgress) {
        $progressState = New-RundotSyncProgressState -Activity 'Hashing local files'
        Write-RundotSyncProgress `
            -State $progressState `
            -Index 0 `
            -Path $root `
            -Force
    }

    Add-LocalManifestDirectory `
        -Directory (New-Object System.IO.DirectoryInfo $root) `
        -WorkspaceRoot $root `
        -RelativePath '' `
        -Files $files `
        -ProgressState $progressState

    if ($files.Count -gt 0) {
        Assert-SafeSyncPathSet -Paths @($files.Keys)
    }

    if ($ShowProgress) {
        Complete-RundotSyncProgress `
            -State $progressState `
            -Text ("Hashed {0} local file(s)." -f $files.Count)
    }

    return $files
}
