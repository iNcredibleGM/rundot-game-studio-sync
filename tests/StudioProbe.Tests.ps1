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
    $probeText -match '\$AccessTokenPath'
) "the probe must accept a token file so a token never has to be pasted inline"

# A swallowed switch name is the mistake that cost a debugging session:
# '-ProjectId ABC-Scenario run-binary-all' binds ProjectId='ABC-Scenario', and
# the resulting rejection looks like an auth failure. The probe must catch it.
Assert-True (
    $probeText -match 'swallowed the next switch name'
) "the probe must detect a -ProjectId that swallowed the next switch name"

Assert-True (
    $probeText -match '\$probeParameterNames'
) "the swallowed-switch check must cover this script's own parameter names"

# The probe must never fall through to an interactive token prompt.
Assert-True (
    $probeText -notmatch 'Get-RundotAccessToken'
) "the probe must not call the shared helper that can prompt for a token"

Assert-True (
    $probeText -match 'This probe deliberately does not prompt'
) "the probe must state that it refuses to prompt for a token"

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

# Every created file must carry the per-run stamp, or cleanup silently misses
# it. An unstamped name (a bare random Guid) is invisible to the run filter,
# which is how 13 files survived a cleanup that reported success.
Assert-True (
    $probeText -match 'function Get-ProbeProbeOwnedPaths'
) "the probe must have a single definition of what it owns"

Assert-Equal 0 ([regex]::Matches(
    $probeText,
    "Guid\]::NewGuid\(\)\.ToString\('N'\)\.Substring"
).Count) "probe filenames must use the run stamp, not an ad-hoc random Guid"

Assert-True (
    $probeText -match '\$script:ProbeRunStamp = '
) "the probe must fix one run stamp per process"

Assert-True (
    $probeText -match '\$script:ProbeNamePrefix'
) "probe filenames must be built from the run-stamped prefix"

Assert-True (
    $probeText -match "\`$script:ProbeDir = '/sync-probe'"
) "the probe-owned prefix must be /sync-probe"

# The ownership test must compare on a path boundary. A plain StartsWith would
# treat /sync-probe-other/x.txt as owned and let a destructive case escape.
Assert-True (
    $probeText -match "\`$owned \+ '/'"
) "probe path ownership must compare on a segment boundary, not a raw string prefix"

# ---------------------------------------------------------------------------
# #16: DELETE is the one mutation that can destroy a file the probe did not
# create, so the target itself is guarded, not just the write gate.
# ---------------------------------------------------------------------------

Assert-True (
    $probeText -match '(?m)^function Assert-ProbeDeleteTarget\b'
) "every DELETE must route through Assert-ProbeDeleteTarget"

Assert-True (
    $probeText -match 'Refusing to DELETE a path the probe does not own'
) "the delete guard must refuse a path the probe does not own"

# The guard existing is not enough: Invoke-ProbeDeleteFile must actually call
# it, or a future edit could bypass the check while leaving the function in
# place. Match the call inside that function's body.
$deleteHelperIndex = $probeText.IndexOf('function Invoke-ProbeDeleteFile')
$deleteGuardCallIndex = if ($deleteHelperIndex -ge 0) {
    $probeText.IndexOf('Assert-ProbeDeleteTarget -Path $Path -Case $Case', $deleteHelperIndex)
}
else { -1 }

Assert-True (
    $deleteGuardCallIndex -gt $deleteHelperIndex
) "Invoke-ProbeDeleteFile must call Assert-ProbeDeleteTarget before it sends"

# The delete helper must also keep the list-absence proof: a status alone is
# never evidence that a file is gone.
Assert-True (
    $probeText -match 'StillListed'
) "a DELETE must be proved by list absence, not by its status"

# A bare directory such as /uploads must never be an eligible delete target:
# binary uploads flatten into /uploads, so a directory DELETE there could
# destroy real project files.
Assert-True (
    $probeText -match 'a bare directory like /uploads is never eligible'
) "the delete guard must state that a bare directory is never eligible"

# The rename capture is a copied fetch, which carries an Authorization header.
# It must be redacted rather than recorded.
Assert-True (
    $probeText -match "(?i)authorization"
) "the rename DevTools capture must name the Authorization header it redacts"

Assert-True (
    $probeText -match [regex]::Escape('$1$2<redacted>')
) "the rename DevTools capture must replace a credential value with a placeholder"

# The capture exists to name the real route, so the method and its URL must
# both be extracted. Matching on "method" alone records that a request happened
# without recording where it went, which is exactly the bug this pins.
Assert-True (
    $probeText -match 'captureRoutes'
) "rename-devtools-apply must record the captured method/URL route pairs"

# A blanket https?:// match picks up the "referrer" line, which sits between
# the fetch URL and the method, so the recorded route would be
# "https://run.world/" instead of the real endpoint. Rather than assert on the
# probe's source text (which is fragile), this replicates the extractor's two
# patterns against a real copied-fetch snippet and checks it picks the endpoint,
# not the referrer.
$fetchUrlPattern = 'fetch\(\s*[''"](https?://[^''"]+)[''"]'
$harUrlPattern = '"(?:url|requestUrl)"\s*:\s*"(https?://[^"]+)"'
$sampleCapture = @(
    'await fetch("https://studio.example/api/projects/p1/move", {'
    '    "referrer": "https://run.world/",'
    '    "body": "{}",'
    '    "method": "POST",'
    '    "mode": "cors"'
    '});'
)

