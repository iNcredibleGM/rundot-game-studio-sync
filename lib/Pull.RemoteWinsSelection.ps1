# Pull.RemoteWinsSelection.ps1 - Confirmed remote-wins replace for Pull (#90).
#
# Pull's default selection applies only a clean download. A conflict
# (BASE=A LOCAL=B REMOTE=C) has no direction, so a local file that also changed
# in Studio can never be brought up to Studio's bytes. -RemoteWins adds the
# confirmed replace mode that mirrors Push -LocalWins, in the opposite
# direction: REMOTE bytes overwrite LOCAL, after a backup.
#
# It stays a pull, not a reset:
#   - it never deletes a local-only file (an upload row)
#   - it never deletes anything, locally or remotely
#   - it never rebuilds the tree; Init -InitMode FromRemote is the only reset
#
# Every action it returns has the same shape the default selection produces, so
# the existing apply layer (backup, concurrent-edit guard, atomic write,
# rollback) and the existing BASE update are reused unchanged.

function Get-SyncPullRemoteWinsExclusionReason {
    # One reason per out-of-scope status. The wording is a safety surface: a
    # local-only change must read as "this will not be touched", not as a
    # pending action.
    param($Change)

    $status = [string]$Change.Status

    if ([bool]$Change.KindChange) {
        return $script:SyncKindChangeReason
    }

    switch ($status) {
        $script:SyncStatusDownload {
            return 'REMOTE differs from BASE while LOCAL still matches BASE. Plain Pull already applies this; -RemoteWins only replaces a both-changed path.'
        }
        $script:SyncStatusUpload {
            return 'LOCAL differs from BASE while REMOTE still matches BASE. -RemoteWins never deletes or overwrites a local-only change.'
        }
        $script:SyncStatusConflict {
            return 'This conflict cannot be replaced: a kind change or a missing side has no safe byte direction.'
        }
        $script:SyncStatusDeleteLocalCandidate {
            return 'REMOTE no longer has this path while LOCAL still matches BASE. -RemoteWins does not delete a local file.'
        }
        $script:SyncStatusDeleteRemoteCandidate {
            return 'LOCAL no longer has this path while REMOTE still matches BASE. -RemoteWins does not delete remote content.'
        }
        $script:SyncStatusIgnored {
            return $script:SyncIgnoredReason
        }
        $script:SyncStatusUnchanged {
            return 'BASE, LOCAL, and REMOTE all agree, so there is nothing to pull.'
        }
        $script:SyncStatusUnverifiable {
            return 'REMOTE is over Studio''s read limit, so its bytes cannot be read. -RemoteWins cannot replace this path; it is left untouched.'
        }
        $script:SyncStatusSynchronizedChange {
            return 'LOCAL and REMOTE already agree on the new content, so there is nothing to pull.'
        }
        $script:SyncStatusSynchronizedAddition {
            return 'LOCAL and REMOTE already agree on this untracked path, so there is nothing to pull.'
        }
        $script:SyncStatusSettledAbsent {
            return 'This path is absent from both LOCAL and REMOTE, so there is nothing to pull.'
        }
    }

    return 'This path is not a both-changed conflict, so -RemoteWins does not replace it.'
}

function Get-SyncPullRemoteWinsSelection {
    # Split the three-way classification into the rows -RemoteWins may replace
    # and everything else, with a reason. Pure: no filesystem access, no
    # network, and no mutation of any input map.
    #
    # In scope is exactly one status: conflict (A/B/C) with both sides present
    # and no kind change. That is the row plain Pull refuses to touch, and the
    # exact mirror of Push -LocalWins.
    param(
        $Base,
        $Local,
        $Remote
    )

    $changes = @(Get-SyncPlanChanges -Base $Base -Local $Local -Remote $Remote)

    $actions = New-Object 'System.Collections.Generic.List[object]'
    $excluded = New-Object 'System.Collections.Generic.List[object]'

    foreach ($change in @($changes)) {
        $path = [string]$change.Path
        $status = [string]$change.Status

        $localEntry = Get-SyncMapEntry -Map $Local -Path $path
        $remoteEntry = Get-SyncMapEntry -Map $Remote -Path $path

        if (
            $status -ne $script:SyncStatusConflict -or
            [bool]$change.KindChange -or
            $null -eq $localEntry -or
            $null -eq $remoteEntry
        ) {
            $excluded.Add([pscustomobject]@{
                Path       = $path
                Status     = $status
                Reason     = Get-SyncPullRemoteWinsExclusionReason -Change $change
                Ignored    = [bool]$change.Ignored
                KindChange = [bool]$change.KindChange
            })
            continue
        }

        $actions.Add([pscustomobject]@{
            Path              = $path
            Status            = $status
            Kind              = [string](Get-SyncEntryKind -Entry $remoteEntry)
            LocalSha256       = $change.LocalSha256
            RemoteSha256      = $change.RemoteSha256
            RemoteStagingPath = [string](Get-SyncEntryProperty `
                -Entry $remoteEntry `
                -Names @('StagingPath', 'stagingPath'))
            IsOverwrite       = $true
        })
    }

    $actionRows = @()
    if ($actions.Count -gt 0) {
        $actionRows = $actions.ToArray()
    }

    $excludedRows = @()
    if ($excluded.Count -gt 0) {
        $excludedRows = $excluded.ToArray()
    }

    return [pscustomobject]@{
        Actions    = $actionRows
        Excluded   = $excludedRows
        Overwrites = @($actionRows)
        RemoteWins = $true
    }
}

function Get-SyncPullRemoteWinsSelectionForRun {
    # The selection the Pull engine uses for a run. -RemoteWins replaces the
    # default clean-download selection with the confirmed replace set; the
    # default path is untouched.
    param(
        [switch]$RemoteWins,
        $Base,
        $Local,
        $Remote
    )

    if ($RemoteWins) {
        return (Get-SyncPullRemoteWinsSelection -Base $Base -Local $Local -Remote $Remote)
    }

    return (Get-SyncPullSelection -Base $Base -Local $Local -Remote $Remote)
}
