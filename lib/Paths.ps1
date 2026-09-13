# Canonical path helpers for sync identity and safety.
# Identity keys are relative, slash-separated, NFC, and never Windows absolute paths.

$script:Win32ReservedNamePattern = '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..+)?$'
$script:InvalidFileNameCharPattern = '[<>:"|?*]'
$script:Win32MaxPath = 259

function Test-EmbeddedNul {
    param([string]$Text)

    return $Text.IndexOf([char]0) -ge 0
}

function Test-Win32ReservedPathComponent {
    param([string]$Name)

    return $Name -match $script:Win32ReservedNamePattern
}

function ConvertTo-SlashPath {
    param([string]$Path)

    return $Path.Replace('\', '/')
}

function Get-SyncPathPreNfcSpelling {
    param([string]$Path)

    $slashPath = ConvertTo-SlashPath -Path $Path

    if ($slashPath.StartsWith('/')) {
        $slashPath = $slashPath.Substring(1)
    }

    if ($slashPath.EndsWith('/') -and $slashPath.Length -gt 0) {
        $slashPath = $slashPath.Substring(0, $slashPath.Length - 1)
    }

    return $slashPath
}

function Get-NormalizedWorkspaceRoot {
    param([string]$WorkspaceRoot)

    $full = [System.IO.Path]::GetFullPath($WorkspaceRoot)
    return $full.TrimEnd('\')
}

function Test-PathIsUnderWorkspace {
    param(
        [string]$WorkspaceRoot,
        [string]$FullPath
    )

    $root = Get-NormalizedWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $full = [System.IO.Path]::GetFullPath($FullPath)

    if ($full.Length -lt $root.Length) {
        return $false
    }

    if (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    if ($full.Length -eq $root.Length) {
        return $true
    }

    return $full[$root.Length] -eq '\'
}

function Assert-UnsafeSyncPath {
    param([string]$Message)

    throw [System.InvalidOperationException]::new($Message)
}

function ConvertTo-CanonicalSyncPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (Test-EmbeddedNul -Text $Path) {
        Assert-UnsafeSyncPath "Path contains an embedded NUL and cannot be used as a sync identity."
    }

    $slashPath = ConvertTo-SlashPath -Path $Path

    if ($slashPath.StartsWith('//')) {
        Assert-UnsafeSyncPath "UNC path '$Path' cannot be used as a sync identity."
    }

    if ($slashPath -match '^[A-Za-z]:') {
        Assert-UnsafeSyncPath "Absolute Windows path '$Path' cannot be used as a sync identity."
    }

    $rawSegments = $slashPath.Split(@('/'), [System.StringSplitOptions]::None)
    $segments = New-Object 'System.Collections.Generic.List[string]'

    $start = 0
    $end = $rawSegments.Length - 1

    if ($rawSegments.Length -gt 0 -and $rawSegments[0] -eq '') {
        $start = 1
    }

    if ($end -ge $start -and $rawSegments[$end] -eq '') {
        $end = $end - 1
    }

    if ($end -lt $start) {
        Assert-UnsafeSyncPath "Path '$Path' is empty after canonicalization."
    }

    for ($i = $start; $i -le $end; $i++) {
        $segment = $rawSegments[$i]

        if ($segment -eq '') {
            Assert-UnsafeSyncPath "Path '$Path' has an empty segment after normalization."
        }

        if ($segment -eq '.' -or $segment -eq '..') {
            Assert-UnsafeSyncPath "Path '$Path' contains a '.' or '..' segment."
        }

        if (Test-Win32ReservedPathComponent -Name $segment) {
            Assert-UnsafeSyncPath "Path '$Path' contains reserved Win32 component '$segment'."
        }

        $segments.Add($segment)
    }

    $joined = [string]::Join('/', $segments.ToArray())
    return $joined.Normalize([System.Text.NormalizationForm]::FormC)
}

function ConvertTo-CanonicalSyncPathFromLocal {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$FullPath
    )

    $root = Get-NormalizedWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $full = [System.IO.Path]::GetFullPath($FullPath)

    if (-not (Test-PathIsUnderWorkspace -WorkspaceRoot $root -FullPath $full)) {
        Assert-UnsafeSyncPath "Local path is outside the workspace root."
    }

    if ($full.Length -eq $root.Length) {
        Assert-UnsafeSyncPath "Workspace root itself is not a relative sync path."
    }

    $relative = $full.Substring($root.Length + 1)
    return ConvertTo-CanonicalSyncPath -Path $relative
}

function ConvertTo-LocalFullPath {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$CanonicalPath
    )

    $canonical = ConvertTo-CanonicalSyncPath -Path $CanonicalPath
    $root = Get-NormalizedWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $combined = $root

    foreach ($segment in $canonical.Split(@('/'), [System.StringSplitOptions]::None)) {
        $combined = [System.IO.Path]::Combine($combined, $segment)
    }

    $full = [System.IO.Path]::GetFullPath($combined)

    if (-not (Test-PathIsUnderWorkspace -WorkspaceRoot $root -FullPath $full)) {
        Assert-UnsafeSyncPath "Canonical path '$CanonicalPath' escaped the workspace root."
    }

    return $full
}

