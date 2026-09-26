# game-studio-sync.ps1 surface and safety contracts.
# Source-text assertions only: the CLI authenticates against Studio, so there
# is no network-free path to invoking it here.
#
# Do not require Pester.

$repoRoot = Split-Path $PSScriptRoot -Parent
$syncCliPath = Join-Path $repoRoot "game-studio-sync.ps1"

Assert-True (Test-Path -LiteralPath $syncCliPath) "game-studio-sync.ps1 must exist"

$syncCliSource = ""
if (Test-Path -LiteralPath $syncCliPath) {
    $syncCliSource = [System.IO.File]::ReadAllText($syncCliPath)
}


# --------------------------------------------------------------------------
# Public surface: Init, Plan, Status and the two allowed Init modes
# --------------------------------------------------------------------------

Assert-True `
    ($syncCliSource -match "ValidateSet\(\s*'Init'\s*,\s*'Plan'\s*,\s*'Status'\s*,\s*'Pull'\s*,\s*'Push'\s*\)") `
    "the CLI should expose Init, Plan, Status, Pull, and Push on a validated -Command"

Assert-True `
    ($syncCliSource -match "ValidateSet\(\s*'FromRemote'\s*,\s*'Adopt'\s*\)") `
    "the CLI should expose only the FromRemote and Adopt Init modes"

Assert-True `
    ($syncCliSource -match '\$InitMode') `
    "the CLI should accept an -InitMode parameter"

Assert-True `
    ($syncCliSource -match '\$FromRemote') `
    "the CLI should accept -FromRemote as the documented alias"

Assert-True `
    ($syncCliSource -match '\$AllowNoBase') `
    "the CLI should accept the -AllowNoBase escape hatch"

# Explicitly out of scope for this milestone.
Assert-True `
    ($syncCliSource -notmatch 'FromLocal') `
    "the CLI must not expose an unapproved FromLocal Init mode"

Assert-True `
    ($syncCliSource -notmatch 'AcceptRemoteAsBase') `
    "the CLI must not expose AcceptRemoteAsBase"

Assert-True `
    ($syncCliSource -match '(?m)^\s*\[Parameter\(Mandatory\s*=\s*\$true\)\]') `
    "the CLI should require its core parameters rather than guessing them"


# --------------------------------------------------------------------------
# Wiring: the CLI composes the tested libraries instead of reimplementing
# --------------------------------------------------------------------------

foreach ($requiredFunction in @(
    'Resolve-RundotSyncPlanBase',
    'Initialize-RundotSyncFromRemote',
    'Initialize-RundotSyncByAdopt',
    'Assert-RundotSyncInitDestination',
    'Assert-RundotSyncAdoptDestination',
    'Get-RundotAccessToken'
)) {
    Assert-True `
        ($syncCliSource -match [regex]::Escape($requiredFunction)) `
        "the CLI should call $requiredFunction rather than duplicating its logic"
}

foreach ($requiredLibrary in @(
    'Paths.ps1',
    'Ignore.ps1',
    'Hashing.ps1',
    'Workspace.ps1',
    'Manifest.ps1',
    'RemoteApi.ps1',
    'Auth.ps1',
    'Snapshot.ps1',
    'Classifier.ps1',
    'Plan.ps1',
    'Init.ps1'
)) {
    Assert-True `
        ($syncCliSource -match [regex]::Escape($requiredLibrary)) `
        "the CLI should load lib\$requiredLibrary"
}

# The gate must run before authentication so a missing BASE never prompts
# for a token.
#
# Plan and Init each authenticate, so ordering is asserted inside the
# function that does the work rather than across the whole file: a file-wide
# "first occurrence" comparison would silently pass or fail depending on
# which function happens to be defined first.
function Get-SyncCliFunctionText {
    param(
        [string]$Source,
        [string]$FunctionName
    )

    $start = $Source.IndexOf("function $FunctionName ")
    if ($start -lt 0) {
        return ""
    }

    $next = $Source.IndexOf("`nfunction ", $start + 1)
    if ($next -lt 0) {
        return $Source.Substring($start)
    }

    return $Source.Substring($start, $next - $start)
}

