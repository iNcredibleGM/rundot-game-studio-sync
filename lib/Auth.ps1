# Shared RUN Studio authentication helpers.
# RemoteApi.ps1 must be dot-sourced first for token validation.

function Get-RundotCliSession {
    param(
        [Parameter(Mandatory)]
        [string]$RundotCliSessionPath
    )

    if (-not (Test-Path $RundotCliSessionPath)) {
        return $null
    }

    try {
        $session = Get-Content $RundotCliSessionPath -Raw | ConvertFrom-Json
        $accessToken = [string]$session.accessToken

        if ([string]::IsNullOrWhiteSpace($accessToken)) {
            return $null
        }

        return @{
            AccessToken         = $accessToken
            ExpiresAtUnixTimeMs = $session.expiresAtUnixTimeMs
        }
    }
    catch {
        return $null
    }
}


function Test-RundotCliTokenFresh {
    param(
        [Parameter(Mandatory)]
        [string]$AccessToken,

        $ExpiresAtUnixTimeMs
    )

    $now = [DateTimeOffset]::UtcNow
    $safetyWindow = [TimeSpan]::FromMinutes(5)

    if ($null -ne $ExpiresAtUnixTimeMs) {
        try {
            $expiresMs = [int64]$ExpiresAtUnixTimeMs

            if ($expiresMs -gt 0) {
                $expires = [DateTimeOffset]::FromUnixTimeMilliseconds($expiresMs)
                return ($expires - $now) -gt $safetyWindow
            }
        }
        catch {
            # Fall through to the JWT expiry claim.
        }
    }

    try {
        $parts = $AccessToken.Split('.')

        if ($parts.Count -lt 2) {
            return $false
        }

        $payload = $parts[1].Replace('-', '+').Replace('_', '/')

        switch ($payload.Length % 4) {
            2 { $payload += '==' }
            3 { $payload += '=' }
        }

        $payloadBytes = [Convert]::FromBase64String($payload)
        $claims = [System.Text.Encoding]::UTF8.GetString($payloadBytes) |
            ConvertFrom-Json

        if ($null -eq $claims.exp) {
            return $false
        }

        $expires = [DateTimeOffset]::FromUnixTimeSeconds([int64]$claims.exp)
        return ($expires - $now) -gt $safetyWindow
    }
    catch {
        return $false
    }
}


function Save-StudioAuth {
    param(
        [Parameter(Mandatory)]
        [string]$AuthDir,

        [Parameter(Mandatory)]
        [string]$AuthPath,

        [Parameter(Mandatory)]
        [string]$ApiKey,

        [Parameter(Mandatory)]
        [string]$RefreshToken
    )

    New-Item -ItemType Directory -Force -Path $AuthDir | Out-Null

    $secureRefreshToken = ConvertTo-SecureString $RefreshToken -AsPlainText -Force
    $encryptedRefreshToken = ConvertFrom-SecureString $secureRefreshToken
    $authObject = [ordered]@{
        version               = 1
        apiKey                = $ApiKey
        encryptedRefreshToken = $encryptedRefreshToken
    }
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($AuthPath, ($authObject | ConvertTo-Json), $utf8NoBom)
}


function Write-RundotAuthStatus {
    param(
        $WriteStatus,

        [AllowEmptyString()]
        [string]$Text,

        [ValidateSet('Host', 'Warning')]
        [string]$Kind = 'Host'
    )

    if ($null -eq $WriteStatus) { return }
    & $WriteStatus -Text $Text -Kind $Kind
}


function Load-StudioAuth {
    param(
        [Parameter(Mandatory)]
        [string]$AuthPath,

        [scriptblock]$WriteStatus = $null
    )

    if (-not (Test-Path $AuthPath)) {
        return $null
    }

    try {
        $saved = Get-Content $AuthPath -Raw | ConvertFrom-Json

        if (-not $saved.apiKey -or -not $saved.encryptedRefreshToken) {
            return $null
        }

        $secureRefreshToken = ConvertTo-SecureString ([string]$saved.encryptedRefreshToken)
        $refreshToken = [System.Net.NetworkCredential]::new("", $secureRefreshToken).Password

        if ([string]::IsNullOrWhiteSpace($refreshToken)) {
            return $null
        }

        return @{
            ApiKey       = [string]$saved.apiKey
            RefreshToken = $refreshToken
        }
    }
    catch {
        Write-RundotAuthStatus -WriteStatus $WriteStatus -Text "Saved Studio authentication could not be loaded." -Kind Warning
        Write-RundotAuthStatus -WriteStatus $WriteStatus -Text $_.Exception.Message -Kind Warning
        return $null
    }
}