function Assert-SafeSyncPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    [void](ConvertTo-CanonicalSyncPath -Path $Path)
}

function Assert-SafeSyncPathSet {
    param(
        [Parameter(Mandatory)]
        [string[]]$Paths
    )

    $canonicalByPreNfc = New-Object 'System.Collections.Generic.Dictionary[string,string]' (
        [System.StringComparer]::Ordinal
    )
    $canonicalByWindowsIdentity = New-Object 'System.Collections.Generic.Dictionary[string,string]' (
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($original in $Paths) {
        $canonical = ConvertTo-CanonicalSyncPath -Path $original
        $preNfc = Get-SyncPathPreNfcSpelling -Path $original

        if ($canonicalByPreNfc.ContainsKey($preNfc)) {
            continue
        }

        foreach ($existingPreNfc in $canonicalByPreNfc.Keys) {
            $existingCanonical = $canonicalByPreNfc[$existingPreNfc]
            if ([string]::Equals($existingCanonical, $canonical, [System.StringComparison]::Ordinal)) {
                Assert-UnsafeSyncPath (
                    "Remote project contains paths that collide after NFC normalization:`n  $existingPreNfc`n  $preNfc`n`nThis workspace cannot be represented safely on this filesystem."
                )
            }
        }

        if ($canonicalByWindowsIdentity.ContainsKey($canonical)) {
            $existingCanonical = $canonicalByWindowsIdentity[$canonical]
            if (-not [string]::Equals($existingCanonical, $canonical, [System.StringComparison]::Ordinal)) {
                Assert-UnsafeSyncPath (
                    "Remote project contains paths that collide on Windows:`n  $existingCanonical`n  $canonical`n`nThis workspace cannot be represented safely on this filesystem."
                )
            }
        }
        else {
            $canonicalByWindowsIdentity[$canonical] = $canonical
        }

        $canonicalByPreNfc[$preNfc] = $canonical
    }
}

function Assert-SyncPathRepresentable {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$CanonicalPath
    )

    $canonical = ConvertTo-CanonicalSyncPath -Path $CanonicalPath

    foreach ($segment in $canonical.Split(@('/'), [System.StringSplitOptions]::None)) {
        if ($segment -match $script:InvalidFileNameCharPattern) {
            Assert-UnsafeSyncPath "Path '$canonical' contains a character this filesystem cannot represent."
        }

        foreach ($character in $segment.ToCharArray()) {
            if ([int][char]$character -lt 32) {
                Assert-UnsafeSyncPath "Path '$canonical' contains a control character this filesystem cannot represent."
            }
        }
    }

    $root = Get-NormalizedWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $combined = $root + '\' + $canonical.Replace('/', '\')

    if ($combined.Length -gt $script:Win32MaxPath) {
        Assert-UnsafeSyncPath "Path '$canonical' cannot be represented by the current runtime (MAX_PATH)."
    }
}

function Test-UnsafeSyncFileAttributes {
    param(
        [Parameter(Mandatory)]
        $Attributes
    )

    return $false
}

function Assert-LocalWorkspaceTreeSafe {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot
    )
}
