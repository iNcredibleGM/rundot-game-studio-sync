param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectId,

    [string]$OutDir = ".\game-studio-export",

    [switch]$IncludeThreads,

    [switch]$ForgetAuth
)

$ErrorActionPreference = "Stop"

# ============================================================================
# RUN Game Studio Project Exporter
#
# Exports the complete editable project filesystem from RUN Game Studio.
#
# Authentication priority:
#
#   1. Fresh official RUNdot CLI access token
#        %APPDATA%\.rundot\prod.session.json
#   2. Previously saved exporter Firebase refresh credentials
#        %APPDATA%\.rundot\studio-export.auth.json
#   3. Firebase bootstrap JSON found in clipboard
#   4. Studio bearer token found in clipboard:
#        - Copy as cURL (POSIX)
#        - Copy as cURL (Windows)
#        - authorization: Bearer ...
#        - Bearer ...
#        - raw JWT
#   5. Manual secure bearer-token paste
#
# Refresh tokens are stored encrypted with Windows DPAPI.
#
# Files:
#   GET /api/projects/<id>/files
#   GET /api/projects/<id>/file?path=<path>
#
# Optional thread archive (-IncludeThreads):
#   GET /api/projects/<id>/threads
#   GET /agents/chat-thread/<uid>:<projectId>:<threadId>/get-messages
#
# Text files are written as the exact UTF-8 representation returned by
# Game Studio, without BOM or newline normalization.
# ============================================================================


# ============================================================================
# Configuration
# ============================================================================

$StudioOrigin = "https://venus-studio-prod.series-ai.workers.dev"

$BaseUrl = "$StudioOrigin/api/projects/$ProjectId"

$AuthDir = Join-Path $env:APPDATA ".rundot"

$AuthPath = Join-Path $AuthDir "studio-export.auth.json"

$RundotCliSessionPath = Join-Path $env:APPDATA ".rundot\prod.session.json"

$OutDir = [System.IO.Path]::GetFullPath($OutDir)

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)


# ============================================================================
# Utility
# ============================================================================

function Write-Section {
    param([string]$Text)

    Write-Host ""
    Write-Host "=================================================="
    Write-Host $Text
    Write-Host "=================================================="
}


function Clear-SensitiveVariables {
    $script:Token = $null
    $script:RefreshToken = $null
    $script:clipboard = $null
    $script:rundotCliSession = $null
}


# Read an HTTP response as raw bytes and decode it explicitly as UTF-8.
#
# Windows PowerShell 5.1 can decode response bodies with the wrong character
# set when the server omits an explicit charset. Reading the bytes ourselves
# prevents UTF-8 emoji/symbols from turning into mojibake.
function Invoke-Utf8TextGet {
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    $request = [System.Net.HttpWebRequest]::Create($Uri)
    $request.Method = "GET"

    foreach ($key in $Headers.Keys) {
        switch -Regex ($key) {
            '^Accept$' {
                $request.Accept = [string]$Headers[$key]
                continue
            }
            default {
                $request.Headers[$key] = [string]$Headers[$key]
            }
        }
    }

    $httpResponse = $request.GetResponse()

    try {
        $stream = $httpResponse.GetResponseStream()
        $memory = New-Object System.IO.MemoryStream

        try {
            $stream.CopyTo($memory)
            $responseBytes = $memory.ToArray()
        }
        finally {
            $memory.Dispose()
            $stream.Dispose()
        }

        return [System.Text.Encoding]::UTF8.GetString($responseBytes)
    }
    finally {
        $httpResponse.Dispose()
    }
}


function Invoke-Utf8JsonGet {
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    $jsonText = Invoke-Utf8TextGet `
        -Uri $Uri `
        -Headers $Headers

    return $jsonText | ConvertFrom-Json
}