$extractedUrl = $null
foreach ($line in $sampleCapture) {
    $fetchMatch = [regex]::Match($line, $fetchUrlPattern)
    if ($fetchMatch.Success) { $extractedUrl = $fetchMatch.Groups[1].Value; continue }
    $harMatch = [regex]::Match($line, $harUrlPattern)
    if ($harMatch.Success) { $extractedUrl = $harMatch.Groups[1].Value; continue }
}

Assert-Equal 'https://studio.example/api/projects/p1/move' $extractedUrl `
    "the capture extractor must read the fetch endpoint, not the referrer line"

Assert-True (
    $probeText -match 'requestUrl'
) "rename-devtools-apply must also read a HAR url field"

Assert-True (
    $probeText -match 'function Invoke-ScenarioRunDeleteRenameAll'
) "the #16 investigation must be runnable with one command"

Assert-True (
    $probeText -match 'function Invoke-ScenarioConditionalDelete'
) "the delete verb's precondition behavior must be probed"

Assert-True (
    $probeText -match 'function Invoke-ScenarioRenameDevToolsApply'
) "the DevTools rename capture must have a recording scenario"

# The rename hand-off runs as two separate processes, so the apply step cannot
# use its own per-process run stamp: it would never match the file the prepare
# run created. It must recover the prepare stamp from the state file, and find
# the renamed file by content hash rather than by name, because the human picks
# the new name and a copy-as-fetch capture does not show the recorded path.
Assert-True (
    $probeText -match 'prepareStamp'
) "rename-devtools-apply must recover the prepare run's stamp instead of using its own"

Assert-True (
    $probeText -match 'renamedPathByHash'
) "rename-devtools-apply must locate the renamed file by content hash"

# The apply step must leave the project clean, but must not weaken the delete
# guard to do it: a path the guard refuses is reported for manual removal.
$applyIndex = $probeText.IndexOf('function Invoke-ScenarioRenameDevToolsApply')
$applyBody = if ($applyIndex -ge 0) { $probeText.Substring($applyIndex) } else { '' }
Assert-True (
    $applyBody -match 'rename-devtools-cleanup'
) "rename-devtools-apply must clean up the hand-off"
Assert-True (
    $applyBody -match 'needsManual'
) "rename-devtools-apply must report a path it could not delete rather than forcing it"

# ---------------------------------------------------------------------------
# Every declared scenario must be dispatchable, and every scenario must also
# appear in the dry-run plan. A scenario that is in the ValidateSet but not the
# dispatch switch fails at run time, after -ConfirmRemoteWrite was supplied,
# which is the worst moment to discover a typo. A scenario missing from the
# plan text would make a dry run under-report what it would send.
# ---------------------------------------------------------------------------

$validateSetMatch = [regex]::Match(
    $probeText,
    '(?s)\[ValidateSet\((.*?)\)\]\s*\[string\]\$Scenario'
)
Assert-True $validateSetMatch.Success "the probe must declare a scenario ValidateSet"

$declaredScenarios = @()
if ($validateSetMatch.Success) {
    $declaredScenarios = @(
        [regex]::Matches($validateSetMatch.Groups[1].Value, "'([a-z0-9-]+)'") |
            ForEach-Object { $_.Groups[1].Value } |
            Sort-Object -Unique
    )
}

Assert-True (
    $declaredScenarios.Count -gt 20
) "the scenario list must include the #16 delete/rename/concurrency scenarios"

$dispatchMatch = [regex]::Match($probeText, '(?s)switch \(\$Scenario\) \{(.*?)\n\}')
Assert-True $dispatchMatch.Success "the probe must have a scenario dispatch switch"

$undispatched = @()
if ($dispatchMatch.Success) {
    foreach ($scenarioName in $declaredScenarios) {
        if ($dispatchMatch.Groups[1].Value -notmatch [regex]::Escape("'$scenarioName'")) {
            $undispatched += $scenarioName
        }
    }
}

Assert-Equal 0 $undispatched.Count (
    "every declared scenario must be dispatched; missing: $($undispatched -join ', ')"
)

# The runner functions are the documented entry points; they must exist and be
# reachable from the dispatch switch.
foreach ($runnerName in @('run-text-all', 'run-binary-all', 'run-delete-rename-all')) {
    Assert-True (
        $dispatchMatch.Success -and
        $dispatchMatch.Groups[1].Value -match [regex]::Escape("'$runnerName'")
    ) "the $runnerName runner must be dispatched"
}

# Every scenario must also have a dry-run plan entry, so a dry run reports what
# it would send. Read-only survey scenarios are the deliberate exception.
$planMatch = [regex]::Match($probeText, '(?s)\$plans = @\{(.*?)\n    \}')
$missingPlans = @()
if ($planMatch.Success) {
    foreach ($scenarioName in $declaredScenarios) {
        if ($scenarioName -like '*-survey') { continue }
        if ($planMatch.Groups[1].Value -notmatch [regex]::Escape("'$scenarioName'")) {
            $missingPlans += $scenarioName
        }
    }
}

Assert-Equal 0 $missingPlans.Count (
    "every mutating scenario must have a dry-run plan entry; missing: $($missingPlans -join ', ')"
)

# A dispatch arm that is present but empty would satisfy the reachability check
# above while sending nothing, so the arm must call a scenario function.
if ($dispatchMatch.Success) {
    $emptyArms = [regex]::Matches(
        $dispatchMatch.Groups[1].Value,
        "(?m)^\s*'[a-z0-9-]+'\s*\{\s*\}"
    )
    Assert-Equal 0 $emptyArms.Count "a probe dispatch arm must call a scenario function, not be empty"
}

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
