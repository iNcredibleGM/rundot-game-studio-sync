# URL construction and JSON wrapping for GET-only Studio helpers.
# Network is stubbed. Do not print tokens.

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "lib\RemoteApi.ps1")

$script:CapturedTextUri = $null
$script:CapturedTextHeaders = $null

function Invoke-Utf8TextGet {
    param(
        [string]$Uri,
        [hashtable]$Headers
    )

    $script:CapturedTextUri = $Uri
    $script:CapturedTextHeaders = $Headers
    return '{"ok":true,"count":1}'
}

$jsonHeaders = @{
    Accept = "*/*"
}

$jsonResult = Invoke-Utf8JsonGet `
    -Uri "https://example.test/json" `
    -Headers $jsonHeaders

Assert-Equal "https://example.test/json" $script:CapturedTextUri "Invoke-Utf8JsonGet should GET the given URI"
Assert-Equal "*/*" $script:CapturedTextHeaders.Accept "Invoke-Utf8JsonGet should pass headers through"
Assert-Equal $true $jsonResult.ok "Invoke-Utf8JsonGet should parse JSON"
Assert-Equal 1 $jsonResult.count "Invoke-Utf8JsonGet should preserve JSON numbers"

$script:CapturedJsonUri = $null
$script:CapturedJsonHeaders = $null
$script:CapturedJsonResult = @{ files = @() }

function Invoke-Utf8JsonGet {
    param(
        [string]$Uri,
        [hashtable]$Headers
    )

    $script:CapturedJsonUri = $Uri
    $script:CapturedJsonHeaders = $Headers
    return $script:CapturedJsonResult
}

$origin = "https://venus-studio-prod.series-ai.workers.dev"
$projectId = "proj-test-1"
$headers = @{
    Authorization = "Bearer test-token"
    Accept        = "*/*"
}

$list = Get-RemoteProjectFileList `
    -StudioOrigin $origin `
    -ProjectId $projectId `
    -Headers $headers

Assert-Equal `
    "$origin/api/projects/$projectId/files" `
    $script:CapturedJsonUri `
    "Get-RemoteProjectFileList should GET /files"
Assert-Equal "Bearer test-token" $script:CapturedJsonHeaders.Authorization "list GET should pass Authorization"
Assert-Equal "*/*" $script:CapturedJsonHeaders.Accept "list GET should pass Accept"
Assert-Equal 0 @($list.files).Count "list GET should return the stubbed payload"

$filePath = "/foo bar/" + [char]0x00E9 + [char]0x6587 + [char]0x4EF6 + ".txt"
$encodedPath = [System.Uri]::EscapeDataString($filePath)

$script:CapturedJsonResult = @{
    encoding = "utf8"
    content  = "hi"
}

$file = Get-RemoteProjectFile `
    -StudioOrigin $origin `
    -ProjectId $projectId `
    -Path $filePath `
    -Headers $headers

Assert-Equal `
    "$origin/api/projects/$projectId/file?path=$encodedPath" `
    $script:CapturedJsonUri `
    "Get-RemoteProjectFile should encode the path query"
Assert-Equal "Bearer test-token" $script:CapturedJsonHeaders.Authorization "file GET should pass Authorization"
Assert-Equal "utf8" $file.encoding "file GET should return the stubbed payload"