function Get-StudioUidFromToken {
    param(
        [Parameter(Mandatory)]
        [string]$AccessToken
    )

    try {
        $parts = $AccessToken.Split('.')

        if ($parts.Count -lt 2) {
            return $null
        }

        $payload = $parts[1].Replace('-', '+').Replace('_', '/')

        switch ($payload.Length % 4) {
            2 { $payload += '==' }
            3 { $payload += '=' }
        }

        $payloadBytes = [Convert]::FromBase64String($payload)
        $payloadJson = [System.Text.Encoding]::UTF8.GetString($payloadBytes)
        $claims = $payloadJson | ConvertFrom-Json

        if ($claims.user_id) {
            return [string]$claims.user_id
        }

        if ($claims.sub) {
            return [string]$claims.sub
        }
    }
    catch {
        return $null
    }

    return $null
}


function Convert-UnixMillisecondsToIso {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    try {
        return [DateTimeOffset]::FromUnixTimeMilliseconds(
            [int64]$Value
        ).ToString("o")
    }
    catch {
        return [string]$Value
    }
}


function Convert-ThreadToMarkdown {
    param(
        [Parameter(Mandatory)]
        $Thread,

        [Parameter(Mandatory)]
        $Messages
    )

    $builder = New-Object System.Text.StringBuilder
    $title = if ($Thread.title) { [string]$Thread.title } else { [string]$Thread.id }

    [void]$builder.AppendLine("# $title")
    [void]$builder.AppendLine()
    [void]$builder.AppendLine("- Thread ID: ``$($Thread.id)``")

    $created = Convert-UnixMillisecondsToIso $Thread.createdAt
    $updated = Convert-UnixMillisecondsToIso $Thread.updatedAt
    $lastOpened = Convert-UnixMillisecondsToIso $Thread.lastOpenedAt

    if ($created) { [void]$builder.AppendLine("- Created: $created") }
    if ($updated) { [void]$builder.AppendLine("- Updated: $updated") }
    if ($lastOpened) { [void]$builder.AppendLine("- Last opened: $lastOpened") }

    [void]$builder.AppendLine()

    foreach ($message in @($Messages)) {
        $role = if ($message.role) { [string]$message.role } else { "message" }
        $roleLabel = switch ($role.ToLowerInvariant()) {
            "user" { "User" }
            "assistant" { "Assistant" }
            "system" { "System" }
            default { $role }
        }

        [void]$builder.AppendLine("## $roleLabel")

        if ($message.id) {
            [void]$builder.AppendLine()
            [void]$builder.AppendLine("Message ID: ``$($message.id)``")
        }

        foreach ($part in @($message.parts)) {
            [void]$builder.AppendLine()

            switch ([string]$part.type) {
                "text" {
                    [void]$builder.AppendLine([string]$part.text)
                }

                "reasoning" {
                    [void]$builder.AppendLine("### Reasoning")
                    [void]$builder.AppendLine()
                    [void]$builder.AppendLine([string]$part.text)
                }

                default {
                    $partType = if ($part.type) { [string]$part.type } else { "unknown" }
                    [void]$builder.AppendLine("### Part: $partType")
                    [void]$builder.AppendLine()
                    [void]$builder.AppendLine("````json")
                    [void]$builder.AppendLine(($part | ConvertTo-Json -Depth 100))
                    [void]$builder.AppendLine("````")
                }
            }
        }

        [void]$builder.AppendLine()
    }

    return $builder.ToString()
}


# ============================================================================
# RUNdot CLI session
# ============================================================================

# Safely load the official RUNdot CLI login session.
#
# Returns $null when the file is missing, unreadable, or does not contain a
# usable access token. Never prints token contents and never modifies the
# official CLI session file.
function Get-RundotCliSession {
    if (-not (Test-Path $RundotCliSessionPath)) {
        return $null
    }

    try {
        $session = Get-Content `
            $RundotCliSessionPath `
            -Raw |
            ConvertFrom-Json

        $accessToken = [string]$session.accessToken

        if ([string]::IsNullOrWhiteSpace($accessToken)) {
            return $null
        }

        return @{
            AccessToken          = $accessToken
            ExpiresAtUnixTimeMs  = $session.expiresAtUnixTimeMs
        }
    }
    catch {
        return $null
    }
}


