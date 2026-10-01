# File and function length budget, enforced as a ratchet.
#
# A file or function must stay under the budget. Anything already over budget
# is frozen in the allowlists below at its current size: it may shrink, and it
# may not grow. When a frozen entry drops under budget, remove it from the
# allowlist so the ratchet tightens.
#
# Budget: 500 lines per product PowerShell file, 150 lines per function.
# Rationale and the ratchet rule are documented in CONTRIBUTING.md.

$repoRoot = Split-Path $PSScriptRoot -Parent

$fileBudget = 500
$functionBudget = 150

# Files over budget today, frozen at their current size. Shrinking is allowed.
$fileAllowlist = @{
    'lib/Classifier.ps1'         = 598
    'lib/Hashing.ps1'            = 558
    'lib/Init.ps1'               = 756
    'lib/Plan.ps1'               = 948
    'lib/Pull.ps1'               = 1082
    'lib/RemoteBinaryPlace.ps1'  = 848
    'lib/Snapshot.ps1'           = 603
    'game-studio-export.ps1'     = 779
    'game-studio-sync.ps1'       = 1124
}

# Functions over budget today, frozen at their current size. Shrinking is allowed.
$functionAllowlist = @{
    'lib/Plan.ps1::Get-SyncPlanOperationRows'          = 152
    'lib/Pull.ps1::Invoke-RundotSyncPullApply'         = 216
    'lib/Pull.ps1::Invoke-RundotSyncPull'              = 256
    'lib/RemoteBinaryPlace.ps1::Assert-RemoteBinaryPlaceStepGate' = 155
    'lib/RemoteBinaryPlace.ps1::Invoke-RemoteBinaryPlaceSequence' = 286
    'game-studio-sync.ps1::Invoke-SyncPushCommand'     = 172
}

function Get-FileLengthRelativePath {
    param([string]$FullName)

    return ($FullName.Substring($repoRoot.Length).TrimStart("\", "/") -replace '\\', '/')
}

function Get-TopLevelFunctions {
    param([string]$Text)

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        return @()
    }

    return @($ast.FindAll({
        param($node)
        if ($node -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { return $false }
        $scriptBlock = $node.Parent.Parent
        return ($scriptBlock -is [System.Management.Automation.Language.ScriptBlockAst] -and $null -eq $scriptBlock.Parent)
    }, $true))
}

$productFiles = @()
$libRoot = Join-Path $repoRoot 'lib'
if (Test-Path $libRoot) {
    $productFiles += @(Get-ChildItem -Path $libRoot -Filter '*.ps1')
}
foreach ($rootFile in @('game-studio-sync.ps1', 'game-studio-export.ps1')) {
    $rootPath = Join-Path $repoRoot $rootFile
    if (Test-Path $rootPath) {
        $productFiles += Get-Item $rootPath
    }
}

$seenFiles = @{}
$seenFunctions = @{}

foreach ($file in $productFiles) {
    $relative = Get-FileLengthRelativePath -FullName $file.FullName
    $seenFiles[$relative] = $true
    $lines = [System.IO.File]::ReadAllLines($file.FullName).Count

    if ($fileAllowlist.ContainsKey($relative)) {
        Assert-True `
            ($lines -le $fileAllowlist[$relative]) `
            "$relative must not grow past its frozen $($fileAllowlist[$relative]) lines (now $lines)"
        Assert-True `
            ($lines -gt $fileBudget) `
            "$relative is back under the $fileBudget-line budget; remove it from the file allowlist"
    }
    else {
        Assert-True `
            ($lines -le $fileBudget) `
            "$relative must stay at or under the $fileBudget-line budget (now $lines)"
    }

    $text = [System.IO.File]::ReadAllText($file.FullName)
    foreach ($function in (Get-TopLevelFunctions -Text $text)) {
        $functionText = $text.Substring($function.Extent.StartOffset, $function.Extent.EndOffset - $function.Extent.StartOffset)
        $functionLines = ($functionText -split "`n").Count
        $key = '{0}::{1}' -f $relative, $function.Name
        $seenFunctions[$key] = $true

        if ($functionAllowlist.ContainsKey($key)) {
            Assert-True `
                ($functionLines -le $functionAllowlist[$key]) `
                "$key must not grow past its frozen $($functionAllowlist[$key]) lines (now $functionLines)"
            Assert-True `
                ($functionLines -gt $functionBudget) `
                "$key is back under the $functionBudget-line budget; remove it from the function allowlist"
        }
        else {
            Assert-True `
                ($functionLines -le $functionBudget) `
                "$key must stay at or under the $functionBudget-line budget (now $functionLines)"
        }
    }
}

foreach ($entry in $fileAllowlist.Keys) {
    Assert-True ($seenFiles.ContainsKey($entry)) "file allowlist entry '$entry' no longer exists; remove it"
}

foreach ($entry in $functionAllowlist.Keys) {
    Assert-True ($seenFunctions.ContainsKey($entry)) "function allowlist entry '$entry' no longer exists; remove it"
}
