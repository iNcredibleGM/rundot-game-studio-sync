# Pull.PlanGate.ps1 - Plan artifact consumption for Pull (#90, Ask 2).
#
# Push hard-gates on the plan artifact because every Push write must match a
# fingerprint the plan recorded. Pull's staged bytes are verified by the
# torn-read-protected snapshot independently, and Pull is commonly run right
# after Init with no plan on disk, so this gate is advisory: when an artifact
# is present it must agree with the run, and a disagreement is reported; when
# it is absent or unusable, Pull still proceeds.
#
# The decision here is deliberately not fatal. A missing artifact is a normal
# state (Init -> Pull), not an error. This module never writes, never mutates
# Studio, and never moves BASE.

function Get-SyncPullPlanGate {
    # Inspect the on-disk plan artifact, if any, and report whether it agrees
    # with this run. Returns a stable shape so the caller can print one line
    # and continue:
    #
    #   Present  - an artifact was read
    #   Usable   - the artifact matches this run and is not expired
    #   Reason   - why it is not usable, or $null when usable
    #   Artifact - the artifact, or $null
    #
    # Never throws for a missing artifact, an unreadable artifact, or an
    # expired one: those are reported, not fatal.
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        $Resolution,

        $Local,

        $Remote,

        $Snapshot
    )

    $notPresent = [pscustomobject]@{
        Present  = $false
        Usable   = $false
        Reason   = $null
        Artifact = $null
    }

    $artifactPath = Get-PlanArtifactPath -WorkspaceRoot $WorkspaceRoot
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
        return $notPresent
    }

    $artifact = $null
    try {
        $artifact = Read-PlanArtifact -WorkspaceRoot $WorkspaceRoot
    }
    catch {
        # A malformed or torn artifact must not block a read-only pull.
        return [pscustomobject]@{
            Present  = $true
            Usable   = $false
            Reason   = ("the plan artifact could not be read ({0})" -f $_.Exception.Message)
            Artifact = $null
        }
    }

    if ($null -eq $artifact) {
        return $notPresent
    }

    $reason = Get-SyncPullPlanGateMismatchReason `
        -Artifact $artifact `
        -ProjectId $ProjectId `
        -WorkspaceRoot $WorkspaceRoot `
        -Resolution $Resolution `
        -Local $Local `
        -Remote $Remote `
        -Snapshot $Snapshot

    return [pscustomobject]@{
        Present  = $true
        Usable   = ($null -eq $reason)
        Reason   = $reason
        Artifact = $artifact
    }
}

function Get-SyncPullPlanGateMismatchReason {
    # The first reason the artifact does not describe this run, or $null when it
    # agrees. The checks mirror the Push identity/freshness/hash gates so the
    # two commands cannot disagree about what "the same plan" means.
    param(
        [Parameter(Mandatory)]
        $Artifact,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        $Resolution,

        $Local,

        $Remote,

        $Snapshot
    )

    if (-not [string]::Equals([string]$Artifact.projectId, $ProjectId, [System.StringComparison]::Ordinal)) {
        return 'it was built for a different project'
    }

    if (
        -not [string]::Equals(
            [string]$Artifact.localRootFingerprint,
            (Get-LocalRootFingerprint -WorkspaceRoot $WorkspaceRoot),
            [System.StringComparison]::Ordinal
        )
    ) {
        return 'it was built for a different workspace folder'
    }

    if (-not [bool]$Artifact.basePresent -or [bool]$Artifact.untrusted) {
        return 'it was built without a verified BASE'
    }

    $expiresAt = [System.DateTime]::Parse(
        [string]$Artifact.expiresAt,
        $null,
        [System.Globalization.DateTimeStyles]::RoundtripKind
    )
    if ($expiresAt.Kind -eq [System.DateTimeKind]::Unspecified) {
        $expiresAt = [System.DateTime]::SpecifyKind($expiresAt, [System.DateTimeKind]::Utc)
    }
    elseif ($expiresAt.Kind -eq [System.DateTimeKind]::Local) {
        $expiresAt = $expiresAt.ToUniversalTime()
    }

    if ([DateTime]::UtcNow -ge $expiresAt) {
        return 'it has expired'
    }

    if ($null -ne $Local) {
        if (
            -not [string]::Equals(
                [string]$Artifact.localManifestHash,
                (Get-SyncLocalManifestFingerprint -Local $Local),
                [System.StringComparison]::Ordinal
            )
        ) {
            return 'LOCAL changed since it was created'
        }
    }

    if ($null -ne $Snapshot) {
        if (
            -not [string]::Equals(
                [string]$Artifact.remoteManifestHashBefore,
                [string]$Snapshot.RemoteManifestHashBefore,
                [System.StringComparison]::Ordinal
            ) -or
            -not [string]::Equals(
                [string]$Artifact.remoteManifestHashAfter,
                [string]$Snapshot.RemoteManifestHashAfter,
                [System.StringComparison]::Ordinal
            )
        ) {
            return 'REMOTE changed since it was created'
        }
    }

    return $null
}

function Format-SyncPullPlanGateLine {
    # One advisory line for the pull header, computed from the run's inputs. A
    # missing artifact is silent because it is a normal state; anything else is
    # stated plainly. Returns $null when there is nothing to say.
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        $Resolution,

        $Local,

        $Remote,

        $Snapshot
    )

    $gate = Get-SyncPullPlanGate `
        -WorkspaceRoot $WorkspaceRoot `
        -ProjectId $ProjectId `
        -Resolution $Resolution `
        -Local $Local `
        -Remote $Remote `
        -Snapshot $Snapshot

    if ($null -eq $gate -or -not [bool]$gate.Present) {
        return $null
    }

    if ([bool]$gate.Usable) {
        return ("Plan artifact: {0} - matches this pull." -f [string]$gate.Artifact.planId)
    }

    return (
        "Plan artifact: ignored ({0}). Re-run Plan to preview this pull against a fresh plan." -f `
            [string]$gate.Reason
    )
}
