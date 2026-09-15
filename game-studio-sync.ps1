param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectId,

    [Parameter(Mandatory = $true)]
    [string]$LocalDir,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Init', 'Plan', 'Status', 'Pull')]
    [string]$Command,

    [ValidateSet('FromRemote', 'Adopt')]
    [string]$InitMode,

    # Documented alias for -InitMode FromRemote.
    [switch]$FromRemote,

    # Advanced escape hatch for Plan/Status when BASE is missing.
    [switch]$AllowNoBase,

    # Pull only: skip the overwrite confirmation prompt. Never skips backups.
    [switch]$ForcePull
)

$ErrorActionPreference = "Stop"

# ============================================================================
# RUN Game Studio Sync
#
# Read-oriented sync for a Studio project. Neither LOCAL nor REMOTE is
# authoritative: BASE is the last verified shared state, and any ambiguity is
# a conflict rather than a guess.
#
# Init is the only first-run command. Init and Pull write BASE: Init builds it
# on first run, and Pull replaces it only after every pulled byte is verified.
# Plan and Status are read-only: Plan writes a dry-run plan artifact, Status
# writes nothing, and neither touches Studio.
#
#   .\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Init -InitMode FromRemote
#   .\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Init -InitMode Adopt
#   .\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Plan
#   .\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Status
#   .\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Pull
#
# Plan and Status are dry runs. They show what a future Apply would consider,
# but no operation is applicable in this milestone and no plan is permission
# to write. Add -Verbose to also list unchanged paths.
#
# Pull is the only command that writes LOCAL. It applies clean remote-only
# changes, backs up every overwritten file into .rundot-sync/backups first,
# re-verifies the written bytes, and updates BASE only after all of that
# succeeds. It asks for confirmation before overwriting; -ForcePull skips the
# prompt but never a backup, and never bypasses the concurrent-edit guard.
# Pull never deletes anything, locally or remotely.
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
. (Join-Path $PSScriptRoot "lib\Backup.ps1")
. (Join-Path $PSScriptRoot "lib\Journal.ps1")
. (Join-Path $PSScriptRoot "lib\Pull.ps1")
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
    Write-Host "  .\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Pull"
    Write-Host "  .\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Pull -ForcePull"
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
# Pull
#
# Pull is the only command in this milestone that writes LOCAL. It applies
# clean remote-only changes, backs up every overwrite first, re-verifies the
# written bytes, and updates BASE only after all of that succeeds.
#
# Pull never mutates Studio. -ForcePull may skip the confirmation prompt, but
# it never skips a backup, and it never bypasses the concurrent-edit guard.
# ============================================================================

function Read-RundotSyncPullConfirmation {
    # Deliberate confirmation: the user must type the whole word. Anything
    # else, including an empty line or a closed console, declines.
    param(
        [int]$OverwriteCount,

        [string[]]$Paths
    )

    Write-Host ""
    Write-Host "Confirmation required"
    Write-Host "====================="
    Write-Host "Pull will overwrite $OverwriteCount existing local file(s):"
    foreach ($path in @($Paths)) {
        Write-Host "  $path"
    }
    Write-Host ""
    Write-Host "Each one is copied into .rundot-sync/backups before it is replaced."
    Write-Host "Type 'yes' to continue. Anything else cancels the pull."

    $answer = $null
    try {
        $answer = Read-Host "Overwrite $OverwriteCount local file(s)?"
    }
    catch {
        # No console to prompt on. Fail closed.
        return $false
    }

    return [string]::Equals(
        ([string]$answer).Trim(),
        'yes',
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Invoke-SyncPullCommand {
    param(
        [string]$WorkspaceRoot,
        [string]$StudioProjectId,
        [bool]$Force,
        [string]$Origin,
        [string]$SyncAuthDir,
        [string]$SyncAuthPath,
        [string]$CliSessionPath
    )

    # 1. BASE gate, before authentication. Pull has no untrusted mode: without
    #    a verified BASE there is no shared state to pull against, so it must
    #    never ask for a token to find that out.
    $resolution = $null

    try {
        $resolution = Resolve-RundotSyncPlanBase `
            -WorkspaceRoot $WorkspaceRoot `
            -ProjectId $StudioProjectId
    }
    catch {
        Write-Host ""
        Write-Host $_.Exception.Message
        Write-Host ""
        Clear-SensitiveVariables
        exit 1
    }

    # 2. Authenticate. GET-only: every call below reads.
    Write-Section "Pull - RUN Studio authentication"

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

    # The engine owns the write; the CLI owns only the prompt. Keeping the
    # callback here means the engine stays testable without a console.
    $ConfirmOverwrite = {
        param($OverwriteCount, $Paths)
        return (Read-RundotSyncPullConfirmation -OverwriteCount $OverwriteCount -Paths $Paths)
    }

    try {
        # 3. LOCAL tree, then a stable REMOTE snapshot. The snapshot is
        #    torn-read protected, and its staged bytes are what Pull writes.
        Write-Section "Pull - LOCAL and REMOTE"

        $localManifest = Get-LocalManifest -WorkspaceRoot $WorkspaceRoot
        Write-Host "LOCAL:  $($localManifest.Count) file(s) inventoried."

        $snapshot = Get-StableRemoteSnapshot `
            -WorkspaceRoot $WorkspaceRoot `
            -StudioOrigin $Origin `
            -ProjectId $StudioProjectId `
            -Headers $Headers

        Write-Host "REMOTE: $($snapshot.Files.Count) file(s) captured."

        # 4. Select, confirm, apply, verify, and update BASE. The engine
        #    aborts before writing if any overwrite cannot be confirmed.
        $result = Invoke-RundotSyncPull `
            -WorkspaceRoot $WorkspaceRoot `
            -ProjectId $StudioProjectId `
            -Resolution $resolution `
            -Local $localManifest `
            -Remote $snapshot.Files `
            -Snapshot $snapshot `
            -ConfirmOverwrite $ConfirmOverwrite `
            -Force:$Force

        Write-Host ""
        Write-Host $result.Report
        Write-Host ""

        # 5. Staging is never sync content, so it is cleared after the run.
        try {
            Clear-RemoteSnapshotTemp -WorkspaceRoot $WorkspaceRoot
        }
        catch {
            # Cleanup is best effort.
        }

        Clear-SensitiveVariables

        if ($result.Cancelled) {
            exit 1
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

    if ($ForcePull) {
        Stop-WithUsageError "-ForcePull applies to Pull only."
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

if ($Command -eq 'Pull') {
    if ($AllowNoBase) {
        Stop-WithUsageError (
            "-AllowNoBase applies to Plan and Status, not Pull.`n" +
            "Pull requires a verified BASE: without one there is no shared state to pull against."
        )
    }

    Invoke-SyncPullCommand `
        -WorkspaceRoot $LocalDir `
        -StudioProjectId $ProjectId `
        -Force ([bool]$ForcePull) `
        -Origin $StudioOrigin `
        -SyncAuthDir $AuthDir `
        -SyncAuthPath $AuthPath `
        -CliSessionPath $RundotCliSessionPath
}

if ($ForcePull) {
    Stop-WithUsageError "-ForcePull applies to Pull only."
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
