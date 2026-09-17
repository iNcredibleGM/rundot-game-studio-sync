# Guard the opt-in Studio probe introduced for #14/#15.
#
# The probe is the only file in this repository that performs a Studio write.
# It is safe only because it lives outside the set of product files that
# tests/NoRemoteMutation.Tests.ps1 scans, and because nothing in the product
# can reach it. These tests pin both properties.
#
# Static only: no network, no credentials, no Pester.

$repoRoot = Split-Path $PSScriptRoot -Parent
$probePath = Join-Path $repoRoot "tools\StudioProbe.ps1"

Assert-True (Test-Path $probePath) "tools/StudioProbe.ps1 must exist"

if (-not (Test-Path $probePath)) {
    return
}

$probeText = Get-Content -Path $probePath -Raw

# ---------------------------------------------------------------------------
# The probe parses, so a broken salvage cannot land silently.
# ---------------------------------------------------------------------------

$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile(
    $probePath,
    [ref]$null,
    [ref]$parseErrors
)

Assert-Equal 0 @($parseErrors).Count "tools/StudioProbe.ps1 must parse without errors"

# ---------------------------------------------------------------------------
# The write gate exists and is declared.
# ---------------------------------------------------------------------------

Assert-True (
    $probeText -match '\$ConfirmRemoteWrite'
) "the probe must declare a -ConfirmRemoteWrite switch"

Assert-True (
    $probeText -match 'Refusing to mutate Studio without -ConfirmRemoteWrite'
) "the probe must refuse to mutate without -ConfirmRemoteWrite"

Assert-True (
    $probeText -match 'function Assert-ProbeWriteAllowed'
) "every mutating helper must route through Assert-ProbeWriteAllowed"

# The early gate must run before authentication, so a dry run is refused
# without a network call. If this ordering flips, the offline dry-run test
# below would start depending on credentials.
$earlyGateIndex = $probeText.IndexOf("if (-not `$ConfirmRemoteWrite)")
$authIndex = $probeText.IndexOf("function Get-RundotAccessToken")

Assert-True (
    $earlyGateIndex -ge 0
) "the probe must contain an early -ConfirmRemoteWrite gate"

Assert-True (
    $authIndex -lt 0 -or $earlyGateIndex -lt $authIndex
) "the -ConfirmRemoteWrite gate must be evaluated before the access-token flow"

# ---------------------------------------------------------------------------
# The probe cannot be pointed at a real project's whole tree.
# ---------------------------------------------------------------------------

Assert-True (
    $probeText -match 'function Assert-ProbeOwnedPath'
) "the probe must confine destructive cases to a probe-owned path"

Assert-True (
    $probeText -match "\`$script:ProbeDir = '/sync-probe'"
) "the probe-owned prefix must be /sync-probe"

# ---------------------------------------------------------------------------
# The restore discipline that #14 learned the hard way.
# ---------------------------------------------------------------------------

Assert-True (
    $probeText -match 'function Invoke-ProbeRoundTrip'
) "mutating text cases must route through Invoke-ProbeRoundTrip"

Assert-True (
    $probeText -match 'restoredExactly'
) "the round trip must verify a byte-for-byte restore"

Assert-True (
    $probeText -match 'function Read-ProbeResponseBody'
) "responses must be read defensively; an empty write body crashed the #14 v1 restore"

# ---------------------------------------------------------------------------
# Evidence must stay quotable in a public issue.
# ---------------------------------------------------------------------------

Assert-True (
    $probeText -match 'function ConvertTo-RedactedEvidence'
) "evidence must be redacted before it is written"

Assert-True (
    $probeText -match "contentLength"
) "redaction must reduce file content to a length"

# No credential-shaped literals in the probe.
$tokenShaped = [regex]::Matches(
    $probeText,
    'eyJ[A-Za-z0-9_-]{10}|AIza[0-9A-Za-z_-]{10}'
)

Assert-Equal 0 $tokenShaped.Count "tools/StudioProbe.ps1 must not contain token-shaped strings"

# ---------------------------------------------------------------------------
# The probe must not be reachable from product code.
#
# This is the invariant that makes tools/ safe: if a product file ever
# dot-sources the probe, the milestone's mutation ban is defeated without the
# mutation grep noticing.
# ---------------------------------------------------------------------------

$productPaths = @(
    (Join-Path $repoRoot "game-studio-sync.ps1"),
    (Join-Path $repoRoot "game-studio-export.ps1")
)

$libRoot = Join-Path $repoRoot "lib"
if (Test-Path $libRoot) {
    $productPaths += @(
        Get-ChildItem -Path $libRoot -Recurse -Filter "*.ps1" |
            ForEach-Object { $_.FullName }
    )
}

$reachabilityPattern = '(?i)StudioProbe|tools[\\/]StudioProbe|upload-adopt|upload-url'

foreach ($productPath in $productPaths) {
    if (-not (Test-Path $productPath)) {
        continue
    }

    $relative = $productPath.Substring($repoRoot.Length).TrimStart("\", "/")
    $text = Get-Content -Path $productPath -Raw
    $matches = [regex]::Matches($text, $reachabilityPattern)

    Assert-Equal 0 $matches.Count (
        "product file $relative must not reference the probe or Studio upload endpoints"
    )
}