function Get-FreshStudioToken {
    param(
        [Parameter(Mandatory)]
        [string]$ApiKey,

        [Parameter(Mandatory)]
        [string]$RefreshToken
    )

    try {
        $result = Invoke-RestMethod `
            -Uri "https://securetoken.googleapis.com/v1/token?key=$ApiKey" `
            -Method POST `
            -ContentType "application/x-www-form-urlencoded" `
            -Body @{ grant_type = "refresh_token"; refresh_token = $RefreshToken } `
            -ErrorAction Stop

        if (-not $result.id_token) {
            return $null
        }

        return @{
            AccessToken = [string]$result.id_token
            RefreshToken = if ($result.refresh_token) { [string]$result.refresh_token } else { $RefreshToken }
        }
    }
    catch {
        return $null
    }
}


function Get-TokenFromText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $authorizationMatch = [regex]::Match($Text, '(?i)authorization\s*:\s*Bearer\s+([A-Za-z0-9._~-]+)')
    if ($authorizationMatch.Success) {
        return $authorizationMatch.Groups[1].Value
    }

    $bearerMatch = [regex]::Match($Text, '(?i)\bBearer\s+([A-Za-z0-9._~-]+)')
    if ($bearerMatch.Success) {
        return $bearerMatch.Groups[1].Value
    }

    $jwtMatch = [regex]::Match($Text.Trim(), '^([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)$')
    if ($jwtMatch.Success) {
        return $jwtMatch.Groups[1].Value
    }

    return $null
}


function Get-BootstrapAuthFromText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    try {
        $parsed = $Text.Trim() | ConvertFrom-Json
        if ($parsed.apiKey -and $parsed.refreshToken) {
            return @{ ApiKey = [string]$parsed.apiKey; RefreshToken = [string]$parsed.refreshToken }
        }
    }
    catch {
        # Clipboard simply was not bootstrap JSON.
    }

    return $null
}


function Get-StudioManifestWithToken {
    param(
        [Parameter(Mandatory)][string]$StudioOrigin,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$AccessToken
    )

    try {
        return Get-RemoteProjectFileList -StudioOrigin $StudioOrigin -ProjectId $ProjectId -Headers @{
            Authorization = "Bearer $AccessToken"
            Accept        = "*/*"
        }
    }
    catch {
        return $null
    }
}


function Resolve-RundotBootstrapAccessToken {
    param(
        [string]$StudioOrigin,
        [string]$ProjectId,
        [string]$AuthDir,
        [string]$AuthPath,
        $Clipboard,
        $WriteStatus
    )

    $bootstrapAuth = Get-BootstrapAuthFromText $Clipboard
    if (-not $bootstrapAuth) { return $null }

    Write-RundotAuthStatus -WriteStatus $WriteStatus -Text "Found RUN Studio bootstrap credentials in clipboard."
    Write-RundotAuthStatus -WriteStatus $WriteStatus -Text "Refreshing Studio token..."
    $refreshed = Get-FreshStudioToken -ApiKey $bootstrapAuth.ApiKey -RefreshToken $bootstrapAuth.RefreshToken
    if (-not $refreshed) {
        Write-RundotAuthStatus -WriteStatus $WriteStatus -Text "Bootstrap refresh token could not be refreshed."
        return $null
    }

    $candidateManifest = Get-StudioManifestWithToken -StudioOrigin $StudioOrigin -ProjectId $ProjectId -AccessToken $refreshed.AccessToken
    if (-not $candidateManifest) {
        Write-RundotAuthStatus -WriteStatus $WriteStatus -Text "Bootstrap credentials produced a token,"
        Write-RundotAuthStatus -WriteStatus $WriteStatus -Text "but Studio rejected it."
        return $null
    }

    Save-StudioAuth -AuthDir $AuthDir -AuthPath $AuthPath -ApiKey $bootstrapAuth.ApiKey -RefreshToken $refreshed.RefreshToken
    Write-RundotAuthStatus -WriteStatus $WriteStatus -Text "Studio bootstrap authentication accepted."
    Write-RundotAuthStatus -WriteStatus $WriteStatus -Text "Refresh credentials saved securely for future exports."
    return @{
        AccessToken  = $refreshed.AccessToken
        Manifest     = $candidateManifest
        RefreshToken = $refreshed.RefreshToken
    }
}


function Resolve-RundotClipboardBearerAccessToken {
    param(
        [string]$StudioOrigin,
        [string]$ProjectId,
        $Clipboard,
        $WriteStatus
    )

    $clipboardToken = Get-TokenFromText $Clipboard
    if (-not $clipboardToken) { return $null }

    Write-RundotAuthStatus -WriteStatus $WriteStatus -Text "Found Studio bearer token in clipboard."
    Write-RundotAuthStatus -WriteStatus $WriteStatus -Text "Testing it against Studio..."
    $candidateManifest = Get-StudioManifestWithToken -StudioOrigin $StudioOrigin -ProjectId $ProjectId -AccessToken $clipboardToken
    if (-not $candidateManifest) {
        Write-RundotAuthStatus -WriteStatus $WriteStatus -Text "Clipboard bearer token was rejected or expired."
        return $null
    }

    Write-RundotAuthStatus -WriteStatus $WriteStatus -Text "Clipboard authentication accepted."
    return @{
        AccessToken  = $clipboardToken
        Manifest     = $candidateManifest
        RefreshToken = $null
    }
}


function Resolve-RundotManualAccessToken {
    param(
        [string]$StudioOrigin,
        [string]$ProjectId,
        $ReadManualToken,
        $WriteStatus
    )

    if ($null -eq $ReadManualToken) {
        throw "No Studio authentication was supplied."
    }

    while ($true) {
        $manualToken = & $ReadManualToken
        if ([string]::IsNullOrWhiteSpace($manualToken)) {
            throw "No Studio authentication was supplied."
        }

        Write-RundotAuthStatus -WriteStatus $WriteStatus -Text "Testing manually supplied token..."
        $candidateManifest = Get-StudioManifestWithToken -StudioOrigin $StudioOrigin -ProjectId $ProjectId -AccessToken $manualToken
        if ($candidateManifest) {
            Write-RundotAuthStatus -WriteStatus $WriteStatus -Text "Manual Studio authentication accepted."
            return @{
                AccessToken  = $manualToken
                Manifest     = $candidateManifest
                RefreshToken = $null
            }
        }

        Write-RundotAuthStatus -WriteStatus $WriteStatus -Text "Studio rejected that bearer token." -Kind Warning
        Write-RundotAuthStatus -WriteStatus $WriteStatus -Text "It may be expired. Try a fresh token." -Kind Warning
    }
}


function Get-RundotAccessToken {
    param(
        [Parameter(Mandatory)][string]$StudioOrigin,
        [Parameter(Mandatory)][string]$ProjectId,
        [string]$AuthDir = (Join-Path $env:APPDATA ".rundot"),
        [string]$AuthPath = (Join-Path $env:APPDATA ".rundot\studio-export.auth.json"),
        [string]$RundotCliSessionPath = (Join-Path $env:APPDATA ".rundot\prod.session.json"),
        [scriptblock]$WriteStatus = $null,
        [scriptblock]$ReadManualToken = $null
    )

    $token = $null
    $refreshToken = $null
    $manifest = $null
    $rundotCliSession = Get-RundotCliSession -RundotCliSessionPath $RundotCliSessionPath

    if ($rundotCliSession) {
        if (Test-RundotCliTokenFresh -AccessToken $rundotCliSession.AccessToken -ExpiresAtUnixTimeMs $rundotCliSession.ExpiresAtUnixTimeMs) {
            Write-RundotAuthStatus -WriteStatus $WriteStatus -Text "Found RUNdot CLI session."
            Write-RundotAuthStatus -WriteStatus $WriteStatus -Text "Testing fresh CLI authentication against Studio..."
            $candidateManifest = Get-StudioManifestWithToken -StudioOrigin $StudioOrigin -ProjectId $ProjectId -AccessToken $rundotCliSession.AccessToken
            if ($candidateManifest) {
                $token = $rundotCliSession.AccessToken
                $manifest = $candidateManifest
                Write-RundotAuthStatus -WriteStatus $WriteStatus -Text "RUNdot CLI authentication accepted."
            }
            else {
                Write-RundotAuthStatus -WriteStatus $WriteStatus -Text "RUNdot CLI authentication was rejected."
                Write-RundotAuthStatus -WriteStatus $WriteStatus -Text "Trying other authentication methods..."
            }
        }
        else {
            Write-RundotAuthStatus -WriteStatus $WriteStatus -Text "Found RUNdot CLI session, but its access token is expired or near expiry."
            Write-RundotAuthStatus -WriteStatus $WriteStatus -Text "Run ``rundot login`` to refresh it."
            Write-RundotAuthStatus -WriteStatus $WriteStatus -Text "Trying other authentication methods..."
        }
    }

    # Preserve v0.1.0 control flow: saved credentials are tried even after CLI success.
    $savedAuth = Load-StudioAuth -AuthPath $AuthPath -WriteStatus $WriteStatus
    if ($savedAuth) {
        Write-RundotAuthStatus -WriteStatus $WriteStatus -Text "Found saved RUN Studio authentication."
        Write-RundotAuthStatus -WriteStatus $WriteStatus -Text "Refreshing Studio token..."
        $refreshed = Get-FreshStudioToken -ApiKey $savedAuth.ApiKey -RefreshToken $savedAuth.RefreshToken
        if ($refreshed) {
            $candidateManifest = Get-StudioManifestWithToken -StudioOrigin $StudioOrigin -ProjectId $ProjectId -AccessToken $refreshed.AccessToken
            if ($candidateManifest) {
                $token = $refreshed.AccessToken
                $refreshToken = $refreshed.RefreshToken
                $manifest = $candidateManifest
                Save-StudioAuth -AuthDir $AuthDir -AuthPath $AuthPath -ApiKey $savedAuth.ApiKey -RefreshToken $refreshed.RefreshToken
                Write-RundotAuthStatus -WriteStatus $WriteStatus -Text "Saved Studio authentication accepted."
            }
            else {
                Write-RundotAuthStatus -WriteStatus $WriteStatus -Text "Saved Studio authentication was refreshed,"
                Write-RundotAuthStatus -WriteStatus $WriteStatus -Text "but Studio rejected the resulting token."
            }
        }
        else {
            Write-RundotAuthStatus -WriteStatus $WriteStatus -Text "Saved Studio authentication could not be refreshed."
        }
    }

    $clipboard = $null
    if (-not $token) {
        try { $clipboard = Get-Clipboard -Raw } catch { $clipboard = $null }
    }

    if (-not $token) {
        $bootstrapResult = Resolve-RundotBootstrapAccessToken -StudioOrigin $StudioOrigin -ProjectId $ProjectId -AuthDir $AuthDir -AuthPath $AuthPath -Clipboard $clipboard -WriteStatus $WriteStatus
        if ($bootstrapResult) {
            $token = $bootstrapResult.AccessToken
            $manifest = $bootstrapResult.Manifest
            $refreshToken = $bootstrapResult.RefreshToken
        }
    }

    if (-not $token) {
        $clipboardResult = Resolve-RundotClipboardBearerAccessToken -StudioOrigin $StudioOrigin -ProjectId $ProjectId -Clipboard $clipboard -WriteStatus $WriteStatus
        if ($clipboardResult) {
            $token = $clipboardResult.AccessToken
            $manifest = $clipboardResult.Manifest
        }
    }

    if (-not $token) {
        $manualResult = Resolve-RundotManualAccessToken -StudioOrigin $StudioOrigin -ProjectId $ProjectId -ReadManualToken $ReadManualToken -WriteStatus $WriteStatus
        $token = $manualResult.AccessToken
        $manifest = $manualResult.Manifest
    }

    return @{ AccessToken = $token; Manifest = $manifest; RefreshToken = $refreshToken }
}
