param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectId,

    [Parameter(Mandatory = $true)]
    [string]$LocalDir,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Init', 'Plan', 'Status')]
    [string]$Command,

    [ValidateSet('FromRemote', 'Adopt')]
    [string]$InitMode,

    # Documented alias for -InitMode FromRemote.
    [switch]$FromRemote,

    # Advanced escape hatch for Plan/Status when BASE is missing.
    [switch]$AllowNoBase
)

$ErrorActionPreference = "Stop"

# ============================================================================
# RUN Game Studio Sync
#
# Read-oriented sync for a Studio project. Neither LOCAL nor REMOTE is
# authoritative: BASE is the last verified shared state, and any ambiguity is
# a conflict rather than a guess.
#
# Init is the only first-run command and the only writer of BASE. Plan and
# Status are read-only: Plan writes a dry-run plan artifact, Status writes
# nothing, and neither touches Studio.
#
#   .\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Init -InitMode FromRemote
#   .\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Init -InitMode Adopt
#   .\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Plan
#   .\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Status
#
# Plan and Status are dry runs. They show what a future Apply would consider,
# but no operation is applicable in this milestone and no plan is permission
# to write. Add -Verbose to also list unchanged paths.
#
# This script is GET-only. It does not create, replace, rename, or delete
# anything on Studio.
# ============================================================================


# ============================================================================
# Configuration
# ============================================================================

$StudioOrigin = "https://venus-studio-prod.series-ai.workers.dev"

$AuthDir = Join-Path $env:APPDATA ".rundot"

$AuthPath = Join-Path $AuthDir "studio-export.auth.json"

$RundotCliSessionPath = Join-Path $env:APPDATA ".rundot\prod.session.json"

$LocalDir = [System.IO.Path]::GetFullPath($LocalDir)

. (Join-Path $PSScriptRoot "lib\Paths.ps1")
. (Join-Path $PSScriptRoot "lib\Ignore.ps1")
. (Join-Path $PSScriptRoot "lib\Hashing.ps1")
. (Join-Path $PSScriptRoot "lib\Workspace.ps1")
. (Join-Path $PSScriptRoot "lib\Manifest.ps1")
. (Join-Path $PSScriptRoot "lib\RemoteApi.ps1")
. (Join-Path $PSScriptRoot "lib\Auth.ps1")
. (Join-Path $PSScriptRoot "lib\Snapshot.ps1")
. (Join-Path $PSScriptRoot "lib\Classifier.ps1")
. (Join-Path $PSScriptRoot "lib\Plan.ps1")
. (Join-Path $PSScriptRoot "lib\Init.ps1")


# ============================================================================
# Utility
# ============================================================================

function Write-Section {
    param([string]$Text)

    Write-Host ""
    Write-Host "=================================================="
    Write-Host $Text
    Write-Host "=================================================="
}

function Clear-SensitiveVariables {
    # No auth value may survive into output, a manifest, or a log.
    $script:Token = $null
    $script:RefreshToken = $null
    $script:authResult = $null
    $script:Headers = $null
}

function Stop-WithUsageError {
    param([string]$Message)

    Write-Host ""
    Write-Host "Usage error"
    Write-Host "==========="
    Write-Host $Message
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  .\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Init -InitMode FromRemote"
    Write-Host "  .\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Init -InitMode Adopt"
    Write-Host "  .\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Plan"
    Write-Host "  .\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Status"
    Write-Host ""

    Clear-SensitiveVariables
    exit 2
}

function Get-ResolvedInitMode {
    param(
        [string]$RequestedInitMode,
        [bool]$FromRemoteAlias,
        [bool]$InitModeSpecified
    )

    if ($FromRemoteAlias -and $InitModeSpecified -and $RequestedInitMode -ne 'FromRemote') {
        Stop-WithUsageError (
            "-FromRemote conflicts with -InitMode $RequestedInitMode. " +
            "Pass only one, or pass -InitMode FromRemote."
        )
    }

    if ($FromRemoteAlias) {
        return 'FromRemote'
    }

    if (-not [string]::IsNullOrEmpty($RequestedInitMode)) {
        return $RequestedInitMode
    }

    Stop-WithUsageError (
        "Init requires a mode.`n" +
        "Use -InitMode FromRemote to build a trusted workspace from REMOTE,`n" +
        "or -InitMode Adopt to attach sync metadata to an existing tree."
    )
}


# ============================================================================
# Plan / Status
#
# The BASE gate is deliberately consulted before any authentication: a missing
# BASE is a normal first-run state, and the answer must not depend on holding
# a token. Authentication happens only once the run can actually proceed.
#
# Both commands run the same engine. Plan persists a dry-run plan artifact;
# Status persists nothing. Neither mutates Studio, and no operation in this
# milestone is applicable.
# ============================================================================

