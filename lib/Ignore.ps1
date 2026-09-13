# Default ignore matcher for local sync inventory.
# No .rundotignore parser. Classifiers must consult Test-IgnoredSyncPath
# before emitting upload or deleteRemoteCandidate.

function Get-DefaultSyncIgnorePatterns {
    return @(
        '.git/',
        '.rundot-sync/',
        'node_modules/',
        'dist/',
        'build/',
        'out/',
        '.vs/',
        '.idea/',
        '.vscode/',
        '.rundot-studio-export/',
        'Thumbs.db',
        'desktop.ini',
        '.DS_Store',
        '*.swp',
        '*~',
        '*.tmp',
        '*.bak'
    )
}

function Get-SyncIgnoreMatchPath {
    param([string]$CanonicalPath)

    $path = $CanonicalPath.Replace('\', '/')

    if ($path.StartsWith('/')) {
        $path = $path.Substring(1)
    }

    while ($path.EndsWith('/') -and $path.Length -gt 0) {
        $path = $path.Substring(0, $path.Length - 1)
    }

    return $path
}

function Test-IgnoredSyncPath {
    param(
        [Parameter(Mandatory)]
        [string]$CanonicalPath
    )

    $path = Get-SyncIgnoreMatchPath -CanonicalPath $CanonicalPath

    if ([string]::IsNullOrEmpty($path)) {
        return $false
    }

    $segments = $path.Split(@('/'), [System.StringSplitOptions]::None)
    $leaf = $segments[$segments.Length - 1]

    foreach ($pattern in Get-DefaultSyncIgnorePatterns) {
        if ($pattern.EndsWith('/')) {
            $directoryName = $pattern.Substring(0, $pattern.Length - 1)
            foreach ($segment in $segments) {
                if ([string]::Equals($segment, $directoryName, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $true
                }
            }

            continue
        }

        if ($pattern.Contains('*')) {
            if ($leaf -like $pattern) {
                return $true
            }

            continue
        }

        if ([string]::Equals($leaf, $pattern, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}
