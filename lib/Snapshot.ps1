# Torn-read remote snapshot helpers.
# Callers must load Paths.ps1, Hashing.ps1, Workspace.ps1, and RemoteApi.ps1 first.
#
# Fingerprint, list validation, and decode are implemented in a later step.
# Stubs exist so Snapshot.Tests.ps1 can load.

function Assert-RemoteManifestValid {
    param($Manifest)
}

function Get-RemoteManifestFingerprint {
    param($Manifest)
}

function ConvertFrom-RemoteFileContent {
    param($Response)
}
