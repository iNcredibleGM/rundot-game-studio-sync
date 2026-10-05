# Push.Report.ps1 - Push report formatter.
#
# Part of the Push split (#70). Loaded by lib/Push.ps1; do not dot-source
# directly. Function bodies are unchanged from the original lib/Push.ps1.

function Format-SyncPushReport {
    param(
        $Selection,

        [object[]]$AppliedActions,

        [int]$Applied = 0,

        [object[]]$CreatedActions = $null,

        [int]$Created = 0,

        [object[]]$DeletedActions = $null,

        [int]$Deleted = 0,

        [object[]]$BinaryActions = $null,

        [object[]]$Skipped = $null,

        [object[]]$Refused = $null,

        [bool]$Cancelled = $false,

        [bool]$BaseUpdated = $false,

        [string]$PlanId = $null,

        [string]$BackupRoot = $null,

        [string]$BackupSetPath = $null
    )

    $lines = New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add('RUN Game Studio Sync - Push')

    if (-not [string]::IsNullOrEmpty($PlanId)) {
        [void]$lines.Add(('planId: {0}' -f $PlanId))
    }

    if ($Cancelled) {
        [void]$lines.Add('')
        [void]$lines.Add('Push cancelled. No remote files were changed and BASE was not updated.')
        return ([string]::Join("`n", $lines.ToArray()))
    }

    $actionRows = @($AppliedActions)
    $createdRows = @($CreatedActions)
    $binaryRows = @($BinaryActions)
    $deletedRows = @($DeletedActions)
    $skippedRows = @($Skipped)
    if ($null -eq $Skipped -and $null -ne $Selection) {
        $skippedRows = @($Selection.Excluded)
    }

    if ($actionRows.Count -eq 0 -and $createdRows.Count -eq 0 -and $binaryRows.Count -eq 0 -and $deletedRows.Count -eq 0) {
        [void]$lines.Add('')
        [void]$lines.Add('Nothing to push: no publishable overwrite, text create, binary place, or confirmed delete remains in this plan.')
        [void]$lines.Add('BASE was not updated.')
    }
    else {
        if ($actionRows.Count -gt 0) {
            [void]$lines.Add('')
            [void]$lines.Add('APPLIED')
            foreach ($action in $actionRows) {
                [void]$lines.Add(('  {0}  (overwrite)' -f [string]$action.Path))
            }
        }

        if ($createdRows.Count -gt 0) {
            [void]$lines.Add('')
            [void]$lines.Add('CREATED')
            foreach ($action in $createdRows) {
                [void]$lines.Add(('  {0}  (text create)' -f [string]$action.Path))
            }
        }

        if ($binaryRows.Count -gt 0) {
            [void]$lines.Add('')
            [void]$lines.Add('BINARY')
            foreach ($action in $binaryRows) {
                $modeLabel = [string]$action.Mode
                if ([string]::IsNullOrEmpty($modeLabel)) {
                    $modeLabel = 'place'
                }

                [void]$lines.Add(('  {0}  (binary {1})' -f [string]$action.Path, $modeLabel))
            }
        }

        if ($deletedRows.Count -gt 0) {
            [void]$lines.Add('')
            [void]$lines.Add('DELETED')
            foreach ($action in $deletedRows) {
                [void]$lines.Add(('  {0}  (delete)' -f [string]$action.Path))
            }
        }
    }

    if ($skippedRows.Count -gt 0) {
        [void]$lines.Add('')
        [void]$lines.Add('SKIPPED')
        foreach ($row in $skippedRows) {
            $reason = ([string]$row.Reason).Replace("`r", ' ').Replace("`n", ' ')
            [void]$lines.Add(('  {0}  [{1}]  {2}' -f [string]$row.Path, [string]$row.Status, $reason))
        }
    }

    $refusedRows = @($Refused)
    if ($refusedRows.Count -gt 0) {
        [void]$lines.Add('')
        [void]$lines.Add('REFUSED')
        foreach ($row in $refusedRows) {
            $reason = ([string]$row.Reason).Replace("`r", ' ').Replace("`n", ' ')
            [void]$lines.Add(('  {0}  [{1}]  {2}' -f [string]$row.Path, [string]$row.Status, $reason))
        }
    }

    [void]$lines.Add('')
    [void]$lines.Add('SUMMARY')
    [void]$lines.Add(('  applied:      {0}' -f $Applied))
    [void]$lines.Add(('  created:      {0}' -f $Created))
    [void]$lines.Add(('  deleted:      {0}' -f $Deleted))
    [void]$lines.Add(('  skipped:      {0}' -f $skippedRows.Count))
    [void]$lines.Add(('  refused:      {0}' -f $refusedRows.Count))
    [void]$lines.Add(('  BASE updated: {0}' -f ([bool]$BaseUpdated).ToString().ToLowerInvariant()))

    if (-not [string]::IsNullOrEmpty($BackupRoot)) {
        [void]$lines.Add('')
        [void]$lines.Add('BACKUPS')
        [void]$lines.Add(('  backup root: {0}' -f $BackupRoot))
        if (-not [string]::IsNullOrEmpty($BackupSetPath)) {
            [void]$lines.Add(('  this run:    {0}' -f $BackupSetPath))
        }
        [void]$lines.Add('  Restore the previous remote bytes by copying them back from the backup set.')
    }

    [void]$lines.Add('')
    [void]$lines.Add('Push writes REMOTE only. It never changes LOCAL files.')
    [void]$lines.Add('WARNING: This tool uses unofficial remote API routes that may change.')

    return ([string]::Join("`n", $lines.ToArray()))
}