$planFunctionText = Get-SyncCliFunctionText -Source $syncCliSource -FunctionName 'Invoke-SyncPlanCommand'
Assert-True `
    (-not [string]::IsNullOrEmpty($planFunctionText)) `
    "the CLI must define Invoke-SyncPlanCommand for Plan and Status"

$planGateIndex = $planFunctionText.IndexOf('Resolve-RundotSyncPlanBase')
$planAuthIndex = $planFunctionText.IndexOf('Get-RundotAccessToken')
Assert-True `
    ($planGateIndex -ge 0 -and $planAuthIndex -ge 0 -and $planGateIndex -lt $planAuthIndex) `
    "the no-BASE gate should be consulted before requesting Studio authentication"

# A destination that cannot succeed must be refused before authenticating too,
# or a doomed run still prompts for credentials (and can block on a paste).
$initFunctionText = Get-SyncCliFunctionText -Source $syncCliSource -FunctionName 'Invoke-SyncInit'
Assert-True `
    (-not [string]::IsNullOrEmpty($initFunctionText)) `
    "the CLI must define Invoke-SyncInit"

$preflightIndex = $initFunctionText.IndexOf('Assert-RundotSyncInitDestination')
$initAuthIndex = $initFunctionText.IndexOf('Get-RundotAccessToken')
Assert-True `
    ($preflightIndex -ge 0 -and $initAuthIndex -ge 0 -and $preflightIndex -lt $initAuthIndex) `
    "the Init destination pre-flight should run before requesting authentication"


# --------------------------------------------------------------------------
# Plan / Status wiring: the CLI composes the dry-run engine
# --------------------------------------------------------------------------

foreach ($planFunction in @(
    'New-RundotSyncPlanAnalysis',
    'Get-LocalManifest',
    'Get-StableRemoteSnapshot',
    'Clear-RemoteSnapshotTemp'
)) {
    Assert-True `
        ($planFunctionText -match [regex]::Escape($planFunction)) `
        "Invoke-SyncPlanCommand should call $planFunction"
}

# The CLI composes at the analysis boundary: classification and diagnostics
# are the engine's job, so their call sites must live in lib/Plan.ps1 and not
# be reimplemented here.
Assert-True `
    ($planFunctionText -match [regex]::Escape('$analysis.Report')) `
    "Plan and Status must print the engine report, so the dry-run lines always appear"

# The engine owns persistence; the CLI only decides whether to ask for it.
# Status must never persist, so the flag is gated on the command.
Assert-True `
    ($planFunctionText -match [regex]::Escape('-PersistArtifact:($SyncCommand -eq ''Plan'')')) `
    "only Plan may ask the engine to persist the plan artifact"

Assert-True `
    ($planFunctionText -match [regex]::Escape('-IncludeUnchanged:$IncludeUnchanged')) `
    "the CLI should pass the -Verbose-derived flag into the engine"

Assert-True `
    ($planFunctionText -match '\[bool\]\$AllowWithoutBase') `
    "Invoke-SyncPlanCommand should accept the -AllowNoBase decision"

# The dispatch forwards the escape hatch into the gate; the call site is in
# the dispatch block rather than the function body.
Assert-True `
    ($syncCliSource -match [regex]::Escape('-AllowWithoutBase ([bool]$AllowNoBase)')) `
    "the dispatch should pass the -AllowNoBase escape hatch into the gate"

# A plan is read-only: it must not write BASE or reach a Studio write route.
Assert-True `
    ($planFunctionText -notmatch 'Save-BaseManifest') `
    "Plan and Status must never write BASE"
Assert-True `
    ($planFunctionText -notmatch '(?i)upload-url|upload-adopt') `
    "Plan and Status must never reference a Studio upload endpoint"

