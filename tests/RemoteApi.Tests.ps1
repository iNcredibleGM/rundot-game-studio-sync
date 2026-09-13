# URL construction and JSON wrapping for GET-only Studio helpers.
# Network is stubbed. Do not print tokens.

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "lib\RemoteApi.ps1")


# --------------------------------------------------------------------------
# ConvertFrom-RemoteJson: HTML / non-JSON must never become a payload
# --------------------------------------------------------------------------

$emptyFiles = ConvertFrom-RemoteJson -Text '{"files":[]}'
Assert-Equal 0 @($emptyFiles.files).Count "object JSON with an empty files array should parse"

$jsonArray = ConvertFrom-RemoteJson -Text '[{"ok":true},{"ok":false}]'
Assert-True ($jsonArray -is [System.Array]) "a JSON array payload should remain an array"
Assert-Equal 2 @($jsonArray).Count "a JSON array should keep its elements"
Assert-Equal $true $jsonArray[0].ok "a JSON array payload should parse"

$paddedObject = ConvertFrom-RemoteJson -Text "  `n{`"ok`":true}"
Assert-Equal $true $paddedObject.ok "leading whitespace before JSON should still parse"

Assert-Throws {
    ConvertFrom-RemoteJson -Text '<!DOCTYPE html><html><body>login</body></html>'
} "an HTML login page must not parse as remote JSON"

Assert-Throws {
    ConvertFrom-RemoteJson -Text '<html>login</html>'
} "an html element body must not parse as remote JSON"

Assert-Throws {
    ConvertFrom-RemoteJson -Text '<HTML>LOGIN</HTML>'
} "HTML detection must be case-insensitive"

Assert-Throws {
    ConvertFrom-RemoteJson -Text 'not json'
} "plain text must not parse as remote JSON"

Assert-Throws {
    ConvertFrom-RemoteJson -Text ''
} "an empty body must not parse as remote JSON"

Assert-Throws {
    ConvertFrom-RemoteJson -Text '   '
} "a whitespace-only body must not parse as remote JSON"

Assert-Throws {
    ConvertFrom-RemoteJson -Text '{"files":'
} "truncated JSON must not parse as a remote payload"

try {
    ConvertFrom-RemoteJson -Text '<!DOCTYPE html><html>login</html>'
    Assert-True $false "HTML ConvertFrom-RemoteJson should have thrown"
}
catch {
    Assert-True (
        $_.Exception.Message -match '(?i)html'
    ) "HTML rejection should say the payload was HTML, not a torn read"
}


# --------------------------------------------------------------------------
# HTTP status attachment: Snapshot can classify 404 vs auth vs other
# --------------------------------------------------------------------------

$notFound = New-RemoteHttpException -StatusCode 404
Assert-Equal 404 (Get-RemoteHttpStatusCode -Exception $notFound) "a 404 wrapper should expose HttpStatusCode"
Assert-True (Test-RemoteNotFoundException -Exception $notFound) "404 must classify as remote not-found"

$unauthorized = New-RemoteHttpException -StatusCode 401
Assert-Equal 401 (Get-RemoteHttpStatusCode -Exception $unauthorized) "a 401 wrapper should expose HttpStatusCode"
Assert-True (-not (Test-RemoteNotFoundException -Exception $unauthorized)) "401 must not classify as remote not-found"

$plain = [System.InvalidOperationException]::new("Remote GET failed.")
Assert-Null (Get-RemoteHttpStatusCode -Exception $plain) "an exception without status data should not invent a code"
Assert-True (-not (Test-RemoteNotFoundException -Exception $plain)) "a status-less exception is not a 404"

$innerNotFound = [System.InvalidOperationException]::new(
    "wrapper",
    (New-RemoteHttpException -StatusCode 404)
)
Assert-Equal `
    404 `
    (Get-RemoteHttpStatusCode -Exception $innerNotFound) `
    "status lookup should walk InnerException"

$webException = New-Object System.Net.WebException(
    "The remote server returned an error.",
    [System.Net.WebExceptionStatus]::ProtocolError
)
$wrappedWeb = Convert-WebExceptionToRemoteHttpException -Exception $webException
Assert-True (
    $wrappedWeb -is [System.InvalidOperationException]
) "a WebException with no response should wrap as InvalidOperationException"
Assert-Null `
    (Get-RemoteHttpStatusCode -Exception $wrappedWeb) `
    "a WebException with no response must not invent HttpStatusCode"

$remoteApiSource = [System.IO.File]::ReadAllText((Join-Path $repoRoot "lib\RemoteApi.ps1"))
Assert-True `
    ($remoteApiSource -match 'Convert-WebExceptionToRemoteHttpException') `
    "Invoke-Utf8TextGet should wrap WebException through Convert-WebExceptionToRemoteHttpException"
$wrapStart = $remoteApiSource.IndexOf('function Convert-WebExceptionToRemoteHttpException')
$wrapNext = $remoteApiSource.IndexOf("`nfunction ", $wrapStart + 1)
$wrapLength = $remoteApiSource.Length - $wrapStart
if ($wrapNext -ge 0) {
    $wrapLength = $wrapNext - $wrapStart
}
$wrapText = ""
if ($wrapStart -ge 0) {
    $wrapText = $remoteApiSource.Substring($wrapStart, $wrapLength)
}
Assert-True `
    ($wrapText -notmatch 'ConvertFrom-RemoteJson') `
    "error-page bodies must not be parsed as JSON"


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

function Invoke-Utf8TextGet {
    param(
        [string]$Uri,
        [hashtable]$Headers
    )

    $script:CapturedTextUri = $Uri
    $script:CapturedTextHeaders = $Headers
    return '<!DOCTYPE html><html>login</html>'
}

Assert-Throws {
    Invoke-Utf8JsonGet -Uri "https://example.test/login" -Headers $jsonHeaders
} "Invoke-Utf8JsonGet should reject an HTML login page instead of hashing it"

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
