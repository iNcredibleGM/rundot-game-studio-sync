# Run every tests/*.Tests.ps1 without Pester.
#
#   powershell -NoProfile -File .\tests\Run-Tests.ps1

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Assert.ps1")
. (Join-Path $PSScriptRoot "TestHelpers.ps1")

foreach ($shadowName in @('Invoke-Utf8TextGet', 'Get-RemoteProjectFileList', 'Get-RemoteProjectFile')) {
    if (Get-Command $shadowName -ErrorAction SilentlyContinue) {
        throw "tests/TestHelpers.ps1 must not define $shadowName at file scope; it would shadow lib/RemoteApi.ps1."
    }
}

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