# Determine whether a RUNdot CLI access token is fresh enough to attempt.
#
# This is only a freshness check. It does NOT verify the token signature.
# The Studio manifest request remains the authoritative validation.
#
# Prefers the session's expiresAtUnixTimeMs when valid. Falls back to
# decoding the JWT exp claim locally when needed.
function Test-RundotCliTokenFresh {
    param(
        [Parameter(Mandatory)]
        [string]$AccessToken,

        $ExpiresAtUnixTimeMs
    )

    $now = [DateTimeOffset]::UtcNow
    $safetyWindow = [TimeSpan]::FromMinutes(5)

    # Prefer the session's explicit expiry timestamp.
    if ($null -ne $ExpiresAtUnixTimeMs) {
        try {
            $expires = [DateTimeOffset]::FromUnixTimeMilliseconds(
                [int64]$ExpiresAtUnixTimeMs
            )

            return ($expires - $now) -gt $safetyWindow
        }
        catch {
            # Fall through to the JWT exp claim.
        }
    }

    # Fall back to decoding the JWT exp claim locally.
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
        $payloadJson = [System.Text.Encoding]::UTF8.GetString($payloadBytes)
        $claims = $payloadJson | ConvertFrom-Json

        if ($null -eq $claims.exp) {
            return $false
        }

        $expires = [DateTimeOffset]::FromUnixTimeSeconds(
            [int64]$claims.exp
        )

        return ($expires - $now) -gt $safetyWindow
    }
    catch {
        return $false
    }
}


# ============================================================================
# Saved Studio authentication
# ============================================================================

function Save-StudioAuth {
    param(
        [Parameter(Mandatory)]
        [string]$ApiKey,

        [Parameter(Mandatory)]
        [string]$RefreshToken
    )

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $AuthDir | Out-Null

    # ConvertFrom-SecureString without a supplied key uses Windows DPAPI.
    # The encrypted value is tied to the current Windows user.
    $secureRefreshToken = ConvertTo-SecureString `
        $RefreshToken `
        -AsPlainText `
        -Force

    $encryptedRefreshToken = ConvertFrom-SecureString `
        $secureRefreshToken

    $authObject = [ordered]@{
        version               = 1
        apiKey                = $ApiKey
        encryptedRefreshToken = $encryptedRefreshToken
    }

    $json = $authObject | ConvertTo-Json

    # This is not project source, so ordinary PowerShell JSON output is fine.
    [System.IO.File]::WriteAllText(
        $AuthPath,
        $json,
        $Utf8NoBom
    )
}


function Load-StudioAuth {

    if (-not (Test-Path $AuthPath)) {
        return $null
    }

    try {
        $saved = Get-Content `
            $AuthPath `
            -Raw |
            ConvertFrom-Json

        if (
            -not $saved.apiKey -or
            -not $saved.encryptedRefreshToken
        ) {
            return $null
        }

        $secureRefreshToken = ConvertTo-SecureString `
            ([string]$saved.encryptedRefreshToken)

        $refreshToken = [System.Net.NetworkCredential]::new(
            "",
            $secureRefreshToken
        ).Password

        if ([string]::IsNullOrWhiteSpace($refreshToken)) {
            return $null
        }

        return @{
            ApiKey       = [string]$saved.apiKey
            RefreshToken = $refreshToken
        }
    }
    catch {
        Write-Warning "Saved Studio authentication could not be loaded."
        Write-Warning $_.Exception.Message

        return $null
    }
}


if ($ForgetAuth) {

    if (Test-Path $AuthPath) {
        Remove-Item $AuthPath -Force
        Write-Host "Removed saved Studio authentication:"
        Write-Host "  $AuthPath"
    }
    else {
        Write-Host "No saved Studio authentication exists."
    }

    exit 0
}


# ============================================================================
# Firebase token refresh
# ============================================================================

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
            -Body @{
                grant_type    = "refresh_token"
                refresh_token = $RefreshToken
            } `
            -ErrorAction Stop

        if (-not $result.id_token) {
            return $null
        }

        return @{
            AccessToken = [string]$result.id_token

            RefreshToken = if ($result.refresh_token) {
                [string]$result.refresh_token
            }
            else {
                $RefreshToken
            }
        }
    }
    catch {
        return $null
    }
}


