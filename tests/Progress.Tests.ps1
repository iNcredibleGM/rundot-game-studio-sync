# Progress helper contracts: throttling, plain lines, publish lines, safety.
#
# Do not require Pester. No network.
#
# SCOPE NOTE: tests/Run-Tests.ps1 dot-sources every *.Tests.ps1 into one
# scope, in filename order. Helpers here are prefixed ProgressTest* so they
# never shadow a library function another test file needs.

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "lib\Paths.ps1")
. (Join-Path $repoRoot "lib\Progress.ps1")

$script:ProgressTestLines = New-Object 'System.Collections.Generic.List[string]'

function Start-ProgressTestCapture {
    $script:ProgressTestLines.Clear()
    $script:RundotSyncProgressWriter = {
        param([string]$Text)
        $script:ProgressTestLines.Add($Text)
    }
}

function Stop-ProgressTestCapture {
    $script:RundotSyncProgressWriter = $null
}

function Get-ProgressTestLines {
    # The comma keeps a single-element result as an array; PowerShell would
    # otherwise unroll it to a bare string, and $lines[0] would be a character.
    return ,@($script:ProgressTestLines.ToArray())
}

# --------------------------------------------------------------------------
# Plain lines: start and final always emit; intermediate lines throttle
# --------------------------------------------------------------------------

Start-ProgressTestCapture
try {
    $state = New-RundotSyncProgressState -Activity 'Hashing local files'
    Write-RundotSyncProgress -State $state -Index 0 -Path 'C:\tree' -Force

    # A second call inside the interval must not print.
    Write-RundotSyncProgress -State $state -Index 1 -Path 'src/a.ts'

    # -Force bypasses the throttle for the final line.
    Complete-RundotSyncProgress -State $state -Text 'Hashed 1 local file(s).'

    $lines = Get-ProgressTestLines
    Assert-Equal 2 $lines.Count "start and final lines must always emit"
    Assert-True ($lines[0] -match 'Hashing local files') "the start line must name the activity"
    Assert-True ($lines[1] -match 'Hashed 1 local file\(s\)') "the final line must summarize the run"
}
finally {
    Stop-ProgressTestCapture
}

# A state with no total still prints plain lines, without a "0 of 0" suffix.
Start-ProgressTestCapture
try {
    $noTotal = New-RundotSyncProgressState -Activity 'Hashing local files'
    Write-RundotSyncProgress -State $noTotal -Index 3 -Path 'src/b.ts' -Force
    $lines = Get-ProgressTestLines
    Assert-Equal 1 $lines.Count "an unknown-total state must still print"
    Assert-True ($lines[0] -match 'src/b\.ts') "the line must name the current path"
    Assert-True ($lines[0] -notmatch '0 of 0') "an unknown total must not print '0 of 0'"
}
finally {
    Stop-ProgressTestCapture
}

# With a total, the line reports index of total and the path.
Start-ProgressTestCapture
try {
    $known = New-RundotSyncProgressState -Activity 'Downloading remote project' -Total 4
    Write-RundotSyncProgress -State $known -Index 2 -Path 'src/c.ts' -Force
    $lines = Get-ProgressTestLines
    Assert-True `
        ($lines[0] -match '2 of 4' -and $lines[0] -match 'src/c\.ts') `
        "a known-total line must report the index and path"
}
finally {
    Stop-ProgressTestCapture
}

# A writer that throws must not surface to the caller: progress is best effort.
$script:RundotSyncProgressWriter = { param([string]$Text) throw 'writer exploded' }
try {
    $state = New-RundotSyncProgressState -Activity 'Hashing local files'
    Write-RundotSyncProgress -State $state -Index 1 -Path 'src/a.ts' -Force
    Complete-RundotSyncProgress -State $state -Text 'done'
    Assert-True $true "a failing progress writer must not abort the work it reports"
}
catch {
    Assert-True $false "a failing progress writer must not throw"
}
finally {
    Stop-ProgressTestCapture
}

# --------------------------------------------------------------------------
# Publish lines: per-path, with applied/remaining counts and phase verbs
# --------------------------------------------------------------------------

Start-ProgressTestCapture
try {
    Write-RundotSyncPublishProgress `
        -Phase 'backup' `
        -Path 'src/a.ts' `
        -Index 1 `
        -Total 3 `
        -Applied 0
    Write-RundotSyncPublishProgress `
        -Phase 'write' `
        -Path 'src/b.ts' `
        -Index 2 `
        -Total 3 `
        -Applied 1

    $lines = Get-ProgressTestLines
    Assert-Equal 2 $lines.Count "each publish item must print exactly one line"
    Assert-True `
        ($lines[0] -match 'Backing up 1 of 3' -and $lines[0] -match 'src/a\.ts' -and $lines[0] -match 'applied 0, remaining 2') `
        "a backup line must name the path with applied and remaining counts"
    Assert-True `
        ($lines[1] -match 'Publishing 2 of 3' -and $lines[1] -match 'src/b\.ts' -and $lines[1] -match 'applied 1, remaining 1') `
        "a write line must name the path with applied and remaining counts"
}
finally {
    Stop-ProgressTestCapture
}

# --------------------------------------------------------------------------
# Safety: progress never carries secrets or file contents
# --------------------------------------------------------------------------

$progressSource = [System.IO.File]::ReadAllText((Join-Path $repoRoot "lib\Progress.ps1"))

foreach ($banned in @('Token', 'Authorization', 'RefreshToken', 'Headers', 'Get-Content', 'ReadAllText', 'ReadAllBytes')) {
    Assert-True `
        ($progressSource -notmatch [regex]::Escape($banned)) `
        "lib\Progress.ps1 must not reference $banned"
}

# The helper must not add a Studio write route.
Assert-True `
    ($progressSource -notmatch '(?i)upload-url|upload-adopt') `
    "lib\Progress.ps1 must not reference a Studio upload endpoint"
Assert-True `
    ($progressSource -notmatch '(?im)^\s*function\s+(Set|Remove)-') `
    "lib\Progress.ps1 must not define a Set-* or Remove-* function"
