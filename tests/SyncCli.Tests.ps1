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
    ($syncCliSource -match "ValidateSet\(\s*'Init'\s*,\s*'Plan'\s*,\s*'Status'\s*\)") `
    "the CLI should expose Init, Plan, and Status on a validated -Command"

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
# Safety: no mutation, no leaked secrets
# --------------------------------------------------------------------------

Assert-True `
    ($syncCliSource -notmatch '(?i)upload-url|upload-adopt') `
    "the CLI must not reference Studio upload endpoints"

Assert-True `
    ($syncCliSource -notmatch "ValidateSet\(\s*'Apply'|ValidateSet\(\s*'Push'") `
    "the CLI must not expose Apply or Push in this milestone"

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