# ============================================================================
# Clipboard authentication parsing
# ============================================================================

function Get-TokenFromText {
    param(
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }


    # Handles:
    #
    #   authorization: Bearer eyJ...
    #
    # POSIX cURL:
    #
    #   -H 'authorization: Bearer eyJ...'
    #
    # Windows cURL:
    #
    #   -H "authorization: Bearer eyJ..."
    #
    $authorizationMatch = [regex]::Match(
        $Text,
        '(?i)authorization\s*:\s*Bearer\s+([A-Za-z0-9._~-]+)'
    )

    if ($authorizationMatch.Success) {
        return $authorizationMatch.Groups[1].Value
    }


    # Handles:
    #
    #   Bearer eyJ...
    #
    $bearerMatch = [regex]::Match(
        $Text,
        '(?i)\bBearer\s+([A-Za-z0-9._~-]+)'
    )

    if ($bearerMatch.Success) {
        return $bearerMatch.Groups[1].Value
    }


    # Handles raw JWT only.
    $jwtMatch = [regex]::Match(
        $Text.Trim(),
        '^([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)$'
    )

    if ($jwtMatch.Success) {
        return $jwtMatch.Groups[1].Value
    }


    return $null
}


function Get-BootstrapAuthFromText {
    param(
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    try {
        $parsed = $Text.Trim() | ConvertFrom-Json

        if (
            $parsed.apiKey -and
            $parsed.refreshToken
        ) {
            return @{
                ApiKey       = [string]$parsed.apiKey
                RefreshToken = [string]$parsed.refreshToken
            }
        }
    }
    catch {
        # Clipboard simply wasn't bootstrap JSON.
    }

    return $null
}


# ============================================================================
# Studio token validation
# ============================================================================

function Get-StudioManifestWithToken {
    param(
        [Parameter(Mandatory)]
        [string]$AccessToken
    )

    $headers = @{
        Authorization = "Bearer $AccessToken"
        Accept        = "*/*"
    }

    try {
        return Invoke-Utf8JsonGet `
            -Uri "$BaseUrl/files" `
            -Headers $headers
    }
    catch {
        return $null
    }
}


# ============================================================================
# Manual bearer fallback
# ============================================================================

function Read-ManualBearerToken {

    Write-Host ""
    Write-Host "No usable automatic Studio authentication was found."
    Write-Host ""
    Write-Host "You can paste a fresh Studio bearer token."
    Write-Host "The token will not be displayed."
    Write-Host ""

    $secureToken = Read-Host `
        "Bearer token" `
        -AsSecureString

    if ($null -eq $secureToken) {
        return $null
    }

    $plainText = [System.Net.NetworkCredential]::new(
        "",
        $secureToken
    ).Password

    if ([string]::IsNullOrWhiteSpace($plainText)) {
        return $null
    }

    $parsedToken = Get-TokenFromText $plainText

    if ($parsedToken) {
        return $parsedToken
    }

    return $plainText.Trim()
}


# ============================================================================
# Resolve authentication
# ============================================================================

Write-Section "RUN Studio authentication"

$Token = $null
$RefreshToken = $null
$manifest = $null


# ----------------------------------------------------------------------------
# 1. Fresh official RUNdot CLI access token
# ----------------------------------------------------------------------------

$rundotCliSession = Get-RundotCliSession

if ($rundotCliSession) {

    if (Test-RundotCliTokenFresh `
            -AccessToken $rundotCliSession.AccessToken `
            -ExpiresAtUnixTimeMs $rundotCliSession.ExpiresAtUnixTimeMs) {

        Write-Host "Found RUNdot CLI session."
        Write-Host "Testing fresh CLI authentication against Studio..."

        $candidateManifest = Get-StudioManifestWithToken `
            $rundotCliSession.AccessToken

        if ($candidateManifest) {

            $Token = $rundotCliSession.AccessToken
            $manifest = $candidateManifest

            Write-Host "RUNdot CLI authentication accepted."
        }
        else {
            Write-Host "RUNdot CLI authentication was rejected."
            Write-Host "Trying other authentication methods..."
        }
    }
    else {
        Write-Host "Found RUNdot CLI session, but its access token is expired or near expiry."
        Write-Host "Run ``rundot login`` to refresh it."
        Write-Host "Trying other authentication methods..."
    }
}


# ----------------------------------------------------------------------------
# 2. Previously saved Firebase refresh token
# ----------------------------------------------------------------------------

$savedAuth = Load-StudioAuth

if ($savedAuth) {

    Write-Host "Found saved RUN Studio authentication."
    Write-Host "Refreshing Studio token..."

    $refreshed = Get-FreshStudioToken `
        -ApiKey $savedAuth.ApiKey `
        -RefreshToken $savedAuth.RefreshToken

    if ($refreshed) {

        $candidateManifest = Get-StudioManifestWithToken `
            $refreshed.AccessToken

        if ($candidateManifest) {

            $Token = $refreshed.AccessToken
            $RefreshToken = $refreshed.RefreshToken
            $manifest = $candidateManifest

            Save-StudioAuth `
                -ApiKey $savedAuth.ApiKey `
                -RefreshToken $refreshed.RefreshToken

            Write-Host "Saved Studio authentication accepted."
        }
        else {
            Write-Host "Saved Studio authentication was refreshed,"
            Write-Host "but Studio rejected the resulting token."
        }
    }
    else {
        Write-Host "Saved Studio authentication could not be refreshed."
    }
}


# ----------------------------------------------------------------------------
# Read clipboard once for remaining fallbacks
# ----------------------------------------------------------------------------

$clipboard = $null

if (-not $Token) {
    try {
        $clipboard = Get-Clipboard -Raw
    }
    catch {
        $clipboard = $null
    }
}


# ----------------------------------------------------------------------------
# 3. Bootstrap JSON from clipboard
#
# Expected:
#
# {
#   "apiKey": "...",
#   "refreshToken": "..."
# }
#
# ----------------------------------------------------------------------------

if (-not $Token) {

    $bootstrapAuth = Get-BootstrapAuthFromText $clipboard

    if ($bootstrapAuth) {

        Write-Host "Found RUN Studio bootstrap credentials in clipboard."
        Write-Host "Refreshing Studio token..."

        $refreshed = Get-FreshStudioToken `
            -ApiKey $bootstrapAuth.ApiKey `
            -RefreshToken $bootstrapAuth.RefreshToken

        if ($refreshed) {

            $candidateManifest = Get-StudioManifestWithToken `
                $refreshed.AccessToken

            if ($candidateManifest) {

                $Token = $refreshed.AccessToken
                $RefreshToken = $refreshed.RefreshToken
                $manifest = $candidateManifest

                Save-StudioAuth `
                    -ApiKey $bootstrapAuth.ApiKey `
                    -RefreshToken $refreshed.RefreshToken

                Write-Host "Studio bootstrap authentication accepted."
                Write-Host "Refresh credentials saved securely for future exports."
            }
            else {
                Write-Host "Bootstrap credentials produced a token,"
                Write-Host "but Studio rejected it."
            }
        }
        else {
            Write-Host "Bootstrap refresh token could not be refreshed."
        }
    }
}


# ----------------------------------------------------------------------------
# 5. Bearer token from clipboard
# ----------------------------------------------------------------------------

if (-not $Token) {

    $clipboardToken = Get-TokenFromText $clipboard

    if ($clipboardToken) {

        Write-Host "Found Studio bearer token in clipboard."
        Write-Host "Testing it against Studio..."

        $candidateManifest = Get-StudioManifestWithToken `
            $clipboardToken

        if ($candidateManifest) {

            $Token = $clipboardToken
            $manifest = $candidateManifest

            Write-Host "Clipboard authentication accepted."
        }
        else {
            Write-Host "Clipboard bearer token was rejected or expired."
        }
    }
}


# ----------------------------------------------------------------------------
# 6. Manual bearer-token fallback
# ----------------------------------------------------------------------------

while (-not $Token) {

    $manualToken = Read-ManualBearerToken

    if (-not $manualToken) {
        throw "No Studio authentication was supplied."
    }

    Write-Host "Testing manually supplied token..."

    $candidateManifest = Get-StudioManifestWithToken `
        $manualToken

    if ($candidateManifest) {

        $Token = $manualToken
        $manifest = $candidateManifest

        Write-Host "Manual Studio authentication accepted."
        break
    }

    Write-Warning "Studio rejected that bearer token."
    Write-Warning "It may be expired. Try a fresh token."
}


$Headers = @{
    Authorization = "Bearer $Token"
    Accept        = "*/*"
}


# ============================================================================
# Prepare destination
# ============================================================================

Write-Section "Project export"

New-Item `
    -ItemType Directory `
    -Force `
    -Path $OutDir | Out-Null


$files = @(
    $manifest.files |
        Where-Object {
            $_.type -eq "file"
        }
)


Write-Host "Project ID:"
Write-Host "  $ProjectId"
Write-Host ""

Write-Host "Files:"
Write-Host "  $($files.Count)"
Write-Host ""

Write-Host "Destination:"
Write-Host "  $OutDir"
Write-Host ""


# ============================================================================
# Counters
# ============================================================================

$written = 0

$requestFailures = 0
$binaryVerificationFailures = 0
$textVerificationFailures = 0

$textMetadataDifferences = 0


# ============================================================================
# Export files
# ============================================================================

foreach ($entry in $files) {

    $remotePath = [string]$entry.path

    $relativePath = `
        $remotePath.TrimStart("/") `
        -replace '/',
        [System.IO.Path]::DirectorySeparatorChar

    $localPath = Join-Path `
        $OutDir `
        $relativePath

    $parentDir = Split-Path `
        -Parent `
        $localPath

    if ($parentDir) {
        New-Item `
            -ItemType Directory `
            -Force `
            -Path $parentDir | Out-Null
    }


    try {

        Write-Host "GET $remotePath"

        $encodedPath = [System.Uri]::EscapeDataString(
            $remotePath
        )

        $response = Invoke-Utf8JsonGet `
            -Uri "$BaseUrl/file?path=$encodedPath" `
            -Headers $Headers


        # ====================================================================
        # Binary
        # ====================================================================

        if ($response.encoding -eq "base64") {

            $bytes = [Convert]::FromBase64String(
                [string]$response.content
            )

            [System.IO.File]::WriteAllBytes(
                $localPath,
                $bytes
            )

            $diskSize = [int64](
                Get-Item $localPath
            ).Length

            $apiSize = [int64]$response.size

            if ($diskSize -ne $apiSize) {

                Write-Warning (
                    "BINARY VERIFY FAILED: {0} api={1} disk={2}" -f `
                    $remotePath,
                    $apiSize,
                    $diskSize
                )

                $binaryVerificationFailures++
            }
            else {
                $written++
            }

            continue
        }


        # ====================================================================
        # UTF-8 text
        # ====================================================================

        if ($response.encoding -eq "utf8") {

            # The .NET string contains the newline characters exactly as
            # returned by Studio.
            #
            # We deliberately DO NOT use:
            #
            #   Set-Content
            #   Out-File
            #   Add-Content
            #
            # or any line-oriented PowerShell operation.
            #
            # Converting the complete returned string directly to UTF-8 bytes
            # avoids newline normalization and avoids adding a BOM.

            $text = [string]$response.content

            $bytes = $Utf8NoBom.GetBytes(
                $text
            )

            [System.IO.File]::WriteAllBytes(
                $localPath,
                $bytes
            )


            # ----------------------------------------------------------------
            # Exact text round-trip verification
            # ----------------------------------------------------------------

            $writtenBytes = [System.IO.File]::ReadAllBytes(
                $localPath
            )

            $roundTripText = $Utf8NoBom.GetString(
                $writtenBytes
            )

            if ($roundTripText -cne $text) {

                Write-Warning "TEXT VERIFY FAILED: $remotePath"

                $textVerificationFailures++

                continue
            }


            # ----------------------------------------------------------------
            # Explicit line-ending verification
            # ----------------------------------------------------------------

            $sourceCRLF = (
                [regex]::Matches(
                    $text,
                    "`r`n"
                )
            ).Count

            $diskCRLF = (
                [regex]::Matches(
                    $roundTripText,
                    "`r`n"
                )
            ).Count


            $sourceLFOnly = (
                [regex]::Matches(
                    $text,
                    "(?<!`r)`n"
                )
            ).Count

            $diskLFOnly = (
                [regex]::Matches(
                    $roundTripText,
                    "(?<!`r)`n"
                )
            ).Count


            if (
                ($sourceCRLF -ne $diskCRLF) -or
                ($sourceLFOnly -ne $diskLFOnly)
            ) {

                Write-Warning (
                    "LINE ENDING VERIFY FAILED: {0} " +
                    "source(CRLF={1},LF={2}) disk(CRLF={3},LF={4})" -f `
                    $remotePath,
                    $sourceCRLF,
                    $sourceLFOnly,
                    $diskCRLF,
                    $diskLFOnly
                )

                $textVerificationFailures++

                continue
            }


            # ----------------------------------------------------------------
            # Studio size metadata diagnostics
            #
            # We've empirically observed Studio's text size to correspond to
            # character count rather than UTF-8 byte count for Unicode-heavy
            # files.
            #
            # Therefore metadata byte differences do NOT constitute corruption
            # when exact round-trip verification succeeded.
            # ----------------------------------------------------------------

            $manifestSize = [int64]$entry.size
            $apiSize = [int64]$response.size
            $charCount = [int64]$text.Length
            $utf8ByteSize = [int64]$writtenBytes.Length


            if (
                ($manifestSize -ne $utf8ByteSize) -or
                ($apiSize -ne $utf8ByteSize)
            ) {

                Write-Host (
                    "  text verified; size metadata differs: " +
                    "manifest={0} api={1} chars={2} utf8-bytes={3}" -f `
                    $manifestSize,
                    $apiSize,
                    $charCount,
                    $utf8ByteSize
                )

                $textMetadataDifferences++
            }


            $written++

            continue
        }


        throw (
            "Unknown encoding '$($response.encoding)' " +
            "for $remotePath"
        )
    }
    catch {

        Write-Warning "FAILED: $remotePath"
        Write-Warning $_.Exception.Message

        $requestFailures++
    }
}