# Ordering: LOCAL + REMOTE are captured before they are classified, and the
# staging tree is cleared only after the analysis is built.
$planLocalIndex = $planFunctionText.IndexOf('Get-LocalManifest')
$planSnapshotIndex = $planFunctionText.IndexOf('Get-StableRemoteSnapshot')
$planAnalysisIndex = $planFunctionText.IndexOf('New-RundotSyncPlanAnalysis')
$planCleanupIndex = $planFunctionText.IndexOf('Clear-RemoteSnapshotTemp')

Assert-True `
    ($planLocalIndex -ge 0 -and $planAnalysisIndex -ge 0 -and $planLocalIndex -lt $planAnalysisIndex) `
    "the LOCAL manifest should be captured before classification"
Assert-True `
    ($planSnapshotIndex -ge 0 -and $planAnalysisIndex -ge 0 -and $planSnapshotIndex -lt $planAnalysisIndex) `
    "the REMOTE snapshot should be captured before classification"
Assert-True `
    ($planCleanupIndex -ge 0 -and $planAnalysisIndex -ge 0 -and $planCleanupIndex -gt $planAnalysisIndex) `
    "snapshot staging should be cleared only after the analysis is built"


# --------------------------------------------------------------------------
# -Verbose: read from bound parameters, never re-declared
#
# Declaring [switch]$Verbose in the param block is a startup error, because it
# collides with the common parameter of the same name. The switch is
# therefore read from $PSBoundParameters.
# --------------------------------------------------------------------------

$paramBlockEnd = $syncCliSource.IndexOf("`n)")
$syncCliParamBlock = $syncCliSource
if ($paramBlockEnd -ge 0) {
    $syncCliParamBlock = $syncCliSource.Substring(0, $paramBlockEnd)
}

Assert-True `
    ($syncCliParamBlock -notmatch '\$Verbose') `
    "the CLI must not declare -Verbose, which collides with the common parameter"
Assert-True `
    ($syncCliParamBlock -notmatch '(?i)\[switch\]\s*\$(Force|Overwrite|Write|Push|Apply|Upload)\b') `
    "the CLI must not expose any remote-write switch"
Assert-True `
    ($syncCliParamBlock -notmatch '(?i)\$PersistArtifact|\$NoPersist|\$DryRun') `
    "the CLI must not expose an artifact-persistence switch"

$verboseHelperText = Get-SyncCliFunctionText `
    -Source $syncCliSource `
    -FunctionName 'Get-RundotSyncVerboseRequested'
Assert-True `
    (-not [string]::IsNullOrEmpty($verboseHelperText)) `
    "the CLI must define Get-RundotSyncVerboseRequested to read -Verbose safely"
Assert-True `
    ($verboseHelperText -match [regex]::Escape("ContainsKey('Verbose')")) `
    "the -Verbose helper must read the bound Verbose switch rather than a local variable"
Assert-True `
    ($syncCliSource -match [regex]::Escape('Get-RundotSyncVerboseRequested -BoundParameters $PSBoundParameters')) `
    "the dispatch should pass the bound parameters into the -Verbose helper"


# --------------------------------------------------------------------------
# Safety: no mutation, no leaked secrets
# --------------------------------------------------------------------------

Assert-True `
    ($syncCliSource -notmatch '(?i)upload-url|upload-adopt') `
    "the CLI must not reference Studio upload endpoints"

Assert-True `
    ($syncCliSource -notmatch "ValidateSet\(\s*'Apply'") `
    "the CLI must not expose Apply in this milestone"

Assert-True `
    ($syncCliSource -notmatch '(?i)Authorization\s*=\s*''Bearer\s+[A-Za-z0-9]') `
    "the CLI must not hardcode a bearer token"

Assert-True `
    ($syncCliSource -match 'Authorization\s*=\s*\$null') `
    "the CLI should clear the Authorization header before exiting"

Assert-True `
    ($syncCliSource -match '(?m)^\s*exit\s') `
    "the CLI should exit with an explicit code"

Assert-True `
    ($syncCliSource -notmatch '(?i)Write-(Host|Warning|Output).*\$Token\b') `
    "the CLI must not print the access token"

