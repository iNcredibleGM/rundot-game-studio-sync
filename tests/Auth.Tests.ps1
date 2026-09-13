# Offline contracts for shared authentication helpers.

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "lib\RemoteApi.ps1")
. (Join-Path $repoRoot "lib\Auth.ps1")

$jwt = "eyJhbGciOiJub25lIn0.eyJzdWIiOiJ0ZXN0In0.signature"
Assert-Equal $jwt (Get-TokenFromText "authorization: Bearer $jwt") "authorization header token should parse"
Assert-Equal $jwt (Get-TokenFromText "curl -H 'authorization: Bearer $jwt'") "POSIX cURL token should parse"
Assert-Equal $jwt (Get-TokenFromText ('curl -H "authorization: Bearer ' + $jwt + '"')) "Windows cURL token should parse"
Assert-Equal $jwt (Get-TokenFromText "Bearer $jwt") "Bearer token should parse"
Assert-Equal $jwt (Get-TokenFromText "  $jwt  ") "raw JWT should parse"
Assert-Null (Get-TokenFromText "not a token") "garbage should not parse as a token"

$bootstrap = Get-BootstrapAuthFromText '{"apiKey":"test-key","refreshToken":"test-refresh"}'
Assert-Equal "test-key" $bootstrap.ApiKey "bootstrap API key should parse"
Assert-Equal "test-refresh" $bootstrap.RefreshToken "bootstrap refresh token should parse"
Assert-Null (Get-BootstrapAuthFromText '{"apiKey":"test-key"}') "incomplete bootstrap JSON should not parse"
Assert-Null (Get-BootstrapAuthFromText "not json") "non-JSON bootstrap text should not parse"

function New-TestJwt {
    param([int64]$Expiry)
    $payload = '{"exp":' + $Expiry + '}'
    $payloadPart = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return "header.$payloadPart.signature"
}

$freshJwt = New-TestJwt ([DateTimeOffset]::UtcNow.AddMinutes(10).ToUnixTimeSeconds())
$nearExpiryJwt = New-TestJwt ([DateTimeOffset]::UtcNow.AddMinutes(4).ToUnixTimeSeconds())
$expiredJwt = New-TestJwt ([DateTimeOffset]::UtcNow.AddMinutes(-1).ToUnixTimeSeconds())
Assert-True (Test-RundotCliTokenFresh -AccessToken $expiredJwt -ExpiresAtUnixTimeMs ([DateTimeOffset]::UtcNow.AddMinutes(10).ToUnixTimeMilliseconds())) "session expiry should be preferred"
Assert-True (Test-RundotCliTokenFresh -AccessToken $freshJwt -ExpiresAtUnixTimeMs 0) "zero session expiry should fall back to JWT"
Assert-True (Test-RundotCliTokenFresh -AccessToken $freshJwt -ExpiresAtUnixTimeMs -1) "negative session expiry should fall back to JWT"
Assert-True (Test-RundotCliTokenFresh -AccessToken $freshJwt -ExpiresAtUnixTimeMs "bad") "invalid session expiry should fall back to JWT"
Assert-True (-not (Test-RundotCliTokenFresh -AccessToken $nearExpiryJwt -ExpiresAtUnixTimeMs 0)) "five-minute safety window should reject near expiry"
Assert-True (-not (Test-RundotCliTokenFresh -AccessToken "bad-token" -ExpiresAtUnixTimeMs 0)) "malformed JWT should be rejected"

$testRoot = Join-Path $env:TEMP ("rundot-auth-tests-" + [Guid]::NewGuid().ToString("N"))
$sessionPath = Join-Path $testRoot "session.json"
$authPath = Join-Path $testRoot "studio-export.auth.json"
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    Assert-Null (Get-RundotCliSession -RundotCliSessionPath $sessionPath) "missing CLI session should return null"
    [IO.File]::WriteAllText($sessionPath, "not json")
    Assert-Null (Get-RundotCliSession -RundotCliSessionPath $sessionPath) "invalid CLI session JSON should return null"
    [IO.File]::WriteAllText($sessionPath, '{"accessToken":"","expiresAtUnixTimeMs":1}')
    Assert-Null (Get-RundotCliSession -RundotCliSessionPath $sessionPath) "empty CLI token should return null"
    [IO.File]::WriteAllText($sessionPath, '{"accessToken":"test-access","expiresAtUnixTimeMs":123}')
    $session = Get-RundotCliSession -RundotCliSessionPath $sessionPath
    Assert-True ($session.ContainsKey("AccessToken") -and $session.ContainsKey("ExpiresAtUnixTimeMs")) "valid CLI session should expose expected keys"

    $script:ValidatedAuthorization = $null
    function Get-RemoteProjectFileList {
        param([string]$StudioOrigin, [string]$ProjectId, [hashtable]$Headers)
        $script:ValidatedAuthorization = $Headers.Authorization
        return @{ files = @() }
    }

    $futureExpiry = [DateTimeOffset]::UtcNow.AddMinutes(10).ToUnixTimeMilliseconds()
    [IO.File]::WriteAllText($sessionPath, ('{"accessToken":"test-cli-token","expiresAtUnixTimeMs":' + $futureExpiry + '}'))
    $authResult = Get-RundotAccessToken `
        -StudioOrigin "https://example.test" `
        -ProjectId "project-test" `
        -AuthDir $testRoot `
        -AuthPath $authPath `
        -RundotCliSessionPath $sessionPath
    Assert-Equal "Bearer test-cli-token" $script:ValidatedAuthorization "CLI token should validate through the remote file list"
    Assert-Equal "test-cli-token" $authResult.AccessToken "fresh CLI token should be returned"
    Assert-Equal 0 @($authResult.Manifest.files).Count "validated CLI manifest should be returned"

    try {
        Save-StudioAuth -AuthDir $testRoot -AuthPath $authPath -ApiKey "test-api-key" -RefreshToken "test-refresh-token"
        $authBytes = [IO.File]::ReadAllBytes($authPath)
        $authText = [Text.Encoding]::UTF8.GetString($authBytes)
        Assert-True (-not $authText.Contains("test-refresh-token")) "saved auth must not contain plaintext refresh token"
        $savedJson = $authText | ConvertFrom-Json
        Assert-Equal 1 $savedJson.version "saved auth schema version should be one"
        Assert-Equal "test-api-key" $savedJson.apiKey "saved auth should retain API key"
        $loaded = Load-StudioAuth -AuthPath $authPath
        Assert-Equal "test-api-key" $loaded.ApiKey "loaded auth should retain API key"
        Assert-Equal "test-refresh-token" $loaded.RefreshToken "loaded auth should decrypt the refresh token"
    }
    catch [System.Security.Cryptography.CryptographicException] {
        Write-Host "SKIP: DPAPI is unavailable in this non-interactive test host."
    }
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