# ============================================================================
# Export Studio AI threads (optional)
# ============================================================================

$threadCount = 0
$threadExported = 0
$threadFailures = 0

if ($IncludeThreads) {

    Write-Section "Studio AI thread export"

    $StudioUid = Get-StudioUidFromToken $Token

    if (-not $StudioUid) {
        Write-Warning "Could not determine the Studio user ID from the Firebase token."
        Write-Warning "Thread export cannot continue, but project files were already exported."
        $threadFailures++
    }
    else {
        $threadRoot = Join-Path $OutDir ".rundot-studio-export\threads"
        $threadRawDir = Join-Path $threadRoot "raw"
        $threadMarkdownDir = Join-Path $threadRoot "markdown"

        New-Item -ItemType Directory -Force -Path $threadRawDir | Out-Null
        New-Item -ItemType Directory -Force -Path $threadMarkdownDir | Out-Null

        try {
            Write-Host "GET /api/projects/$ProjectId/threads"

            $threadIndexText = Invoke-Utf8TextGet `
                -Uri "$BaseUrl/threads" `
                -Headers $Headers

            $threadIndex = $threadIndexText | ConvertFrom-Json

            [System.IO.File]::WriteAllBytes(
                (Join-Path $threadRoot "index.json"),
                $Utf8NoBom.GetBytes($threadIndexText)
            )

            $threads = @($threadIndex.threads)
            $threadCount = $threads.Count

            Write-Host "Found $threadCount threads."
            Write-Host "Archive:"
            Write-Host "  $threadRoot"
            Write-Host ""

            foreach ($thread in $threads) {
                $threadId = [string]$thread.id

                try {
                    $threadKey = "${StudioUid}:${ProjectId}:${threadId}"
                    $threadUri = "$StudioOrigin/agents/chat-thread/$threadKey/get-messages"

                    Write-Host "GET thread $threadId"

                    # Keep the server response byte-for-byte equivalent after UTF-8
                    # decoding/re-encoding. This raw JSON is the canonical archive.
                    $messageJson = Invoke-Utf8TextGet `
                        -Uri $threadUri `
                        -Headers $Headers

                    $rawPath = Join-Path $threadRawDir "$threadId.json"

                    [System.IO.File]::WriteAllBytes(
                        $rawPath,
                        $Utf8NoBom.GetBytes($messageJson)
                    )

                    $messages = $messageJson | ConvertFrom-Json
                    $markdown = Convert-ThreadToMarkdown `
                        -Thread $thread `
                        -Messages $messages

                    $markdownPath = Join-Path $threadMarkdownDir "$threadId.md"

                    [System.IO.File]::WriteAllBytes(
                        $markdownPath,
                        $Utf8NoBom.GetBytes($markdown)
                    )

                    $threadExported++
                }
                catch {
                    Write-Warning "THREAD FAILED: $threadId"
                    Write-Warning $_.Exception.Message
                    $threadFailures++
                }
            }
        }
        catch {
            Write-Warning "THREAD INDEX FAILED"
            Write-Warning $_.Exception.Message
            $threadFailures++
        }
    }
}