# Every dry-run report ends with the three closing lines, and the engine owns
# that text so Plan and Status cannot drift apart.
$planLibrarySource = [System.IO.File]::ReadAllText(
    (Join-Path $repoRoot "lib\Plan.ps1")
)
foreach ($closingLine in @(
    'Dry run only. No remote files were modified.'
    'This plan is a point-in-time observation, not permission to write.'
    'WARNING: This tool uses unofficial remote API routes that may change.'
)) {
    Assert-True `
        ($planLibrarySource -match [regex]::Escape($closingLine)) `
        "the plan engine must emit the dry-run closing line: $closingLine"
}


# --------------------------------------------------------------------------
# Pull wiring: the mutation path stays explicit and confirmed
# --------------------------------------------------------------------------

Assert-True `
    ($syncCliSource -match '\$ForcePull') `
    "the CLI should accept -ForcePull"

Assert-True `
    ($syncCliSource -match '\$ConfirmOverwrite') `
    "the CLI should pass an overwrite-confirmation callback into the engine"

foreach ($requiredPullFunction in @(
    'Invoke-RundotSyncPull'
)) {
    Assert-True `
        ($syncCliSource -match [regex]::Escape($requiredPullFunction)) `
        "the CLI should call $requiredPullFunction rather than duplicating its logic"
}

foreach ($requiredPullLibrary in @(
    'Backup.ps1',
    'Journal.ps1',
    'Pull.ps1'
)) {
    Assert-True `
        ($syncCliSource -match [regex]::Escape($requiredPullLibrary)) `
        "the CLI should load lib\$requiredPullLibrary"
}

$pullFunctionText = Get-SyncCliFunctionText -Source $syncCliSource -FunctionName 'Invoke-SyncPullCommand'
Assert-True `
    (-not [string]::IsNullOrEmpty($pullFunctionText)) `
    "the CLI must define Invoke-SyncPullCommand for Pull"

# The BASE gate must run before authentication for Pull too.
$pullGateIndex = $pullFunctionText.IndexOf('Resolve-RundotSyncPlanBase')
$pullAuthIndex = $pullFunctionText.IndexOf('Get-RundotAccessToken')
Assert-True `
    ($pullGateIndex -ge 0 -and $pullAuthIndex -ge 0 -and $pullGateIndex -lt $pullAuthIndex) `
    "the Pull no-BASE gate should be consulted before requesting Studio authentication"

# Pull composes the tested engine rather than reimplementing it.
foreach ($pullFunction in @(
    'Get-LocalManifest',
    'Get-StableRemoteSnapshot',
    'Invoke-RundotSyncPull',
    'Clear-RemoteSnapshotTemp'
)) {
    Assert-True `
        ($pullFunctionText -match [regex]::Escape($pullFunction)) `
        "Invoke-SyncPullCommand should call $pullFunction"
}

# The CLI prompts and forwards the decision; the engine owns the write.
Assert-True `
    ($pullFunctionText -match [regex]::Escape('-ConfirmOverwrite')) `
    "the CLI should hand the overwrite prompt to the engine"
Assert-True `
    ($pullFunctionText -match [regex]::Escape('-Force')) `
    "the CLI should forward -ForcePull into the engine"

# Pull mutates LOCAL only and must never reach a Studio write.
Assert-True `
    ($pullFunctionText -notmatch '(?i)upload-url|upload-adopt') `
    "Pull must never reference a Studio upload endpoint"
Assert-True `
    ($syncCliSource -notmatch '(?i)Authorization\s*=\s*''Bearer\s+[A-Za-z0-9]') `
    "the CLI must not hardcode a bearer token for Pull"

# Pull must not expose -SupportsShouldProcess/-Confirm/-WhatIf in this
# milestone: confirmation is an explicit prompt plus -ForcePull.
Assert-True `
    ($syncCliParamBlock -notmatch '(?i)SupportsShouldProcess|\[switch\]\s*\$(Confirm|WhatIf)\b') `
    "Pull confirmation must be an explicit prompt, not -SupportsShouldProcess"

