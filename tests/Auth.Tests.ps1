# Offline contracts for shared authentication helpers.

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "lib\RemoteApi.ps1")
. (Join-Path $repoRoot "lib\Auth.ps1")

$authSource = [System.IO.File]::ReadAllText((Join-Path $repoRoot "lib\Auth.ps1"))
Assert-True ($authSource -notmatch 'Write-Host') "lib/Auth.ps1 must not call Write-Host"
Assert-True ($authSource -notmatch 'Write-Warning') "lib/Auth.ps1 must not call Write-Warning"
Assert-True ($authSource -notmatch 'Read-Host') "lib/Auth.ps1 must not call Read-Host"

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

function New-AuthStatusCollector {
    $lines = New-Object 'System.Collections.Generic.List[object]'
    $script:AuthStatusCollectorLines = $lines
    $writeStatus = {
        param($Text, $Kind)
        [void]$script:AuthStatusCollectorLines.Add([pscustomobject]@{ Text = [string]$Text; Kind = [string]$Kind })
    }
    return @{ Lines = $lines; WriteStatus = $writeStatus }
}

function Assert-AuthStatusSequence {
    param(
        $Collector,
        [string[]]$ExpectedTexts,
        [string]$Kind = 'Host'
    )

    Assert-Equal $ExpectedTexts.Count $Collector.Lines.Count "auth status line count should match"
    for ($i = 0; $i -lt $ExpectedTexts.Count; $i++) {
        Assert-Equal $Kind $Collector.Lines[$i].Kind "auth status line $($i) should use stream $Kind"
        Assert-Equal $ExpectedTexts[$i] $Collector.Lines[$i].Text "auth status line $($i) text should match"
    }
}

