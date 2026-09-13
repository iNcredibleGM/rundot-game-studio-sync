# Streaming SHA-256 and local byte diagnostics for sync identity.
# Behavior is defined by tests/Hashing.Tests.ps1.

function Get-FileSha256Hex {
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath
    )
}

function Get-LocalFileIdentity {
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath
    )
}

function ConvertTo-RemoteKind {
    param(
        [string]$Encoding
    )
}

function Test-UnsupportedKindChange {
    param(
        $LocalKind,
        $RemoteKind
    )
}
