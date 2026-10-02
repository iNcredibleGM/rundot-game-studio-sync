# Format-SyncShortHash display contract.
# Do not require Pester.

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "lib\Format.ps1")

Assert-Equal '<none>' (Format-SyncShortHash -Value $null) 'null should render as <none>'
Assert-Equal '<none>' (Format-SyncShortHash -Value '') 'empty string should render as <none>'

$sixteen = 'a' * 16
Assert-Equal $sixteen (Format-SyncShortHash -Value $sixteen) '16 characters should be unchanged'

$seventeen = 'abcdefghijklmnopq'
Assert-Equal 'abcdefgh...nopq' (Format-SyncShortHash -Value $seventeen) '17 characters should use short form'

$fullSha = 'd385701c11111111111111111111111111111111111111111111111143be'
Assert-Equal 'd385701c...43be' (Format-SyncShortHash -Value $fullSha) '64-character hex should use short form'
Assert-Equal 15 ((Format-SyncShortHash -Value $fullSha).Length) 'short form should be 15 characters'

$planSource = [System.IO.File]::ReadAllText((Join-Path $repoRoot "lib\Plan.ps1"))
$initSource = [System.IO.File]::ReadAllText((Join-Path $repoRoot "lib\Init.ps1"))

foreach ($removed in @(
    'function Get-SyncPlanNonNoOpRows'
    'function Format-SyncPlanShortHash'
    'function Format-RundotSyncShortHash'
)) {
    Assert-True ($planSource -notmatch [regex]::Escape($removed)) "lib/Plan.ps1 should not define $removed"
    Assert-True ($initSource -notmatch [regex]::Escape($removed)) "lib/Init.ps1 should not define $removed"
}

Assert-True ($planSource -match 'Format-SyncShortHash') 'lib/Plan.ps1 should call Format-SyncShortHash'
Assert-True ($initSource -match 'Format-SyncShortHash') 'lib/Init.ps1 should call Format-SyncShortHash'