# A mutating command must still clear the Authorization header before exit.
$pullAuthClearCount = ([regex]::Matches($pullFunctionText, 'Authorization\s*=\s*\$null')).Count
Assert-True `
    ($pullAuthClearCount -ge 1) `
    "Invoke-SyncPullCommand should clear the Authorization header before exiting"

# -AllowNoBase is a Plan/Status escape hatch. Pull has no untrusted mode.
Assert-True `
    ($syncCliSource -match [regex]::Escape('-AllowNoBase applies to Plan and Status')) `
    "the CLI should refuse -AllowNoBase outside Plan and Status"

# The dispatch must route Pull to its own command function.
Assert-True `
    ($syncCliSource -match [regex]::Escape('Invoke-SyncPullCommand')) `
    "the dispatch should route Pull to Invoke-SyncPullCommand"


# --------------------------------------------------------------------------
# Push wiring: remote writes stay explicit and confirmed
# --------------------------------------------------------------------------

Assert-True `
    ($syncCliSource -match '\$ConfirmPush') `
    "the CLI should accept -ConfirmPush"
Assert-True `
    ($syncCliSource -match '\$ForcePush') `
    "the CLI should accept -ForcePush"

foreach ($requiredPushFunction in @(
    'Invoke-RundotSyncPush',
    'Read-PlanArtifact'
)) {
    Assert-True `
        ($syncCliSource -match [regex]::Escape($requiredPushFunction)) `
        "the CLI should call $requiredPushFunction rather than duplicating its logic"
}

foreach ($requiredPushLibrary in @(
    'RemoteWrite.ps1',
    'Push.ps1'
)) {
    Assert-True `
        ($syncCliSource -match [regex]::Escape($requiredPushLibrary)) `
        "the CLI should load lib\$requiredPushLibrary"
}

$pushFunctionText = Get-SyncCliFunctionText -Source $syncCliSource -FunctionName 'Invoke-SyncPushCommand'
Assert-True `
    (-not [string]::IsNullOrEmpty($pushFunctionText)) `
    "the CLI must define Invoke-SyncPushCommand for Push"

$pushGateIndex = $pushFunctionText.IndexOf('Resolve-RundotSyncPlanBase')
$pushAuthIndex = $pushFunctionText.IndexOf('Get-RundotAccessToken')
Assert-True `
    ($pushGateIndex -ge 0 -and $pushAuthIndex -ge 0 -and $pushGateIndex -lt $pushAuthIndex) `
    "the Push no-BASE gate should be consulted before requesting Studio authentication"

$pushArtifactIndex = $pushFunctionText.IndexOf('Read-PlanArtifact')
Assert-True `
    ($pushArtifactIndex -ge 0 -and $pushArtifactIndex -lt $pushAuthIndex) `
    "Push should read last-plan.json before requesting Studio authentication"

foreach ($pushFunction in @(
    'Get-LocalManifest',
    'Get-StableRemoteSnapshot',
    'Invoke-RundotSyncPush',
    'Clear-RemoteSnapshotTemp'
)) {
    Assert-True `
        ($pushFunctionText -match [regex]::Escape($pushFunction)) `
        "Invoke-SyncPushCommand should call $pushFunction"
}

Assert-True `
    ($pushFunctionText -match [regex]::Escape('-ConfirmOverwrite')) `
    "the CLI should hand the overwrite prompt to the engine"
Assert-True `
    ($pushFunctionText -match [regex]::Escape('-Force')) `
    "the CLI should forward -Force into the engine"
Assert-True `
    ($syncCliSource -match [regex]::Escape('-ForcePush applies to Push only')) `
    "the CLI should refuse -ForcePush outside Push"
Assert-True `
    ($syncCliSource -match [regex]::Escape('[bool]$ForcePush -or [bool]$ConfirmPush')) `
    "the CLI should treat -ConfirmPush as a skip-prompt alias for Push"