function Get-RundotSyncVerboseRequested {
    # -Verbose cannot be declared in this script's param block: it collides
    # with the common parameter of the same name. Read it from the bound
    # parameters instead. `powershell -File` passes it as a bare switch, whose
    # bound value is a SwitchParameter; `-Verbose:$false` cannot be expressed
    # that way and is rejected by the host before the body runs.
    param($BoundParameters)

    if ($null -eq $BoundParameters -or -not $BoundParameters.ContainsKey('Verbose')) {
        return $false
    }

    $value = $BoundParameters['Verbose']
    if ($value -is [System.Management.Automation.SwitchParameter]) {
        return [bool]$value.IsPresent
    }

    if ($value -is [bool]) {
        return [bool]$value
    }

    return $false
}

function Invoke-SyncPlanCommand {
    param(
        [string]$SyncCommand,
        [string]$WorkspaceRoot,
        [string]$StudioProjectId,
        [bool]$AllowWithoutBase,
        [bool]$IncludeUnchanged,
        [string]$Origin,
        [string]$SyncAuthDir,
        [string]$SyncAuthPath,
        [string]$CliSessionPath
    )

    # 1. BASE gate, before authentication.
    $resolution = $null

    try {
        $resolution = Resolve-RundotSyncPlanBase `
            -WorkspaceRoot $WorkspaceRoot `
            -ProjectId $StudioProjectId `
            -AllowNoBase:$AllowWithoutBase
    }
    catch {
        Write-Host ""
        Write-Host $_.Exception.Message
        Write-Host ""
        Clear-SensitiveVariables
        exit 1
    }

    # 2. Authenticate. GET-only: every call below reads.
    Write-Section "$SyncCommand - RUN Studio authentication"

    $authResult = Get-RundotAccessToken `
        -StudioOrigin $Origin `
        -ProjectId $StudioProjectId `
        -AuthDir $SyncAuthDir `
        -AuthPath $SyncAuthPath `
        -RundotCliSessionPath $CliSessionPath

    $script:Token = $authResult.AccessToken
    $script:RefreshToken = $authResult.RefreshToken

    $Headers = @{
        Authorization = "Bearer $script:Token"
        Accept        = "*/*"
    }

    $script:Headers = $Headers

    try {
        # 3. LOCAL tree, then a stable REMOTE snapshot. The snapshot is torn-read
        #    protected and staged under .rundot-sync/temp.
        Write-Section "$SyncCommand - LOCAL and REMOTE"

        $localManifest = Get-LocalManifest -WorkspaceRoot $WorkspaceRoot
        Write-Host "LOCAL:  $($localManifest.Count) file(s) inventoried."

        $snapshot = Get-StableRemoteSnapshot `
            -WorkspaceRoot $WorkspaceRoot `
            -StudioOrigin $Origin `
            -ProjectId $StudioProjectId `
            -Headers $Headers

        Write-Host "REMOTE: $($snapshot.Files.Count) file(s) captured."
        Write-Host "  before: $($snapshot.RemoteManifestHashBefore)"
        Write-Host "  after:  $($snapshot.RemoteManifestHashAfter)"

        # 4. Classify and build the dry-run analysis. Only Plan persists.
        $analysis = New-RundotSyncPlanAnalysis `
            -WorkspaceRoot $WorkspaceRoot `
            -ProjectId $StudioProjectId `
            -Resolution $resolution `
            -Local $localManifest `
            -Remote $snapshot.Files `
            -Snapshot $snapshot `
            -Command $SyncCommand `
            -IncludeUnchanged:$IncludeUnchanged `
            -PersistArtifact:($SyncCommand -eq 'Plan')

        Write-Host ""
        Write-Host $analysis.Report
        Write-Host ""

        # 5. A dry run leaves no staging tree behind.
        try {
            Clear-RemoteSnapshotTemp -WorkspaceRoot $WorkspaceRoot
        }
        catch {
            # Staging lives under .rundot-sync/temp, which is never sync
            # content, so a cleanup failure must not fail the plan.
        }
    }
    catch {
        Write-Host ""
        Write-Host $_.Exception.Message
        Write-Host ""
        try {
            Clear-RemoteSnapshotTemp -WorkspaceRoot $WorkspaceRoot
        }
        catch {
            # Cleanup is best effort.
        }
        Clear-SensitiveVariables
        exit 1
    }
    finally {
        $Headers.Authorization = $null
        Clear-SensitiveVariables
    }

    exit 0
}


# ============================================================================
# Init
# ============================================================================

function Invoke-SyncInit {
    param(
        [string]$WorkspaceRoot,
        [string]$StudioProjectId,
        [string]$Mode,
        [string]$Origin,
        [string]$SyncAuthDir,
        [string]$SyncAuthPath,
        [string]$CliSessionPath
    )

    # Pre-flight before authenticating. Both checks are re-run inside the
    # initializers; doing them here too means a run that cannot succeed never
    # asks the user to paste a bearer token first.
    try {
        if ($Mode -eq 'FromRemote') {
            Assert-RundotSyncInitDestination -LocalDir $WorkspaceRoot
        }
        else {
            Assert-RundotSyncAdoptDestination -LocalDir $WorkspaceRoot
        }
    }
    catch {
        Write-Host ""
        Write-Host $_.Exception.Message
        Write-Host ""
        Clear-SensitiveVariables
        exit 1
    }

    Write-Section "RUN Studio authentication"

    $authResult = Get-RundotAccessToken `
        -StudioOrigin $Origin `
        -ProjectId $StudioProjectId `
        -AuthDir $SyncAuthDir `
        -AuthPath $SyncAuthPath `
        -RundotCliSessionPath $CliSessionPath

    $script:Token = $authResult.AccessToken
    $script:RefreshToken = $authResult.RefreshToken

    $Headers = @{
        Authorization = "Bearer $script:Token"
        Accept        = "*/*"
    }

    $script:Headers = $Headers

    try {
        if ($Mode -eq 'FromRemote') {
            Write-Section "Init FromRemote"

            $result = Initialize-RundotSyncFromRemote `
                -LocalDir $WorkspaceRoot `
                -ProjectId $StudioProjectId `
                -StudioOrigin $Origin `
                -Headers $Headers

            Write-Host ""
            Write-Host "Initialized a trusted workspace from REMOTE."
            Write-Host "  Files verified and promoted: $($result.FileCount)"
            Write-Host "  Workspace: $WorkspaceRoot"
            Write-Host ""
            Write-Host "BASE was written only after every promoted file was re-verified."
        }
        else {
            Write-Section "Init Adopt"

            $result = Initialize-RundotSyncByAdopt `
                -LocalDir $WorkspaceRoot `
                -ProjectId $StudioProjectId `
                -StudioOrigin $Origin `
                -Headers $Headers

            Write-Host ""
            Write-Host $result.Report
            Write-Host ""
            Write-Host "Attached sync metadata to the existing tree."
            Write-Host "  Paths recorded in BASE: $($result.BaseFileCount)"
            Write-Host "  Unresolved paths:       $($result.UnresolvedCount)"
        }
    }
    finally {
        $Headers.Authorization = $null
        Clear-SensitiveVariables
    }

    Write-Host ""
    Write-Host "Next:"
    Write-Host "  .\game-studio-sync.ps1 -ProjectId $StudioProjectId -LocalDir `"$WorkspaceRoot`" -Command Plan"
    Write-Host ""

    exit 0
}


# ============================================================================
# Dispatch
# ============================================================================

$initModeSpecified = $PSBoundParameters.ContainsKey('InitMode')

if ($Command -eq 'Init') {
    if ($AllowNoBase) {
        Stop-WithUsageError "-AllowNoBase applies to Plan and Status, not Init."
    }

    $resolvedInitMode = Get-ResolvedInitMode `
        -RequestedInitMode $InitMode `
        -FromRemoteAlias ([bool]$FromRemote) `
        -InitModeSpecified $initModeSpecified

    Invoke-SyncInit `
        -WorkspaceRoot $LocalDir `
        -StudioProjectId $ProjectId `
        -Mode $resolvedInitMode `
        -Origin $StudioOrigin `
        -SyncAuthDir $AuthDir `
        -SyncAuthPath $AuthPath `
        -CliSessionPath $RundotCliSessionPath
}

if ($initModeSpecified -or $FromRemote) {
    Stop-WithUsageError "-InitMode and -FromRemote apply to Init only."
}

Invoke-SyncPlanCommand `
    -SyncCommand $Command `
    -WorkspaceRoot $LocalDir `
    -StudioProjectId $ProjectId `
    -AllowWithoutBase ([bool]$AllowNoBase) `
    -IncludeUnchanged (Get-RundotSyncVerboseRequested -BoundParameters $PSBoundParameters) `
    -Origin $StudioOrigin `
    -SyncAuthDir $AuthDir `
    -SyncAuthPath $AuthPath `
    -CliSessionPath $RundotCliSessionPath
