# Default ignore matcher for local sync inventory.
# Behavior is defined by tests/Paths.Tests.ps1. No .rundotignore parser.

function Get-DefaultSyncIgnorePatterns {
    return @()
}

function Test-IgnoredSyncPath {
    param(
        [Parameter(Mandatory)]
        [string]$CanonicalPath
    )

    return $false
}