# ============================================================================
# Results
# ============================================================================

Write-Section "Studio project export complete"

Write-Host ""

Write-Host "Files in manifest:          $($files.Count)"
Write-Host "Verified/written:           $written"

Write-Host "Request/write failures:     $requestFailures"

Write-Host "Binary verification failed: $binaryVerificationFailures"
Write-Host "Text verification failed:   $textVerificationFailures"

Write-Host "Text metadata differences:  $textMetadataDifferences"

if ($IncludeThreads) {
    Write-Host "Threads discovered:          $threadCount"
    Write-Host "Threads exported:            $threadExported"
    Write-Host "Thread export failures:      $threadFailures"
}

Write-Host ""

Write-Host "Destination:"
Write-Host "  $OutDir"

Write-Host ""


$totalFailures = `
    $requestFailures +
    $binaryVerificationFailures +
    $textVerificationFailures +
    $threadFailures


if ($totalFailures -eq 0) {

    Write-Host "SUCCESS: Every exported file passed content verification."

    if ($textMetadataDifferences -gt 0) {

        Write-Host ""
        Write-Host "Note:"
        Write-Host "  Studio reports character-oriented size metadata for some"
        Write-Host "  UTF-8 text files. Their exact contents and line endings"
        Write-Host "  were verified after writing."
    }

    $exitCode = 0
}
else {

    Write-Warning "Export completed with $totalFailures verification failure(s)."

    $exitCode = 1
}


# ============================================================================
# Remove sensitive values from script scope
# ============================================================================

Clear-SensitiveVariables

$Headers.Authorization = $null

exit $exitCode