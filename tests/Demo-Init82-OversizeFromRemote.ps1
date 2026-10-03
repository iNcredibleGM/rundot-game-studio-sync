# Offline demo for GitHub issue #82 — no Studio account or project required.
#
# Simulates a remote listing that includes public/characters/hero/spellCasting.fbx
# over Studio's 2,000,000-byte read limit. Before the fix, Init -InitMode
# FromRemote threw "missing from staging" after downloading everything else.
#
#   powershell -NoProfile -File .\tests\Demo-Init82-OversizeFromRemote.ps1
#
# Exit 0 = demo passed. Exit 1 = something regressed.

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot 'lib\Paths.ps1')
. (Join-Path $repoRoot 'lib\Ignore.ps1')
. (Join-Path $repoRoot 'lib\Hashing.ps1')
. (Join-Path $repoRoot 'lib\Progress.ps1')
. (Join-Path $repoRoot 'lib\Workspace.ps1')
. (Join-Path $repoRoot 'lib\Manifest.ps1')
. (Join-Path $repoRoot 'lib\RemoteApi.ps1')
. (Join-Path $repoRoot 'lib\Snapshot.ps1')
. (Join-Path $repoRoot 'lib\Format.ps1')
. (Join-Path $repoRoot 'lib\Init.ps1')
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

Enable-FakeRemoteProjectReads

function Write-DemoPhase {
    param([string]$Text)
    Write-Host ''
    Write-Host '=================================================='
    Write-Host $Text
    Write-Host '=================================================='
}

function New-DemoRemoteListEntry {
    param([hashtable]$Properties)
    $entry = New-Object PSObject
    foreach ($key in $Properties.Keys) {
        $entry | Add-Member -NotePropertyName $key -NotePropertyValue $Properties[$key]
    }
    return $entry
}

function Fail-Demo {
    param([string]$Message)
    Write-Host ''
    Write-Host "FAIL: $Message"
    exit 1
}

$oversizeLimit = Get-SyncStudioMaxReadableFileSize
$oversizePath = 'public/characters/hero/spellCasting.fbx'
$oversizeListedSize = $oversizeLimit + 1

Write-DemoPhase 'Init #82 offline demo (fake Studio project)'

Write-Host @"
This run fakes GET /files with two files:
  src/a.ts                                          (readable, downloaded)
  $oversizePath  ($oversizeListedSize bytes listed, never downloaded)

Old behavior: Init aborted with ""missing from staging"" for the .fbx.
New behavior: Init finishes; .fbx is reported and omitted from disk and BASE.
"@

$manifest = [pscustomobject]@{
    files = @(
        (New-DemoRemoteListEntry @{
            path     = 'src/a.ts'
            type     = 'file'
            size     = 2
            encoding = 'utf8'
        }),
        (New-DemoRemoteListEntry @{
            path     = $oversizePath
            type     = 'file'
            size     = $oversizeListedSize
            encoding = 'base64'
            kind     = 'binary'
        })
    )
}

Reset-FakeRemote `
    -Lists @($manifest, $manifest) `
    -Files @{
        'src/a.ts' = [pscustomobject]@{ encoding = 'utf8'; content = 'ab' }
    }

$localDir = Join-Path $env:TEMP ('rundot-demo-init82-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $localDir | Out-Null

$headers = @{
    Authorization = 'Bearer demo-token-not-real'
    Accept        = '*/*'
}

Write-DemoPhase 'Running Init -InitMode FromRemote (library path)'

$result = $null
$thrown = $null
try {
    $result = Initialize-RundotSyncFromRemote `
        -LocalDir $localDir `
        -ProjectId 'demo-project-82' `
        -StudioOrigin 'https://example.test' `
        -Headers $headers
}
catch {
    $thrown = $_.Exception
}

if ($null -ne $thrown) {
    Write-Host ''
    Write-Host ('Error: ' + $thrown.Message)
    if ($thrown.Message -match 'missing from staging') {
        Fail-Demo 'Regressed to the #82 failure (oversize path treated as missing staging).'
    }
    Fail-Demo 'Init threw unexpectedly.'
}

$promotedText = Join-Path $localDir 'src\a.ts'
$promotedFbx = Join-Path $localDir 'public\characters\hero\spellCasting.fbx'
$base = Read-BaseManifest -WorkspaceRoot $localDir

Write-DemoPhase 'Results'

foreach ($line in @(Get-RundotSyncInitFromRemoteSummaryLines `
    -FileCount $result.FileCount `
    -Unverifiable $result.Unverifiable)) {
    Write-Host $line
}

Write-Host ''
Write-Host ('GET /file calls: {0} (expected 1, only src/a.ts)' -f $script:FileCallCount)
Write-Host ('Promoted readable file on disk: {0}' -f (Test-Path -LiteralPath $promotedText))
Write-Host ('Oversize .fbx on disk (must be False): {0}' -f (Test-Path -LiteralPath $promotedFbx))
Write-Host ('BASE written: {0}' -f ($null -ne $base))

$baseHasText = ($null -ne $base) -and ($null -ne $base.files.'src/a.ts')
$baseHasFbx = $false
if ($null -ne $base -and $null -ne $base.files) {
    foreach ($prop in @($base.files.PSObject.Properties)) {
        if ([string]$prop.Name -eq $oversizePath) {
            $baseHasFbx = $true
        }
    }
}
Write-Host ('BASE contains src/a.ts: {0}' -f $baseHasText)
Write-Host ('BASE contains oversize .fbx (must be False): {0}' -f $baseHasFbx)

$ok = ($result.FileCount -eq 1) `
    -and ($script:FileCallCount -eq 1) `
    -and (Test-Path -LiteralPath $promotedText) `
    -and (-not (Test-Path -LiteralPath $promotedFbx)) `
    -and $baseHasText `
    -and (-not $baseHasFbx) `
    -and (@($result.Unverifiable).Count -eq 1) `
    -and ([string]$result.Unverifiable[0].Path -eq $oversizePath)

Write-Host ''
if ($ok) {
    Write-Host 'PASS: #82 scenario behaves correctly (Init completes without the oversize file).'
    Write-Host ('Demo workspace (left for inspection): {0}' -f $localDir)
    exit 0
}

Fail-Demo 'One or more checks above did not match expected behavior.'
