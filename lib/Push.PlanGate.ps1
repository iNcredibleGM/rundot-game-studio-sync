# Push.PlanGate.ps1 - Plan artifact validation gates.
#
# Part of the Push split (#70). Loaded by lib/Push.ps1; do not dot-source
# directly. The gates run in the original order: identity and BASE binding,
# then freshness, then live manifest hashes.

function Assert-SyncPushPlanArtifactIdentity {
    # Shape, project binding, workspace fingerprint, BASE presence, and the
    # BASE capturedAt the plan was built against.
    param(
        [AllowNull()]
        $Artifact,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        $Resolution
    )

    if ($null -eq $Artifact) {
        throw [System.InvalidOperationException]::new(
            'No plan artifact found. Run Plan before Push.'
        )
    }

    Assert-PlanArtifactShape -Artifact $Artifact

    if (-not [string]::Equals([string]$Artifact.projectId, $ProjectId, [System.StringComparison]::Ordinal)) {
        throw [System.InvalidOperationException]::new(
            'Refusing to push: plan projectId does not match this command.'
        )
    }

    $expectedFingerprint = Get-LocalRootFingerprint -WorkspaceRoot $WorkspaceRoot
    if (
        -not [string]::Equals(
            [string]$Artifact.localRootFingerprint,
            $expectedFingerprint,
            [System.StringComparison]::Ordinal
        )
    ) {
        throw [System.InvalidOperationException]::new(
            'Refusing to push: plan localRootFingerprint does not match this workspace folder.'
        )
    }

    if (-not [bool]$Artifact.basePresent -or [bool]$Artifact.untrusted) {
        throw [System.InvalidOperationException]::new(
            'Refusing to push: the plan was built without a verified BASE.'
        )
    }

    if ($null -eq $Resolution -or $null -eq $Resolution.Base) {
        throw [System.InvalidOperationException]::new(
            'Refusing to push: BASE is missing.'
        )
    }

    $baseCapturedAt = $null
    $capturedProperty = $Resolution.Base.PSObject.Properties['capturedAt']
    if ($null -ne $capturedProperty) {
        $baseCapturedAt = [string]$capturedProperty.Value
    }

    if (-not [string]::Equals([string]$Artifact.baseCapturedAt, $baseCapturedAt, [System.StringComparison]::Ordinal)) {
        throw [System.InvalidOperationException]::new(
            'Refusing to push: BASE changed since this plan was created. Re-run Plan.'
        )
    }
}

function Assert-SyncPushPlanArtifactFreshness {
    param(
        [Parameter(Mandatory)]
        $Artifact
    )

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
        throw [System.InvalidOperationException]::new(
            'Refusing to push: this plan has expired. Re-run Plan.'
        )
    }
}

function Assert-SyncPushPlanArtifactHashes {
    param(
        [Parameter(Mandatory)]
        $Artifact,

        [Parameter(Mandatory)]
        $Local,

        [Parameter(Mandatory)]
        $Snapshot
    )

    $liveLocalHash = Get-SyncLocalManifestFingerprint -Local $Local
    if (
        -not [string]::Equals(
            [string]$Artifact.localManifestHash,
            $liveLocalHash,
            [System.StringComparison]::Ordinal
        )
    ) {
        throw [System.InvalidOperationException]::new(
            'Refusing to push: LOCAL changed since this plan was created. Re-run Plan.'
        )
    }

    if (
        -not [string]::Equals(
            [string]$Artifact.remoteManifestHashBefore,
            [string]$Snapshot.RemoteManifestHashBefore,
            [System.StringComparison]::Ordinal
        )
    ) {
        throw [System.InvalidOperationException]::new(
            'Refusing to push: REMOTE changed since this plan was created. Re-run Plan.'
        )
    }

    if (
        -not [string]::Equals(
            [string]$Artifact.remoteManifestHashAfter,
            [string]$Snapshot.RemoteManifestHashAfter,
            [System.StringComparison]::Ordinal
        )
    ) {
        throw [System.InvalidOperationException]::new(
            'Refusing to push: REMOTE changed since this plan was created. Re-run Plan.'
        )
    }
}

function Assert-RundotSyncPushPlanArtifact {
    param(
        [AllowNull()]
        $Artifact,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory)]
        $Resolution,

        [Parameter(Mandatory)]
        $Local,

        [Parameter(Mandatory)]
        $Snapshot
    )

    Assert-SyncPushPlanArtifactIdentity `
        -Artifact $Artifact `
        -ProjectId $ProjectId `
        -WorkspaceRoot $WorkspaceRoot `
        -Resolution $Resolution

    Assert-SyncPushPlanArtifactFreshness -Artifact $Artifact

    Assert-SyncPushPlanArtifactHashes `
        -Artifact $Artifact `
        -Local $Local `
        -Snapshot $Snapshot
}