# Push must not expose -SupportsShouldProcess/-Confirm/-WhatIf in this
# milestone: confirmation is an explicit prompt plus -ForcePush/-ConfirmPush.
Assert-True `
    ($syncCliParamBlock -notmatch '(?i)SupportsShouldProcess|\[switch\]\s*\$(Confirm|WhatIf)\b') `
    "Push confirmation must be an explicit prompt, not -SupportsShouldProcess"

Assert-True `
    ($pushFunctionText -match [regex]::Escape('Read-RundotSyncPushConfirmation')) `
    "the CLI should define Read-RundotSyncPushConfirmation for Push"
Assert-True `
    ($pushFunctionText -match [regex]::Escape('result.Cancelled')) `
    "the CLI should handle a cancelled Push confirmation"
Assert-True `
    ($pushFunctionText -match 'exit\s+1') `
    "a cancelled Push must exit non-zero"

Assert-True `
    ($pushFunctionText -notmatch '(?i)upload-url|upload-adopt') `
    "Push must never reference a Studio upload-adopt endpoint"

Assert-True `
    ($syncCliSource -match [regex]::Escape('Invoke-SyncPushCommand')) `
    "the dispatch should route Push to Invoke-SyncPushCommand"

$pushAuthClearCount = ([regex]::Matches($pushFunctionText, 'Authorization\s*=\s*\$null')).Count
Assert-True `
    ($pushAuthClearCount -ge 1) `
    "Invoke-SyncPushCommand should clear the Authorization header before exiting"


# --------------------------------------------------------------------------
# Push delete wiring: the documented DELETE route stays explicit and confirmed
# --------------------------------------------------------------------------

foreach ($requiredPushLibrary in @(
    'RemoteDelete.ps1'
    'RemoteUpload.ps1'
    'RemoteMove.ps1'
    'RemoteTextCreate.ps1'
    'RemoteBinaryPlace.ps1'
)) {
    Assert-True `
        ($syncCliSource -match [regex]::Escape($requiredPushLibrary)) `
        "the CLI should load lib\$requiredPushLibrary"
}

Assert-True `
    ($pushFunctionText -match [regex]::Escape('Read-RundotSyncPushBinaryConfirmation')) `
    "the CLI should define Read-RundotSyncPushBinaryConfirmation for Push"
Assert-True `
    ($pushFunctionText -match [regex]::Escape('Read-RundotSyncPushCreateConfirmation')) `
    "the CLI should define Read-RundotSyncPushCreateConfirmation for Push creates"
Assert-True `
    ($pushFunctionText -match [regex]::Escape('-ConfirmBinary')) `
    "Push wiring should pass ConfirmBinary into Invoke-RundotSyncPush"
Assert-True `
    ($pushFunctionText -match [regex]::Escape('-ConfirmCreate')) `
    "the CLI should hand the create prompt to the engine"
Assert-True `
    ($pushFunctionText -match [regex]::Escape('Read-RundotSyncPushDeleteConfirmation')) `
    "the CLI should define Read-RundotSyncPushDeleteConfirmation for Push deletes"
Assert-True `
    ($pushFunctionText -match [regex]::Escape('-ConfirmDelete')) `
    "the CLI should hand the delete prompt to the engine"
Assert-True `
    ($pushFunctionText -match [regex]::Escape('Invoke-RundotSyncPush')) `
    "the Push command should call the engine that owns the delete"

# The delete confirmation must be its own deliberate prompt, not a silent
# extension of the overwrite prompt.
Assert-True `
    ($syncCliSource -match [regex]::Escape('Push will CREATE')) `
    "the create confirmation must say what will be created"
Assert-True `
    ($syncCliSource -match [regex]::Escape('Push will DELETE')) `
    "the delete confirmation must say what will be removed"

# The one file allowed to send DELETE must be the only one.
Assert-True `
    ($syncCliSource -notmatch "\.Method\s*=\s*['`"]DELETE['`"]") `
    "the CLI must not send DELETE itself; lib/RemoteDelete.ps1 owns the route"
Assert-True `
    ($pushFunctionText -notmatch "\.Method\s*=\s*['`"]DELETE['`"]") `
    "Invoke-SyncPushCommand must not send DELETE itself"
