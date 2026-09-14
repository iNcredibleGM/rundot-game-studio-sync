# Safe Pull: the one command in this milestone that writes LOCAL.
#
# Pull applies exactly one classification: a clean download
# (BASE=A LOCAL=A REMOTE=B). Neither LOCAL nor REMOTE is authoritative, so
# everything else is excluded with a reason and left alone. In particular:
#
#   - a local-only change (A/B/A) is never overwritten by a pull
#   - a conflict (A/B/C) has no safe direction
#   - deleteLocalCandidate (A/A/-) reports and leaves the local file in place
#   - deleteRemoteCandidate (A/-/A), settledAbsent, ignored, and every no-op
#     are report-only
#
# A download that replaces an existing local file is flagged as an overwrite:
# the caller counts those, confirms them, and backs each one up before writing.
#
# This file also owns the apply/verify/rollback path and the verified BASE
# update. Every local write is backed up first and re-hashed afterwards, so a
# partial run can be rolled back and can never leave a BASE that describes
# bytes that were not just verified.
#
# Callers must load Paths.ps1, Ignore.ps1, Hashing.ps1, Workspace.ps1,
# Manifest.ps1, Snapshot.ps1, Classifier.ps1, Plan.ps1, Backup.ps1, and
# Journal.ps1 first.

$script:SyncPullLocalWriteDirectory = $true


function Get-SyncPullSelection {
    # Split the three-way classification into the actions Pull may apply and
    # everything else, with a reason. Pure: no filesystem access, no network,
    # and no mutation of any input map.
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

        if ($status -ne $script:SyncStatusDownload) {
            $excluded.Add([pscustomobject]@{
                Path       = $path
                Status     = $status
                Reason     = Get-SyncPullExclusionReason -Change $change
                Ignored    = [bool]$change.Ignored
                KindChange = [bool]$change.KindChange
            })
            continue
        }

        $localEntry = Get-SyncMapEntry -Map $Local -Path $path
        $remoteEntry = Get-SyncMapEntry -Map $Remote -Path $path
        $isOverwrite = ($null -ne $localEntry)

        $actions.Add([pscustomobject]@{
            Path              = $path
            Status            = $status
            Kind              = [string](Get-SyncEntryKind -Entry $remoteEntry)
            LocalSha256       = $change.LocalSha256
            RemoteSha256      = $change.RemoteSha256
            RemoteStagingPath = [string](Get-SyncEntryProperty `
                -Entry $remoteEntry `
                -Names @('StagingPath', 'stagingPath'))
            IsOverwrite       = [bool]$isOverwrite
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
        Overwrites = @(Get-SyncPullOverwriteRows -Actions $actionRows)
    }
}

function Get-SyncPullExclusionReason {
    # One reason per non-download status. The wording is a safety surface:
    # a local-only change must read as "Pull will not overwrite this", not as
    # a pending action.
    param($Change)

    $status = [string]$Change.Status

    switch ($status) {
        $script:SyncStatusUpload {
            return 'LOCAL differs from BASE while REMOTE still matches BASE. Pull never overwrites a local change.'
        }
        $script:SyncStatusConflict {
            if ([bool]$Change.KindChange) {
                return $script:SyncKindChangeReason
            }

            return $script:SyncConflictReason
        }
        $script:SyncStatusDeleteLocalCandidate {
            return 'REMOTE no longer has this path while LOCAL still matches BASE. Pull reports it and leaves the local file in place.'
        }
        $script:SyncStatusDeleteRemoteCandidate {
            return 'LOCAL no longer has this path while REMOTE still matches BASE. Pull does not delete remote content.'
        }
        $script:SyncStatusIgnored {
            return $script:SyncIgnoredReason
        }
        $script:SyncStatusUnchanged {
            return 'BASE, LOCAL, and REMOTE all agree, so there is nothing to pull.'
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

    return 'This path is not a clean remote-only change, so Pull does not apply it.'
}

function Get-SyncPullOverwriteRows {
    # The subset of actions that replace an existing local file. This is what
    # the confirmation prompt counts and what the backup set must cover.
    param([object[]]$Actions)

    if ($null -eq $Actions) {
        return @()
    }

    $rows = @($Actions | Where-Object { [bool]$_.IsOverwrite })
    if ($rows.Count -eq 0) {
        return @()
    }

    return $rows
}
