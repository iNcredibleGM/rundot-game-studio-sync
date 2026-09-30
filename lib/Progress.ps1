# Host-visible progress for long-running sync work.
#
# Write-Progress is invisible in some hosts, so every progress line is also
# printed as plain text. This file is the only place that emits progress text,
# which keeps throttling, the plain-line fallback, and the redaction rule in
# one spot.
#
# Safety: progress output carries a canonical path and integer counts only.
# It never prints file contents or any credential, and it never reads a file.
# Progress is also best-effort: a failure to print must never abort a hash,
# backup, or write, so every emit is wrapped and swallowed.
#
# Callers must load Paths.ps1 first for ConvertTo-CanonicalSyncPath.

# Tests may replace this with a scriptblock that captures lines instead of
# printing them. Product code never sets it.
$script:RundotSyncProgressWriter = $null

$script:RundotSyncProgressDefaultIntervalMs = 1000

function Write-RundotSyncProgressLine {
    # The one output seam for progress text. A test can install a writer that
    # appends to a list; everything else goes to the host.
    #
    # The write is swallowed on failure: a closed pipe or a throwing writer
    # must never abort the hash, backup, or write the progress describes.
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    try {
        if ($null -ne $script:RundotSyncProgressWriter) {
            & $script:RundotSyncProgressWriter $Text
            return
        }

        Write-Host $Text
    }
    catch {
        # Progress must never change the outcome of the work it reports.
    }
}

function New-RundotSyncProgressState {
    param(
        [Parameter(Mandatory)]
        [string]$Activity,

        [int]$Total = 0,

        [int]$MinIntervalMs = 0
    )

    if ($MinIntervalMs -le 0) {
        $MinIntervalMs = $script:RundotSyncProgressDefaultIntervalMs
    }

    return [pscustomobject]@{
        Activity      = $Activity
        Total         = $Total
        MinIntervalMs = $MinIntervalMs
        LastEmitUtc   = [DateTime]::MinValue
    }
}

function Write-RundotSyncProgress {
    # Emit a progress line for one item. The plain line is throttled to
    # MinIntervalMs so a large tree does not flood the host; -Force bypasses
    # the throttle for the start and final lines. The Write-Progress bar is
    # updated on every call when a total is known, because hosts that show it
    # expect a smooth bar.
    param(
        [Parameter(Mandatory)]
        $State,

        [int]$Index = 0,

        [AllowEmptyString()]
        [string]$Path = '',

        [switch]$Force
    )

    if ($null -eq $State) {
        return
    }

    try {
        $now = [DateTime]::UtcNow
        $shouldPrint = [bool]$Force

        if (-not $shouldPrint) {
            $elapsedMs = ($now - $State.LastEmitUtc).TotalMilliseconds
            if ($elapsedMs -ge $State.MinIntervalMs) {
                $shouldPrint = $true
            }
        }

        if ($shouldPrint) {
            $State.LastEmitUtc = $now

            $text = [string]$State.Activity
            if ($State.Total -gt 0 -and $Index -gt 0) {
                $text += (": {0} of {1}" -f $Index, $State.Total)
            }
            elseif ($Index -gt 0) {
                $text += (": {0}" -f $Index)
            }

            if (-not [string]::IsNullOrEmpty($Path)) {
                $text += (": {0}" -f $Path)
            }

            Write-RundotSyncProgressLine -Text $text
        }

        if ($State.Total -gt 0) {
            $percent = 0
            if ($Index -gt 0) {
                $percent = [int][Math]::Min(
                    100,
                    [Math]::Floor(($Index * 100.0) / $State.Total)
                )
            }

            Write-Progress `
                -Activity ([string]$State.Activity) `
                -Status $Path `
                -PercentComplete $percent `
                -CurrentOperation ("{0} of {1}" -f $Index, $State.Total) `
                -ErrorAction SilentlyContinue
        }
    }
    catch {
        # Progress must never change the outcome of the work it reports.
    }
}

function Write-RundotSyncPublishProgress {
    # One line per mutating publish item. Publishing names every path on
    # purpose, so the user can see which file is being backed up or written
    # and how many remain; it is not throttled. The line carries a canonical
    # path and integers only.
    param(
        [Parameter(Mandatory)]
        [ValidateSet('backup', 'write', 'writing')]
        [string]$Phase,

        [Parameter(Mandatory)]
        [string]$Path,

        [int]$Index = 0,

        [int]$Total = 0,

        [int]$Applied = 0
    )

    $verb = 'Publishing'
    if ($Phase -eq 'backup') {
        $verb = 'Backing up'
    }
    elseif ($Phase -eq 'writing') {
        $verb = 'Writing'
    }

    $remaining = 0
    if ($Total -gt 0 -and $Index -gt 0) {
        $remaining = [Math]::Max(0, $Total - $Index)
    }

    $text = ("{0} {1} of {2}: {3} (applied {4}, remaining {5})" -f `
        $verb, $Index, $Total, $Path, $Applied, $remaining)

    try {
        Write-RundotSyncProgressLine -Text $text
    }
    catch {
        # Progress must never change the outcome of the work it reports.
    }
}

function Complete-RundotSyncProgress {
    # Close a progress run: a forced final plain line, then clear the bar.
    param(
        [Parameter(Mandatory)]
        $State,

        [AllowEmptyString()]
        [string]$Text = ''
    )

    if ($null -eq $State) {
        return
    }

    try {
        if (-not [string]::IsNullOrEmpty($Text)) {
            Write-RundotSyncProgressLine -Text $Text
        }

        if ($State.Total -gt 0) {
            Write-Progress `
                -Activity ([string]$State.Activity) `
                -Completed `
                -ErrorAction SilentlyContinue
        }
    }
    catch {
        # Progress must never change the outcome of the work it reports.
    }
}
