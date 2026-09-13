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

. (Join-Path $PSScriptRoot "lib\RemoteApi.ps1")
. (Join-Path $PSScriptRoot "lib\Auth.ps1")
. (Join-Path $PSScriptRoot "lib\Paths.ps1")
. (Join-Path $PSScriptRoot "lib\Ignore.ps1")


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
    $script:authResult = $null
    $script:clipboard = $null
    $script:rundotCliSession = $null
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
# Forget saved authentication
# ============================================================================

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
# Resolve authentication
# ============================================================================

Write-Section "RUN Studio authentication"

$authResult = Get-RundotAccessToken `
    -StudioOrigin $StudioOrigin `
    -ProjectId $ProjectId `
    -AuthDir $AuthDir `
    -AuthPath $AuthPath `
    -RundotCliSessionPath $RundotCliSessionPath

$Token = $authResult.AccessToken
$manifest = $authResult.Manifest
$RefreshToken = $authResult.RefreshToken


$Headers = @{
    Authorization = "Bearer $Token"
    Accept        = "*/*"
}


# ============================================================================
# Prepare destination
# ============================================================================

Write-Section "Project export"

if (Test-Path -LiteralPath $OutDir) {
    Assert-LocalWorkspaceTreeSafe -WorkspaceRoot $OutDir
}

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

if ($files.Count -gt 0) {
    $remotePaths = @(
        $files |
            ForEach-Object {
                [string]$_.path
            }
    )

    Assert-SafeSyncPathSet -Paths $remotePaths

    foreach ($remotePathToCheck in $remotePaths) {
        $canonicalPath = ConvertTo-CanonicalSyncPath -Path $remotePathToCheck
        Assert-SyncPathRepresentable `
            -WorkspaceRoot $OutDir `
            -CanonicalPath $canonicalPath
    }
}


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
    $canonicalPath = ConvertTo-CanonicalSyncPath -Path $remotePath
    $localPath = ConvertTo-LocalFullPath `
        -WorkspaceRoot $OutDir `
        -CanonicalPath $canonicalPath

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

        $response = Get-RemoteProjectFile `
            -StudioOrigin $StudioOrigin `
            -ProjectId $ProjectId `
            -Path $remotePath `
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