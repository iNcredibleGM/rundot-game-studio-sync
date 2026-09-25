# Remote upload route contracts: URI shape and JSON bodies only.
#
# Do not require Pester. No network.

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "lib\Paths.ps1")
. (Join-Path $repoRoot "lib\Ignore.ps1")
. (Join-Path $repoRoot "lib\Hashing.ps1")
. (Join-Path $repoRoot "lib\Workspace.ps1")
. (Join-Path $repoRoot "lib\RemoteApi.ps1")
. (Join-Path $repoRoot "lib\Snapshot.ps1")
. (Join-Path $repoRoot "lib\RemoteWrite.ps1")
. (Join-Path $repoRoot "lib\RemoteUpload.ps1")

$remoteUploadTestOrigin = 'https://example.test'
$remoteUploadTestProjectId = 'proj-upload-test'

function Assert-RemoteUploadTestThrowsLike {
    param(
        [scriptblock]$Script,
        [string]$Pattern,
        [string]$Message
    )

    $threw = $false
    $text = $null

    try {
        & $Script | Out-Null
    }
    catch {
        $threw = $true
        $text = $_.Exception.Message
    }

    Assert-True $threw $Message
    if ($threw) {
        Assert-True ($text -match $Pattern) ("$Message (pattern '$Pattern', got '$text')")
    }
}

$uploadUri = New-RemoteUploadUrlUri `
    -StudioOrigin $remoteUploadTestOrigin `
    -ProjectId $remoteUploadTestProjectId
Assert-Equal `
    "$remoteUploadTestOrigin/api/projects/$remoteUploadTestProjectId/upload-url" `
    $uploadUri `
    "upload-url URI must target the project upload-url route"

$uploadBody = ConvertTo-RemoteUploadUrlJsonBody -DeclaredSize 71
$uploadBodyText = (New-Object System.Text.UTF8Encoding $false).GetString($uploadBody)
Assert-Equal '{"declaredSize":71}' $uploadBodyText "upload-url body must contain only declaredSize"

Assert-RemoteUploadTestThrowsLike {
    ConvertTo-RemoteUploadUrlJsonBody -DeclaredSize 0 | Out-Null
} 'positive integer' 'declaredSize zero must refuse'

$adoptBody = ConvertTo-RemoteUploadAdoptJsonBody -UploadId 'abc-123' -Name 'rundot-sync-deadbeef.txt'
$adoptBodyText = (New-Object System.Text.UTF8Encoding $false).GetString($adoptBody)
Assert-Equal '{"uploadId":"abc-123","name":"rundot-sync-deadbeef.txt"}' $adoptBodyText `
    "upload-adopt body must contain only uploadId and name"