function Assert-AuthStatusContainsNoSecret {
    param(
        $Collector,
        [string]$Secret
    )

    foreach ($line in $Collector.Lines) {
        Assert-True (-not $line.Text.Contains($Secret)) "auth status must not echo secrets"
    }
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
$missingSessionPath = Join-Path $testRoot "missing-session.json"
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
    $script:ManifestAcceptTokens = @{}
    function Get-RemoteProjectFileList {
        param([string]$StudioOrigin, [string]$ProjectId, [hashtable]$Headers)
        $script:ValidatedAuthorization = $Headers.Authorization
        $token = $Headers.Authorization -replace '^Bearer\s+', ''
        if ($script:ManifestAcceptTokens.ContainsKey($token)) {
            if ($script:ManifestAcceptTokens[$token]) {
                return @{ files = @() }
            }
            return $null
        }
        return @{ files = @() }
    }

    function Get-Clipboard {
        param([switch]$Raw)
        return $script:TestClipboardText
    }

    $futureExpiry = [DateTimeOffset]::UtcNow.AddMinutes(10).ToUnixTimeMilliseconds()
    [IO.File]::WriteAllText($sessionPath, ('{"accessToken":"test-cli-token","expiresAtUnixTimeMs":' + $futureExpiry + '}'))
    $cliCollector = New-AuthStatusCollector
    $authResult = Get-RundotAccessToken `
        -StudioOrigin "https://example.test" `
        -ProjectId "project-test" `
        -AuthDir $testRoot `
        -AuthPath $authPath `
        -RundotCliSessionPath $sessionPath `
        -WriteStatus $cliCollector.WriteStatus
    Assert-Equal "Bearer test-cli-token" $script:ValidatedAuthorization "CLI token should validate through the remote file list"
    Assert-Equal "test-cli-token" $authResult.AccessToken "fresh CLI token should be returned"
    Assert-Equal 0 @($authResult.Manifest.files).Count "validated CLI manifest should be returned"
    Assert-AuthStatusSequence -Collector $cliCollector -ExpectedTexts @(
        'Found RUNdot CLI session.',
        'Testing fresh CLI authentication against Studio...',
        'RUNdot CLI authentication accepted.'
    )
    Assert-AuthStatusContainsNoSecret -Collector $cliCollector -Secret 'test-cli-token'

    $expiredCollector = New-AuthStatusCollector
    [IO.File]::WriteAllText($sessionPath, ('{"accessToken":"' + $nearExpiryJwt + '","expiresAtUnixTimeMs":0}'))
    $script:TestClipboardText = ''
    $script:ManualPromptCount = 0
    $null = Get-RundotAccessToken `
        -StudioOrigin "https://example.test" `
        -ProjectId "project-test" `
        -AuthDir $testRoot `
        -AuthPath $authPath `
        -RundotCliSessionPath $sessionPath `
        -WriteStatus $expiredCollector.WriteStatus `
        -ReadManualToken { $script:ManualPromptCount++; return 'manual-expired-fallback' }
    Assert-AuthStatusSequence -Collector $expiredCollector -ExpectedTexts @(
        'Found RUNdot CLI session, but its access token is expired or near expiry.',
        'Run `rundot login` to refresh it.',
        'Trying other authentication methods...',
        'Testing manually supplied token...',
        'Manual Studio authentication accepted.'
    )

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

        function Get-FreshStudioToken {
            param([string]$ApiKey, [string]$RefreshToken)
            if ($RefreshToken -eq 'test-refresh-token') {
                return @{ AccessToken = 'saved-refreshed-token'; RefreshToken = 'saved-refreshed-refresh' }
            }
            if ($RefreshToken -eq 'bootstrap-refresh') {
                return @{ AccessToken = 'bootstrap-refreshed-token'; RefreshToken = 'bootstrap-refreshed-refresh' }
            }
            return $null
        }

        $savedCollector = New-AuthStatusCollector
        $script:TestClipboardText = ''
        $savedResult = Get-RundotAccessToken `
            -StudioOrigin "https://example.test" `
            -ProjectId "project-test" `
            -AuthDir $testRoot `
            -AuthPath $authPath `
            -RundotCliSessionPath $missingSessionPath `
            -WriteStatus $savedCollector.WriteStatus
        Assert-Equal 'saved-refreshed-token' $savedResult.AccessToken "saved refresh should return a refreshed access token"
        Assert-AuthStatusSequence -Collector $savedCollector -ExpectedTexts @(
            'Found saved RUN Studio authentication.',
            'Refreshing Studio token...',
            'Saved Studio authentication accepted.'
        )

        $savedRejectCollector = New-AuthStatusCollector
        $script:ManifestAcceptTokens = @{ 'saved-reject-token' = $false }
        function Get-FreshStudioToken {
            param([string]$ApiKey, [string]$RefreshToken)
            return @{ AccessToken = 'saved-reject-token'; RefreshToken = 'saved-reject-refresh' }
        }
        $script:TestClipboardText = ''
        $script:ManualPromptCount = 0
        $null = Get-RundotAccessToken `
            -StudioOrigin "https://example.test" `
            -ProjectId "project-test" `
            -AuthDir $testRoot `
            -AuthPath $authPath `
            -RundotCliSessionPath $missingSessionPath `
            -WriteStatus $savedRejectCollector.WriteStatus `
            -ReadManualToken { $script:ManualPromptCount++; return 'manual-after-saved-reject' }
        Assert-AuthStatusSequence -Collector $savedRejectCollector -ExpectedTexts @(
            'Found saved RUN Studio authentication.',
            'Refreshing Studio token...',
            'Saved Studio authentication was refreshed,',
            'but Studio rejected the resulting token.',
            'Testing manually supplied token...',
            'Manual Studio authentication accepted.'
        )

        Remove-Item -LiteralPath $authPath -Force
        Save-StudioAuth -AuthDir $testRoot -AuthPath $authPath -ApiKey "test-api-key" -RefreshToken "test-refresh-token"
        $savedFailCollector = New-AuthStatusCollector
        function Get-FreshStudioToken {
            param([string]$ApiKey, [string]$RefreshToken)
            return $null
        }
        $script:TestClipboardText = ''
        $script:ManualPromptCount = 0
        $null = Get-RundotAccessToken `
            -StudioOrigin "https://example.test" `
            -ProjectId "project-test" `
            -AuthDir $testRoot `
            -AuthPath $authPath `
            -RundotCliSessionPath $missingSessionPath `
            -WriteStatus $savedFailCollector.WriteStatus `
            -ReadManualToken { $script:ManualPromptCount++; return 'manual-after-saved-fail' }
        Assert-AuthStatusSequence -Collector $savedFailCollector -ExpectedTexts @(
            'Found saved RUN Studio authentication.',
            'Refreshing Studio token...',
            'Saved Studio authentication could not be refreshed.',
            'Testing manually supplied token...',
            'Manual Studio authentication accepted.'
        )

        Remove-Item -LiteralPath $authPath -Force
        $bootstrapCollector = New-AuthStatusCollector
        function Get-FreshStudioToken {
            param([string]$ApiKey, [string]$RefreshToken)
            return @{ AccessToken = 'bootstrap-refreshed-token'; RefreshToken = 'bootstrap-refreshed-refresh' }
        }
        $script:TestClipboardText = '{"apiKey":"bootstrap-key","refreshToken":"bootstrap-refresh"}'
        $bootstrapResult = Get-RundotAccessToken `
            -StudioOrigin "https://example.test" `
            -ProjectId "project-test" `
            -AuthDir $testRoot `
            -AuthPath $authPath `
            -RundotCliSessionPath $missingSessionPath `
            -WriteStatus $bootstrapCollector.WriteStatus
        Assert-Equal 'bootstrap-refreshed-token' $bootstrapResult.AccessToken "bootstrap refresh should return a refreshed access token"
        Assert-AuthStatusSequence -Collector $bootstrapCollector -ExpectedTexts @(
            'Found RUN Studio bootstrap credentials in clipboard.',
            'Refreshing Studio token...',
            'Studio bootstrap authentication accepted.',
            'Refresh credentials saved securely for future exports.'
        )

        Remove-Item -LiteralPath $authPath -Force
        $bootstrapFailCollector = New-AuthStatusCollector
        function Get-FreshStudioToken {
            param([string]$ApiKey, [string]$RefreshToken)
            return $null
        }
        $script:TestClipboardText = '{"apiKey":"bootstrap-key","refreshToken":"bootstrap-refresh"}'
        $script:ManualPromptCount = 0
        $null = Get-RundotAccessToken `
            -StudioOrigin "https://example.test" `
            -ProjectId "project-test" `
            -AuthDir $testRoot `
            -AuthPath $authPath `
            -RundotCliSessionPath $missingSessionPath `
            -WriteStatus $bootstrapFailCollector.WriteStatus `
            -ReadManualToken { $script:ManualPromptCount++; return 'manual-after-bootstrap-fail' }
        Assert-AuthStatusSequence -Collector $bootstrapFailCollector -ExpectedTexts @(
            'Found RUN Studio bootstrap credentials in clipboard.',
            'Refreshing Studio token...',
            'Bootstrap refresh token could not be refreshed.',
            'Testing manually supplied token...',
            'Manual Studio authentication accepted.'
        )

        $clipboardCollector = New-AuthStatusCollector
        $script:TestClipboardText = $jwt
        $clipboardResult = Get-RundotAccessToken `
            -StudioOrigin "https://example.test" `
            -ProjectId "project-test" `
            -AuthDir $testRoot `
            -AuthPath $authPath `
            -RundotCliSessionPath $missingSessionPath `
            -WriteStatus $clipboardCollector.WriteStatus
        Assert-Equal $jwt $clipboardResult.AccessToken "clipboard bearer should be accepted"
        Assert-AuthStatusSequence -Collector $clipboardCollector -ExpectedTexts @(
            'Found Studio bearer token in clipboard.',
            'Testing it against Studio...',
            'Clipboard authentication accepted.'
        )
        Assert-AuthStatusContainsNoSecret -Collector $clipboardCollector -Secret $jwt

        $clipboardRejectCollector = New-AuthStatusCollector
        $script:ManifestAcceptTokens = @{ $jwt = $false }
        $script:TestClipboardText = $jwt
        $script:ManualPromptCount = 0
        $null = Get-RundotAccessToken `
            -StudioOrigin "https://example.test" `
            -ProjectId "project-test" `
            -AuthDir $testRoot `
            -AuthPath $authPath `
            -RundotCliSessionPath $missingSessionPath `
            -WriteStatus $clipboardRejectCollector.WriteStatus `
            -ReadManualToken { $script:ManualPromptCount++; return 'manual-after-clipboard-reject' }
        Assert-AuthStatusSequence -Collector $clipboardRejectCollector -ExpectedTexts @(
            'Found Studio bearer token in clipboard.',
            'Testing it against Studio...',
            'Clipboard bearer token was rejected or expired.',
            'Testing manually supplied token...',
            'Manual Studio authentication accepted.'
        )

        $manualCollector = New-AuthStatusCollector
        $script:TestClipboardText = ''
        $script:ManualPromptCount = 0
        $manualResult = Get-RundotAccessToken `
            -StudioOrigin "https://example.test" `
            -ProjectId "project-test" `
            -AuthDir $testRoot `
            -AuthPath $authPath `
            -RundotCliSessionPath $missingSessionPath `
            -WriteStatus $manualCollector.WriteStatus `
            -ReadManualToken { $script:ManualPromptCount++; return 'manual-accepted-token' }
        Assert-Equal 'manual-accepted-token' $manualResult.AccessToken "manual bearer should be accepted"
        Assert-Equal 1 $script:ManualPromptCount "manual prompt should run once on success"
        Assert-AuthStatusSequence -Collector $manualCollector -ExpectedTexts @(
            'Testing manually supplied token...',
            'Manual Studio authentication accepted.'
        )
        Assert-AuthStatusContainsNoSecret -Collector $manualCollector -Secret 'manual-accepted-token'

        $rejectManualCollector = New-AuthStatusCollector
        $script:ManifestAcceptTokens = @{
            'bad-manual-token' = $false
            'good-manual-token' = $true
        }
        $script:TestClipboardText = ''
        $script:ManualPromptCount = 0
        $script:ManualPromptReturns = @('bad-manual-token', 'good-manual-token')
        $rejectManualResult = Get-RundotAccessToken `
            -StudioOrigin "https://example.test" `
            -ProjectId "project-test" `
            -AuthDir $testRoot `
            -AuthPath $authPath `
            -RundotCliSessionPath $missingSessionPath `
            -WriteStatus $rejectManualCollector.WriteStatus `
            -ReadManualToken { $script:ManualPromptCount++; return $script:ManualPromptReturns[$script:ManualPromptCount - 1] }
        Assert-Equal 'good-manual-token' $rejectManualResult.AccessToken "a second manual paste should succeed"
        Assert-Equal 2 $script:ManualPromptCount "rejected manual paste should prompt again"
        Assert-Equal 5 $rejectManualCollector.Lines.Count "rejected manual paste should emit five status lines"
        Assert-Equal 'Testing manually supplied token...' $rejectManualCollector.Lines[0].Text "first manual test line should match"
        Assert-Equal 'Host' $rejectManualCollector.Lines[0].Kind "first manual test line should use the host stream"
        Assert-Equal 'Studio rejected that bearer token.' $rejectManualCollector.Lines[1].Text "manual rejection warning should match"
        Assert-Equal 'Warning' $rejectManualCollector.Lines[1].Kind "first manual rejection should use the warning stream"
        Assert-Equal 'It may be expired. Try a fresh token.' $rejectManualCollector.Lines[2].Text "manual rejection hint should match"
        Assert-Equal 'Warning' $rejectManualCollector.Lines[2].Kind "second manual rejection line should use the warning stream"
        Assert-Equal 'Testing manually supplied token...' $rejectManualCollector.Lines[3].Text "second manual test line should match"
        Assert-Equal 'Manual Studio authentication accepted.' $rejectManualCollector.Lines[4].Text "accepted manual line should match"

        $emptyPasteFailed = $false
        $script:TestClipboardText = ''
        $script:ManualPromptCount = 0
        try {
            $null = Get-RundotAccessToken `
                -StudioOrigin "https://example.test" `
                -ProjectId "project-test" `
                -AuthDir $testRoot `
                -AuthPath $authPath `
                -RundotCliSessionPath $missingSessionPath `
                -ReadManualToken { $script:ManualPromptCount++; return $null }
        }
        catch {
            $emptyPasteFailed = $true
            Assert-Equal 'No Studio authentication was supplied.' $_.Exception.Message "empty manual paste should fail closed"
        }
        Assert-True $emptyPasteFailed "empty manual paste should throw"
        Assert-Equal 1 $script:ManualPromptCount "empty manual paste should still invoke the prompt callback once"

        $noPromptFailed = $false
        $script:TestClipboardText = ''
        $script:ManualPromptCount = 0
        try {
            $null = Get-RundotAccessToken `
                -StudioOrigin "https://example.test" `
                -ProjectId "project-test" `
                -AuthDir $testRoot `
                -AuthPath $authPath `
                -RundotCliSessionPath $missingSessionPath
        }
        catch {
            $noPromptFailed = $true
            Assert-Equal 'No Studio authentication was supplied.' $_.Exception.Message "missing manual callback should fail closed"
        }
        Assert-True $noPromptFailed "missing manual callback should throw when no automatic auth exists"
        Assert-Equal 0 $script:ManualPromptCount "missing manual callback must not invoke a prompt"
    }
    catch [System.Security.Cryptography.CryptographicException] {
        Write-Host "SKIP: DPAPI is unavailable in this non-interactive test host."
    }

    $corruptCollector = New-AuthStatusCollector
    [IO.File]::WriteAllText($authPath, 'not-json')
    $null = Load-StudioAuth -AuthPath $authPath -WriteStatus $corruptCollector.WriteStatus
    Assert-Equal 2 $corruptCollector.Lines.Count "corrupt saved auth should emit two warning lines"
    Assert-Equal 'Saved Studio authentication could not be loaded.' $corruptCollector.Lines[0].Text "corrupt saved auth first warning should match"
    Assert-Equal 'Warning' $corruptCollector.Lines[0].Kind "corrupt saved auth first line should use the warning stream"
    Assert-Equal 'Warning' $corruptCollector.Lines[1].Kind "corrupt saved auth exception should use the warning stream"
    foreach ($line in $corruptCollector.Lines) {
        Assert-True (-not $line.Text.Contains($authPath)) "corrupt saved auth warnings must not echo the auth path"
    }
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
