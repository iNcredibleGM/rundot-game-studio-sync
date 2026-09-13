# Run every tests/*.Tests.ps1 without Pester.
#
#   powershell -NoProfile -File .\tests\Run-Tests.ps1

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Assert.ps1")

$testFiles = @(
    Get-ChildItem `
        -Path $PSScriptRoot `
        -Filter "*.Tests.ps1" |
        Sort-Object Name
)

if ($testFiles.Count -eq 0) {
    Write-Host "No *.Tests.ps1 files found."
}

foreach ($file in $testFiles) {
    Write-Host "Running $($file.Name)"
    . $file.FullName
}

Write-Host ""
Write-Host "Passed: $TestPasses"
Write-Host "Failed: $TestFailures"

if ($TestFailures -gt 0) {
    exit 1
}

exit 0
