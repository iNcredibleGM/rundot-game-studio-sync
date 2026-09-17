# Studio protocol probe: the reusable investigation harness behind
# docs/text-write-protocol.md (#14) and docs/binary-upload-protocol.md (#15).
#
# THIS FILE IS NOT PART OF THE PRODUCT.
#
# It is the only place in this repository that performs a Studio write. It
# exists because the write protocol is undocumented and has to be observed
# rather than read, and because rebuilding a probe from a prose description
# every time is how the #14 probe was lost.
#
# Why this is allowed to exist while the milestone bans write helpers:
#
#   tests/NoRemoteMutation.Tests.ps1 scans game-studio-sync.ps1,
#   game-studio-export.ps1, and lib/**/*.ps1 only. tools/** is deliberately
#   outside that set, so this file cannot smuggle a mutation into the product.
#   tests/StudioProbe.Tests.ps1 pins that: no product file may reference this
#   probe, and the probe may never be dot-sourced by one.
#
# Safety rules baked into this script:
#
#   - Nothing mutates without -ConfirmRemoteWrite. Without it the probe prints
#     the requests it would send and exits non-zero.
#   - Disposable Studio project only. Never point it at a real project.
#   - Overwrite cases only ever target a path the probe itself created, and
#     every one of them is restored and verified by SHA-256 afterwards.
#   - Binary creates cannot be deleted through the API (delete is #16 and is
#     banned), so they are listed for manual cleanup in the Studio UI.
#   - Tokens are never printed, logged, or written to evidence. Evidence holds
#     status codes, sizes, hashes, and redacted bodies only.

param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectId,

    [Parameter(Mandatory = $true)]
    [ValidateSet(
        # Salvaged from the #14 text investigation.
        'text-create',
        'text-overwrite',
        'text-version',
        'text-conditional',
        'text-idempotency',
        'text-failure',
        'text-concurrency-prepare',
        'text-concurrency-apply',
        'text-survey',
        # New in the #15 binary investigation.
        'binary-discover',
        'binary-create',
        'binary-collision',
        'binary-overwrite',
        'binary-idempotency',
        'binary-failure',
        'binary-survey',
        # Whole-investigation runners. These are the ones to use by hand: one
        # command per issue instead of seven.
        'run-text-all',
        'run-binary-all'
    )]
    [string]$Scenario,

    [string]$RepoRoot = '',

    [string]$StudioOrigin = 'https://venus-studio-prod.series-ai.workers.dev',

    [string]$OutDir = (Join-Path $env:TEMP 'rundot-probe-evidence'),

    # A bearer token, a JWT, or pasted DevTools text containing one. Never
    # logged. Exists so automation never blocks on an interactive prompt.
    [string]$AccessToken,

    # A file containing the same thing. Preferred over -AccessToken: the token
    # never reaches a shell history or a chat transcript.
    [string]$AccessTokenPath,

    # Refuse the interactive fallback instead of prompting.
    [switch]$NoInteractiveAuth,

    # The one switch that permits a remote write.
    [switch]$ConfirmRemoteWrite
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is not bound while the param block is evaluated, so the default
# repo root is resolved here instead.
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}

if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'lib\RemoteApi.ps1'))) {
    throw "RepoRoot '$RepoRoot' does not look like the sync repository (lib\RemoteApi.ps1 is missing)."
}


# Every path this probe creates lives under this prefix, and Assert-ProbeOwnedPath
# refuses to write anywhere else.
$script:ProbeDir = '/sync-probe'
$script:ProbeRootPath = "$($script:ProbeDir)/probe.txt"
$script:ProbeNestedPath = "$($script:ProbeDir)/nested/deep.txt"

$script:LogPath = $null
$script:EvidencePath = $null
$script:Evidence = New-Object 'System.Collections.Generic.List[object]'
$script:CreatedPaths = New-Object 'System.Collections.Generic.List[string]'
$script:Unrestored = New-Object 'System.Collections.Generic.List[string]'
$script:Token = $null
$script:Headers = $null
$script:WriteEnabled = $false

. (Join-Path $RepoRoot 'lib\Paths.ps1')
. (Join-Path $RepoRoot 'lib\Hashing.ps1')
. (Join-Path $RepoRoot 'lib\Workspace.ps1')
. (Join-Path $RepoRoot 'lib\RemoteApi.ps1')
. (Join-Path $RepoRoot 'lib\Snapshot.ps1')
. (Join-Path $RepoRoot 'lib\Auth.ps1')

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$script:LogPath = Join-Path $OutDir ("probe-{0}.log" -f $Scenario)
$script:EvidencePath = Join-Path $OutDir ("probe-{0}.json" -f $Scenario)


# ---------------------------------------------------------------------------
# Logging and evidence
# ---------------------------------------------------------------------------

function Write-ProbeLog {
    param([string]$Text)

    Write-Host $Text
    Add-Content -LiteralPath $script:LogPath -Value $Text -Encoding UTF8
}

function Add-ProbeEvidence {
    param(
        [string]$Case,
        [string]$Status,
        [hashtable]$Data
    )

    $script:Evidence.Add([pscustomobject]@{
        case   = $Case
        status = $Status
        data   = $Data
    })
}

function ConvertTo-RedactedEvidence {
    # Evidence is meant to be quotable in a public issue, so file contents
    # never belong in it. Reduce any record that carries content to a length,
    # and keep everything else as-is.
    param($Value)

    if ($null -eq $Value) { return $null }

    # A hashtable's PSObject.Properties are Count/Keys/Values, not its keys,
    # so dictionaries are walked through Keys explicitly.
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in @($Value.Keys)) {
            if ($key -eq 'Content' -or $key -eq 'content') {
                $result['contentLength'] = ([string]$Value[$key]).Length
                continue
            }
            $result[$key] = ConvertTo-RedactedEvidence -Value $Value[$key]
        }
        return [pscustomobject]$result
    }

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $result = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.Name -eq 'Content' -or $property.Name -eq 'content') {
                $result['contentLength'] = ([string]$property.Value).Length
                continue
            }
            $result[$property.Name] = ConvertTo-RedactedEvidence -Value $property.Value
        }
        return [pscustomobject]$result
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = @()
        foreach ($item in $Value) { $items += ConvertTo-RedactedEvidence -Value $item }
        return $items
    }

    return $Value
}

function Save-ProbeEvidence {
    $redacted = @()
    foreach ($item in $script:Evidence) {
        $redacted += ConvertTo-RedactedEvidence -Value $item
    }
    ($redacted | ConvertTo-Json -Depth 12) |
        Set-Content -LiteralPath $script:EvidencePath -Encoding UTF8

    Write-ProbeLog "Evidence: $($script:EvidencePath)"
    Write-ProbeLog "Log:      $($script:LogPath)"

    if ($script:CreatedPaths.Count -gt 0) {
        Write-ProbeLog ''
        Write-ProbeLog 'CLEANUP - the probe created these paths; delete them in the Studio UI:'
        foreach ($path in @($script:CreatedPaths | Sort-Object -Unique)) {
            Write-ProbeLog "  $path"
        }
    }

    if ($script:Unrestored.Count -gt 0) {
        Write-ProbeLog ''
        Write-ProbeLog 'NOT RESTORED - these were overwritten and could not be put back:'
        foreach ($path in @($script:Unrestored | Sort-Object -Unique)) {
            Write-ProbeLog "  $path"
        }
    }
}


# ---------------------------------------------------------------------------
# Hashing and byte helpers
# ---------------------------------------------------------------------------

function Get-Sha256Hex {
    param([byte[]]$Bytes)

    if ($null -eq $Bytes) { return $null }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [System.BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Get-Utf8NoBomBytes {
    param([string]$Text)

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    return $utf8NoBom.GetBytes($Text)
}


# ---------------------------------------------------------------------------
# Path ownership
# ---------------------------------------------------------------------------

function Test-ProbeOwnedPath {
    # A destructive case may only touch a path this probe owns. Every path the
    # probe creates lives under /sync-probe.
    #
    # The comparison is on a segment boundary, not a raw string prefix: a
    # plain StartsWith would treat /sync-probe-other/x.txt as owned because it
    # shares the text prefix, which would let a case escape the probe directory.
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

    $canonical = ConvertTo-CanonicalSyncPath -Path $Path
    $owned = ConvertTo-CanonicalSyncPath -Path $script:ProbeDir

    if ([string]::Equals($canonical, $owned, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    return $canonical.StartsWith(
        ($owned + '/'),
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Assert-ProbeOwnedPath {
    param(
        [string]$Path,
        [string]$Case
    )

    if (Test-ProbeOwnedPath -Path $Path) { return }

    throw (
        "Refusing to write outside the probe directory. " +
        "Case '$Case' targeted '$Path', but only paths under " +
        "'$($script:ProbeDir)' may be modified. " +
        'Pass -TargetPath with a probe-owned path.'
    )
}


# ---------------------------------------------------------------------------
# Raw HTTP
#
# The product helpers are GET-only, so the probe owns its own request layer.
# This is the code the mutation grep is designed not to see, which is exactly
# why it lives here and nowhere else.
# ---------------------------------------------------------------------------

function Read-ProbeResponseBody {
    # A successful write can come back with no body at all, and the product
    # helper assumes one exists. Read defensively so an empty 200/204 does not
    # crash the probe after the request has already been sent.
    param($HttpResponse)

    if ($null -eq $HttpResponse) { return '' }

    $stream = $null
    try { $stream = $HttpResponse.GetResponseStream() }
    catch { return '' }

    if ($null -eq $stream) { return '' }

    $memory = New-Object System.IO.MemoryStream
    try {
        $stream.CopyTo($memory)
        $bytes = $memory.ToArray()
    }
    finally {
        $memory.Dispose()
        $stream.Dispose()
    }

    if ($null -eq $bytes -or $bytes.Length -eq 0) { return '' }

    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Select-ProbeHeaders {
    # Cloudflare fills responses with per-request tracing headers (CF-RAY,
    # Report-To, Nel) that say nothing about write semantics and bloat the
    # evidence. Keep only headers that could carry protocol meaning.
    param([hashtable]$Headers)

    $keep = @('ETag', 'If-Match', 'Content-Type', 'Content-Length', 'Location', 'Vary', 'Cache-Control')
    $result = [ordered]@{}
    if ($null -eq $Headers) { return $result }

    foreach ($key in $Headers.Keys) {
        foreach ($wanted in $keep) {
            if ([string]::Equals($key, $wanted, [System.StringComparison]::OrdinalIgnoreCase)) {
                $result[$key] = $Headers[$key]
                break
            }
        }
    }

    return $result
}

function Invoke-ProbeHttp {
    # One request, never throws on an HTTP status, and returns everything a
    # finding needs: status, body, selected headers, timing, transport error.
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers,
        [byte[]]$BodyBytes,
        [string]$ContentType,
        [int]$TimeoutMs = 120000
    )

    if ($null -eq $BodyBytes) { $BodyBytes = [byte[]]@() }

    $request = [System.Net.HttpWebRequest]::Create($Uri)
    $request.Method = $Method
    $request.AllowAutoRedirect = $false
    $request.Timeout = $TimeoutMs

    if ($null -ne $Headers) {
        foreach ($key in $Headers.Keys) {
            switch -Regex ($key) {
                '^Accept$' { $request.Accept = [string]$Headers[$key]; continue }
                '^Content-Type$' { $request.ContentType = [string]$Headers[$key]; continue }
                '^User-Agent$' { $request.UserAgent = [string]$Headers[$key]; continue }
                default { $request.Headers[$key] = [string]$Headers[$key] }
            }
        }
    }

    if (-not [string]::IsNullOrEmpty($ContentType)) {
        $request.ContentType = $ContentType
    }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $status = $null
    $bodyText = ''
    $responseHeaders = @{}
    $transportError = $null

    try {
        if ($Method -ne 'GET' -or $BodyBytes.Length -gt 0) {
            $request.ContentLength = $BodyBytes.Length
            $stream = $request.GetRequestStream()
            if ($BodyBytes.Length -gt 0) {
                $stream.Write($BodyBytes, 0, $BodyBytes.Length)
            }
            $stream.Dispose()
        }

        $response = $request.GetResponse()
        try {
            $status = [int]$response.StatusCode
            $bodyText = Read-ProbeResponseBody -HttpResponse $response
            foreach ($key in $response.Headers.AllKeys) {
                $responseHeaders[$key] = [string]$response.Headers[$key]
            }
        }
        finally {
            $response.Dispose()
        }
    }
    catch [System.Net.WebException] {
        $transportError = $_.Exception
        $webResponse = $_.Exception.Response
        if ($null -ne $webResponse) {
            try {
                $httpResponse = [System.Net.HttpWebResponse]$webResponse
                $status = [int]$httpResponse.StatusCode
                # An HTML or empty error body must not abort the probe: the
                # status code is the finding, the body is a bonus.
                try { $bodyText = Read-ProbeResponseBody -HttpResponse $httpResponse }
                catch { $bodyText = '<unreadable error body>' }
                try {
                    foreach ($key in $httpResponse.Headers.AllKeys) {
                        $responseHeaders[$key] = [string]$httpResponse.Headers[$key]
                    }
                }
                catch {
                    # Headers are a bonus too.
                }
            }
            finally {
                $webResponse.Dispose()
            }
        }
    }
    finally {
        $watch.Stop()
    }

    return [pscustomobject]@{
        Status          = $status
        BodyText        = $bodyText
        ResponseHeaders = (Select-ProbeHeaders -Headers $responseHeaders)
        ElapsedMs       = $watch.ElapsedMilliseconds
        TransportError  = $transportError
    }
}

function New-ProbeFileUrl {
    param([string]$Path)

    $encoded = [System.Uri]::EscapeDataString($Path)
    return "$StudioOrigin/api/projects/$ProjectId/file?path=$encoded"
}

function New-ProbeApiUrl {
    param([string]$RelativePath)

    return "$StudioOrigin$RelativePath"
}


# ---------------------------------------------------------------------------
# The write gate
#
# Every mutating helper calls this first. Without -ConfirmRemoteWrite the probe
# records what it would have sent and throws, so a mis-typed command line can
# never mutate a project.
# ---------------------------------------------------------------------------

function Assert-ProbeWriteAllowed {
    param(
        [Parameter(Mandatory)][string]$Case,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri
    )

    if ($script:WriteEnabled) { return }

    Add-ProbeEvidence -Case $Case -Status 'BLOCKED' -Data @{
        note = 'dry run: pass -ConfirmRemoteWrite to send this request'
        http = @{ method = $Method; uri = $Uri }
    }
    Write-ProbeLog "[BLOCKED] $Case would send $Method $Uri"

    throw (
        "Refusing to mutate Studio without -ConfirmRemoteWrite. " +
        "Case '$Case' would have sent $Method to $Uri."
    )
}


# ---------------------------------------------------------------------------
# Text write helper (the #14 route)
# ---------------------------------------------------------------------------

function New-JsonContentBody {
    param([string]$Text)

    $payload = @{ content = $Text } | ConvertTo-Json -Compress
    return (Get-Utf8NoBomBytes -Text $payload)
}

function Invoke-ProbeTextPut {
    param(
        [string]$Path,
        [byte[]]$ContentBytes,
        [hashtable]$ExtraHeaders,
        [string]$ContentType = 'application/json'
    )

    if ($null -eq $ContentBytes) { $ContentBytes = [byte[]]@() }

    $uri = New-ProbeFileUrl -Path $Path
    Assert-ProbeWriteAllowed -Case "text-put:$Path" -Method 'PUT' -Uri $uri

    $requestHeaders = @{}
    foreach ($key in $script:Headers.Keys) { $requestHeaders[$key] = $script:Headers[$key] }
    if ($null -ne $ExtraHeaders) {
        foreach ($key in $ExtraHeaders.Keys) { $requestHeaders[$key] = $ExtraHeaders[$key] }
    }

    return Invoke-ProbeHttp `
        -Method 'PUT' `
        -Uri $uri `
        -Headers $requestHeaders `
        -BodyBytes $ContentBytes `
        -ContentType $ContentType
}


# ---------------------------------------------------------------------------
# Read helpers (product GET routes, unchanged)
# ---------------------------------------------------------------------------

function Get-ProbeFileList {
    return Get-RemoteProjectFileList `
        -StudioOrigin $StudioOrigin `
        -ProjectId $ProjectId `
        -Headers $script:Headers
}

function Get-ProbeListedPaths {
    $list = Get-ProbeFileList
    $paths = @()
    foreach ($entry in @($list.files)) {
        if ($null -eq $entry) { continue }
        if ([string]$entry.type -ne 'file') { continue }
        $paths += [string]$entry.path
    }
    return $paths
}

function Get-ProbeFileRow {
    param([string]$Path)

    $list = Get-ProbeFileList
    $wanted = ConvertTo-CanonicalSyncPath -Path $Path
    foreach ($entry in @($list.files)) {
        if ($null -eq $entry) { continue }
        if ([string]$entry.type -ne 'file') { continue }
        $raw = [string]$entry.path
        if ((ConvertTo-CanonicalSyncPath -Path $raw) -eq $wanted) {
            return [pscustomobject]@{ Raw = $entry; RawPath = $raw }
        }
    }

    return $null
}

function Get-ProbeRowFingerprint {
    # Every scalar field the file list exposes for a row, so a finding can name
    # the identity fields without this script knowing them in advance.
    param($Row)

    if ($null -eq $Row) { return $null }

    $fields = [ordered]@{}
    foreach ($property in $Row.Raw.PSObject.Properties) {
        $value = $property.Value
        if ($null -eq $value) { continue }
        if ($value -is [System.Management.Automation.PSCustomObject]) { continue }
        if ($value -is [System.Array]) { continue }
        $fields[$property.Name] = [string]$value
    }

    return $fields
}

function Get-ProbeRead {
    param([string]$Path)

    $response = Get-RemoteProjectFile `
        -StudioOrigin $StudioOrigin `
        -ProjectId $ProjectId `
        -Path $Path `
        -Headers $script:Headers

    $bytes = ConvertFrom-RemoteFileContent -Response $response

    return [pscustomobject]@{
        Encoding  = [string]$response.encoding
        ByteCount = $bytes.Length
        Sha256    = (Get-Sha256Hex -Bytes $bytes)
        Bytes     = $bytes
        Content   = [string]$response.content
    }
}

function Get-ProbeReadOrNull {
    param([string]$Path)

    try { return Get-ProbeRead -Path $Path }
    catch { return $null }
}

function Get-ProbeRowOrNull {
    param([string]$Path)

    try { return Get-ProbeFileRow -Path $Path }
    catch { return $null }
}


# ---------------------------------------------------------------------------
# The safe round trip
#
# Salvaged from the #14 v2 probe. v1 overwrote README.md and then failed to
# restore it because a write response body can be empty. Every mutating case
# now goes through this: read the original bytes, write, observe, restore, and
# verify the restore by SHA-256.
# ---------------------------------------------------------------------------

function Invoke-ProbeRoundTrip {
    param(
        [string]$Case,
        [string]$Path,
        [byte[]]$ContentBytes,
        [hashtable]$ExtraHeaders,
        [string]$ContentType = 'application/json',
        [string]$Note = '',
        [switch]$SkipRestore
    )

    Assert-ProbeOwnedPath -Path $Path -Case $Case

    $original = Get-ProbeReadOrNull -Path $Path
    $rowBefore = Get-ProbeRowOrNull -Path $Path

    if ($null -eq $original -and -not $SkipRestore) {
        # A path that did not exist before cannot be restored by overwrite.
        # Track it so Save-ProbeEvidence prints a cleanup list.
        $script:CreatedPaths.Add($Path)
    }

    $response = Invoke-ProbeTextPut -Path $Path -ContentBytes $ContentBytes -ExtraHeaders $ExtraHeaders -ContentType $ContentType

    Start-Sleep -Milliseconds 300

    $afterRead = Get-ProbeReadOrNull -Path $Path
    $rowAfter = Get-ProbeRowOrNull -Path $Path

    Add-ProbeEvidence -Case $Case -Status 'PROBED' -Data @{
        note           = $Note
        path           = $Path
        existedBefore  = ($null -ne $original)
        bytesBefore    = if ($null -ne $original) { $original.ByteCount } else { $null }
        shaBefore      = if ($null -ne $original) { $original.Sha256 } else { $null }
        fieldsBefore   = Get-ProbeRowFingerprint -Row $rowBefore
        rawPathBefore  = if ($null -ne $rowBefore) { $rowBefore.RawPath } else { $null }
        sentBytes      = $ContentBytes.Length
        http           = @{
            status  = $response.Status
            body    = $response.BodyText
            headers = $response.ResponseHeaders
            elapsed = $response.ElapsedMs
            error   = if ($null -ne $response.TransportError) { [string]$response.TransportError.Message } else { $null }
        }
        listedAfter    = ($null -ne $rowAfter)
        rawPathAfter   = if ($null -ne $rowAfter) { $rowAfter.RawPath } else { $null }
        fieldsAfter    = Get-ProbeRowFingerprint -Row $rowAfter
        bytesAfter     = if ($null -ne $afterRead) { $afterRead.ByteCount } else { $null }
        shaAfter       = if ($null -ne $afterRead) { $afterRead.Sha256 } else { $null }
        encodingAfter  = if ($null -ne $afterRead) { $afterRead.Encoding } else { $null }
    }

    Write-ProbeLog ("[PROBED] {0} status={1} existedBefore={2} listedAfter={3} bytes={4}" -f `
        $Case, $response.Status, ($null -ne $original), ($null -ne $rowAfter), `
        $(if ($null -ne $afterRead) { $afterRead.ByteCount } else { '-' }))

    if ($SkipRestore) { return }
    if ($null -eq $original) { return }

    # Restore the exact original bytes. The project is disposable, but leaving
    # it as found keeps the evidence honest about what the probe touched.
    $restore = Invoke-ProbeTextPut `
        -Path $Path `
        -ContentBytes (New-JsonContentBody -Text ([string]$original.Content))

    Start-Sleep -Milliseconds 300

    $verify = Get-ProbeReadOrNull -Path $Path
    $restoredExactly = (
        $null -ne $verify -and
        [string]::Equals($verify.Sha256, $original.Sha256, [System.StringComparison]::OrdinalIgnoreCase)
    )

    Add-ProbeEvidence -Case ("$Case-restore") -Status 'PROBED' -Data @{
        note            = 'restored the original bytes after the case'
        path            = $Path
        http            = @{ status = $restore.Status; body = $restore.BodyText }
        originalSha     = $original.Sha256
        restoredSha     = if ($null -ne $verify) { $verify.Sha256 } else { $null }
        restoredExactly = $restoredExactly
    }

    if ($restoredExactly) {
        Write-ProbeLog ("[RESTORED] {0} byte-for-byte" -f $Case)
    }
    else {
        $script:Unrestored.Add($Path)
        Write-ProbeLog ("[UNRESTORED] {0} at {1} - restore failed; fix by hand" -f $Case, $Path)
    }
}


# ---------------------------------------------------------------------------
# Binary upload flow (#15)
#
# Three steps, all previously observed but never characterized:
#   1. POST /api/projects/{id}/upload-url
#   2. PUT raw bytes to the returned presigned object-storage URL
#   3. POST /api/projects/{id}/upload-adopt
#
# The bodies are not documented anywhere, so the discover scenario learns them
# from validation errors the same way #14 learned the text body. Nothing here
# guesses: an unknown field is reported as unknown.
# ---------------------------------------------------------------------------

function Get-BinaryProbeBytes {
    # A tiny valid PNG. Small, deterministic, and recognizable enough that a
    # round-trip check is meaningful without storing image data in evidence.
    param([int]$Variant = 0)

    # 1x1 PNG, then one byte of variation so two uploads are never identical
    # unless a case wants them to be.
    $base64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
    $bytes = [Convert]::FromBase64String($base64)
    if ($Variant -ne 0) {
        $bytes = $bytes + [byte]($Variant % 256)
    }
    return $bytes
}

function Get-BinaryProbeName {
    # Collision-suffix survey name. Unique per run so a leftover from a
    # previous run does not masquerade as a collision.
    param([string]$Suffix = '')

    $stamp = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    if ([string]::IsNullOrEmpty($Suffix)) {
        return "probe-$stamp.png"
    }
    return "probe-$stamp-$Suffix.png"
}

function Invoke-ProbeUploadUrlRequest {
    # Step 1. Returns the raw response; the caller records it.
    param(
        [string]$TargetPath,
        [hashtable]$Body,
        [string]$ContentType = 'application/json'
    )

    $uri = New-ProbeApiUrl -RelativePath "/api/projects/$ProjectId/upload-url"
    Assert-ProbeWriteAllowed -Case 'upload-url' -Method 'POST' -Uri $uri

    $bodyBytes = Get-Utf8NoBomBytes -Text ($Body | ConvertTo-Json -Compress -Depth 8)
    return Invoke-ProbeHttp `
        -Method 'POST' `
        -Uri $uri `
        -Headers $script:Headers `
        -BodyBytes $bodyBytes `
        -ContentType $ContentType
}

function Invoke-ProbeRawPut {
    # Step 2. Raw bytes to the presigned URL. This request is unauthenticated
    # by design: the URL carries its own signature.
    param(
        [string]$PresignedUrl,
        [byte[]]$Bytes,
        [string]$ContentType = 'image/png',
        [hashtable]$ExtraHeaders
    )

    Assert-ProbeWriteAllowed -Case 'presigned-put' -Method 'PUT' -Uri $PresignedUrl

    $headers = @{}
    if ($null -ne $ExtraHeaders) {
        foreach ($key in $ExtraHeaders.Keys) { $headers[$key] = $ExtraHeaders[$key] }
    }

    return Invoke-ProbeHttp `
        -Method 'PUT' `
        -Uri $PresignedUrl `
        -Headers $headers `
        -BodyBytes $Bytes `
        -ContentType $ContentType
}

function Invoke-ProbeUploadAdoptRequest {
    # Step 3. Binds the uploaded object to a project path.
    param(
        [hashtable]$Body,
        [string]$ContentType = 'application/json'
    )

    $uri = New-ProbeApiUrl -RelativePath "/api/projects/$ProjectId/upload-adopt"
    Assert-ProbeWriteAllowed -Case 'upload-adopt' -Method 'POST' -Uri $uri

    $bodyBytes = Get-Utf8NoBomBytes -Text ($Body | ConvertTo-Json -Compress -Depth 8)
    return Invoke-ProbeHttp `
        -Method 'POST' `
        -Uri $uri `
        -Headers $script:Headers `
        -BodyBytes $bodyBytes `
        -ContentType $ContentType
}

function Get-ProbePresignedUrl {
    # Pull the URL out of an upload-url response without assuming its field
    # name. Returns $null when none of the plausible names is present, so the
    # caller can record the real shape instead of crashing.
    param($Response)

    if ($null -eq $Response) { return $null }
    if ([string]::IsNullOrWhiteSpace([string]$Response.BodyText)) { return $null }

    try { $parsed = $Response.BodyText | ConvertFrom-Json }
    catch { return $null }

    foreach ($candidate in @('url', 'uploadUrl', 'upload_url', 'presignedUrl', 'presigned_url', 'signedUrl')) {
        $property = $parsed.PSObject.Properties[$candidate]
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }

    # Some shapes nest it under an object.
    foreach ($candidate in @('data', 'result', 'upload')) {
        $property = $parsed.PSObject.Properties[$candidate]
        if ($null -ne $property -and $null -ne $property.Value) {
            $nested = Get-ProbePresignedUrl -Response ([pscustomobject]@{ BodyText = ($property.Value | ConvertTo-Json -Compress -Depth 8) })
            if ($null -ne $nested) { return $nested }
        }
    }

    return $null
}

function Get-ProbeResponseFields {
    # The scalar field names in a JSON response body, for reporting an unknown
    # contract without dumping it.
    param($Response)

    if ($null -eq $Response) { return $null }
    if ([string]::IsNullOrWhiteSpace([string]$Response.BodyText)) { return $null }

    try { $parsed = $Response.BodyText | ConvertFrom-Json }
    catch { return $null }

    $fields = [ordered]@{}
    foreach ($property in $parsed.PSObject.Properties) {
        $value = $property.Value
        if ($null -eq $value) {
            $fields[$property.Name] = $null
            continue
        }
        if ($value -is [System.Management.Automation.PSCustomObject]) {
            $fields[$property.Name] = '<object>'
            continue
        }
        if ($value -is [System.Array]) {
            $fields[$property.Name] = '<array>'
            continue
        }
        $fields[$property.Name] = [string]$value
    }

    return $fields
}

function Invoke-ProbeBinaryUpload {
    # The whole three-step flow for one file. Records each step, and returns
    # the resulting project path the adopt step reported, if any.
    param(
        [string]$Case,
        [string]$FileName,
        [byte[]]$Bytes,
        [string]$ContentType = 'image/png',
        [string]$Note = '',
        [hashtable]$UploadUrlBody,
        [hashtable]$AdoptBodyOverride
    )

    $result = [ordered]@{
        case           = $Case
        fileName       = $FileName
        bytes          = $Bytes.Length
        sha256         = Get-Sha256Hex -Bytes $Bytes
        uploadUrl      = $null
        presigned      = $null
        adopt          = $null
        adoptedPath    = $null
        listedAfter    = $null
        listedPaths    = $null
    }

    # --- Step 1: ask for a presigned URL -------------------------------
    $uploadUrlBody = $UploadUrlBody
    if ($null -eq $uploadUrlBody) {
        $uploadUrlBody = @{ fileName = $FileName; path = "$($script:ProbeDir)/$FileName"; contentType = $ContentType }
    }

    $uploadUrlResponse = Invoke-ProbeUploadUrlRequest -Body $uploadUrlBody
    $result.uploadUrl = @{
        request  = $uploadUrlBody
        status   = $uploadUrlResponse.Status
        body     = $uploadUrlResponse.BodyText
        fields   = Get-ProbeResponseFields -Response $uploadUrlResponse
        headers  = $uploadUrlResponse.ResponseHeaders
        error    = if ($null -ne $uploadUrlResponse.TransportError) { [string]$uploadUrlResponse.TransportError.Message } else { $null }
    }
    Write-ProbeLog ("[PROBED] {0} upload-url status={1}" -f $Case, $uploadUrlResponse.Status)

    $presignedUrl = Get-ProbePresignedUrl -Response $uploadUrlResponse
    if ($null -eq $presignedUrl) {
        Write-ProbeLog ("[STOPPED] {0}: no presigned URL in the upload-url response; nothing was uploaded" -f $Case)
        Add-ProbeEvidence -Case $Case -Status 'STOPPED' -Data $result
        return $result
    }

    # --- Step 2: PUT the raw bytes -------------------------------------
    $rawPut = Invoke-ProbeRawPut -PresignedUrl $presignedUrl -Bytes $Bytes -ContentType $ContentType
    $result.presigned = @{
        status  = $rawPut.Status
        headers = $rawPut.ResponseHeaders
        body    = $rawPut.BodyText
        error   = if ($null -ne $rawPut.TransportError) { [string]$rawPut.TransportError.Message } else { $null }
    }
    Write-ProbeLog ("[PROBED] {0} presigned-put status={1}" -f $Case, $rawPut.Status)

    # --- Step 3: adopt --------------------------------------------------
    $adoptBody = $AdoptBodyOverride
    if ($null -eq $adoptBody) {
        $adoptBody = @{ fileName = $FileName; path = "$($script:ProbeDir)/$FileName" }
        # Carry through any object identity the upload-url response exposed.
        $parsedUpload = $null
        try { $parsedUpload = $uploadUrlResponse.BodyText | ConvertFrom-Json } catch { }
        if ($null -ne $parsedUpload) {
            foreach ($candidate in @('key', 'objectKey', 'object_key', 'uploadId', 'upload_id', 'id', 'token')) {
                $property = $parsedUpload.PSObject.Properties[$candidate]
                if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                    $adoptBody[$candidate] = [string]$property.Value
                }
            }
        }
    }

    $adoptResponse = Invoke-ProbeUploadAdoptRequest -Body $adoptBody
    $result.adopt = @{
        request = $adoptBody
        status  = $adoptResponse.Status
        body    = $adoptResponse.BodyText
        fields  = Get-ProbeResponseFields -Response $adoptResponse
        headers = $adoptResponse.ResponseHeaders
        error   = if ($null -ne $adoptResponse.TransportError) { [string]$adoptResponse.TransportError.Message } else { $null }
    }
    Write-ProbeLog ("[PROBED] {0} upload-adopt status={1}" -f $Case, $adoptResponse.Status)

    # Whatever the adopt response calls the final path, the authoritative
    # answer is what the project file list now contains.
    Start-Sleep -Milliseconds 400
    $paths = Get-ProbeListedPaths
    $result.listedPaths = $paths
    $result.listedAfter = @($paths | Where-Object { $_ -like "*$FileName*" })

    foreach ($path in $result.listedAfter) { $script:CreatedPaths.Add([string]$path) }

    Add-ProbeEvidence -Case $Case -Status 'PROBED' -Data $result
    return $result
}


# ---------------------------------------------------------------------------
# Authentication
#
# A supplied -AccessToken is used directly and validated by requesting the
# project manifest, the same authority the product uses. Otherwise the shared
# helper runs, but only when it cannot block: an expired CLI session with no
# saved credentials would prompt for a manual paste, and a probe that hangs is
# worse than one that fails.
# ---------------------------------------------------------------------------

Write-ProbeLog "Probe scenario: $Scenario"
Write-ProbeLog 'Project: <redacted>'

# Read the token from a file when one was given. This is the preferred path:
# the token never enters a shell history or a chat transcript.
if (-not [string]::IsNullOrWhiteSpace($AccessTokenPath)) {
    if (-not (Test-Path -LiteralPath $AccessTokenPath -PathType Leaf)) {
        throw "AccessTokenPath '$AccessTokenPath' does not exist."
    }

    $AccessToken = (Get-Content -LiteralPath $AccessTokenPath -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($AccessToken)) {
        throw "AccessTokenPath '$AccessTokenPath' is empty."
    }

    Write-ProbeLog 'Read a token from -AccessTokenPath (value not shown).'
}


# ---------------------------------------------------------------------------
# The early gate.
#
# This runs before authentication, so a missing -ConfirmRemoteWrite is refused
# without a network call and without needing credentials. That makes the
# safety property testable offline (tests/StudioProbe.Tests.ps1), which is the
# whole point of having it. The per-request Assert-ProbeWriteAllowed is the
# second layer, in case a future scenario forgets to route through a helper.
# ---------------------------------------------------------------------------
function Get-ProbeScenarioPlan {
    # What each scenario would send, so the refusal is informative rather than
    # just "no". Kept short on purpose.
    param([string]$Name)

    $plans = @{
        'text-create'              = @('PUT /file (new paths under /sync-probe)', 'PUT /file (relative path, expect 400)')
        'text-overwrite'           = @('PUT /file (existing probe-owned paths, restored after each case)')
        'text-version'             = @('PUT /file (probe-owned path, twice)')
        'text-conditional'         = @('PUT /file with If-Match / If-None-Match (probe-owned path, restored)')
        'text-idempotency'         = @('PUT /file (identical bytes, three times)')
        'text-failure'             = @('PUT /file (malformed bodies, reserved paths, 2,000,000-char boundary)')
        'text-concurrency-prepare' = @('PUT /file (writes a baseline a human then edits)')
        'text-concurrency-apply'   = @('PUT /file (sends stale bytes over the human edit)')
        'text-survey'              = @()
        'binary-discover'          = @('POST /upload-url (several candidate bodies)', 'POST /upload-adopt (several candidate bodies)')
        'binary-create'            = @('POST /upload-url', 'PUT presigned URL (raw bytes)', 'POST /upload-adopt', 'GET /file (read back)')
        'binary-collision'         = @('POST /upload-url + PUT + adopt, repeated with identical filenames and edge-case names')
        'binary-overwrite'         = @('POST /upload-url + PUT + adopt against an existing binary path', 'POST /upload-adopt (re-adopt)')
        'binary-idempotency'       = @('POST /upload-url + PUT + adopt, twice', 'PUT the same presigned URL twice')
        'binary-failure'           = @('POST /upload-adopt (unknown id)', 'POST /upload-url (bad bodies, no auth)', 'PUT presigned URL (wrong type, malformed URL)')
        'binary-survey'            = @()
        'run-text-all'             = @('The full #14 text investigation: create, overwrite, version, conditional, idempotency, failure, survey')
        'run-binary-all'           = @('The full #15 binary investigation: discover, create, collision, overwrite, idempotency, failure, survey')
    }

    if ($plans.ContainsKey($Name)) { return @($plans[$Name]) }
    return @()
}

if (-not $ConfirmRemoteWrite) {
    $planned = Get-ProbeScenarioPlan -Name $Scenario

    Write-ProbeLog ''
    Write-ProbeLog 'DRY RUN: -ConfirmRemoteWrite was not passed, so nothing was sent.'
    Write-ProbeLog ''
    if ($planned.Count -gt 0) {
        Write-ProbeLog 'This scenario would send:'
        foreach ($step in $planned) { Write-ProbeLog "  - $step" }
    }
    else {
        Write-ProbeLog 'This scenario is read-only; it would send GET requests only.'
    }
    Write-ProbeLog ''
    Write-ProbeLog 'Re-run with -ConfirmRemoteWrite against a DISPOSABLE project to send it.'

    Add-ProbeEvidence -Case 'probe-dry-run' -Status 'BLOCKED' -Data @{
        note     = 'no -ConfirmRemoteWrite; nothing was sent'
        scenario = $Scenario
        planned  = $planned
    }
    Save-ProbeEvidence

    throw 'Refusing to mutate Studio without -ConfirmRemoteWrite.'
}


if ([string]::IsNullOrWhiteSpace($AccessToken)) {
    $savedAuthPath = Join-Path $env:APPDATA '.rundot\studio-export.auth.json'
    $cliSessionPath = Join-Path $env:APPDATA '.rundot\prod.session.json'

    $savedAuth = Load-StudioAuth -AuthPath $savedAuthPath
    $cliSession = Get-RundotCliSession -RundotCliSessionPath $cliSessionPath

    $cliUsable = $false
    if ($null -ne $cliSession) {
        $cliUsable = Test-RundotCliTokenFresh `
            -AccessToken $cliSession.AccessToken `
            -ExpiresAtUnixTimeMs $cliSession.ExpiresAtUnixTimeMs
    }

    if (-not $cliUsable -and $null -eq $savedAuth -and $NoInteractiveAuth) {
        throw (
            'No non-interactive Studio authentication is available: the CLI ' +
            'session is expired or missing, and no saved refresh credentials ' +
            'exist. Run ''rundot login'', or pass -AccessToken.'
        )
    }
}

if (-not [string]::IsNullOrWhiteSpace($AccessToken)) {
    $parsed = Get-TokenFromText $AccessToken
    $script:Token = if ($parsed) { $parsed } else { $AccessToken.Trim() }

    $manifest = Get-StudioManifestWithToken `
        -StudioOrigin $StudioOrigin `
        -ProjectId $ProjectId `
        -AccessToken $script:Token

    if ($null -eq $manifest) {
        throw 'The supplied token was rejected by Studio for this project.'
    }

    Write-ProbeLog 'Supplied token accepted.'
}
else {
    $authResult = Get-RundotAccessToken `
        -StudioOrigin $StudioOrigin `
        -ProjectId $ProjectId `
        -AuthDir (Join-Path $env:APPDATA '.rundot') `
        -AuthPath (Join-Path $env:APPDATA '.rundot\studio-export.auth.json') `
        -RundotCliSessionPath (Join-Path $env:APPDATA '.rundot\prod.session.json')

    $script:Token = $authResult.AccessToken
    Write-ProbeLog 'Shared authentication accepted.'
}

$script:Headers = @{
    Authorization = "Bearer $($script:Token)"
    Accept        = '*/*'
}

# The early gate above already refused a dry run, so reaching here means the
# write gate is armed. Keep the second layer armed too.
$script:WriteEnabled = $true
Write-ProbeLog ''
Write-ProbeLog 'WARNING: -ConfirmRemoteWrite is set. This probe will mutate Studio.'
Write-ProbeLog 'DISPOSABLE PROJECT ONLY. Do not run this against a real project.'
Write-ProbeLog ''



# ---------------------------------------------------------------------------
# Text scenarios (salvaged from the #14 investigation)
# ---------------------------------------------------------------------------

function Invoke-ScenarioTextCreate {
    Invoke-ProbeRoundTrip -Case 'text-create-root-basic' -Path $script:ProbeRootPath `
        -ContentBytes (New-JsonContentBody -Text "probe line one`nprobe line two") `
        -Note 'PUT to a path that does not exist; 404 means create is unsolved'

    Invoke-ProbeRoundTrip -Case 'text-create-nested-newdir' -Path $script:ProbeNestedPath `
        -ContentBytes (New-JsonContentBody -Text 'nested probe content') `
        -Note 'PUT where the parent directory does not exist either'

    Invoke-ProbeRoundTrip -Case 'text-create-relative-path' -Path 'relative-probe.txt' `
        -ContentBytes (New-JsonContentBody -Text 'relative path probe') `
        -Note 'relative path; #14 found 400 before the body is read'

    Invoke-ProbeRoundTrip -Case 'text-create-empty-content' -Path "$($script:ProbeDir)/empty.txt" `
        -ContentBytes (New-JsonContentBody -Text '') `
        -Note 'empty content is a distinct state from a missing file'

    Invoke-ProbeRoundTrip -Case 'text-create-crlf' -Path "$($script:ProbeDir)/crlf.txt" `
        -ContentBytes (New-JsonContentBody -Text "a`r`nb`r`n") `
        -Note 'CRLF must not be normalized'

    $emoji = "emoji: $([char]0xD83D)$([char]0xDE00) end"
    Invoke-ProbeRoundTrip -Case 'text-create-emoji' -Path "$($script:ProbeDir)/emoji.txt" `
        -ContentBytes (New-JsonContentBody -Text $emoji) `
        -Note '4-byte UTF-8 sequence'

    $bom = "$([char]0xFEFF)bom prefixed content"
    Invoke-ProbeRoundTrip -Case 'text-create-bom-prefixed' -Path "$($script:ProbeDir)/bom.txt" `
        -ContentBytes (New-JsonContentBody -Text $bom) `
        -Note 'UTF-8 BOM preservation'

    Invoke-ProbeRoundTrip -Case 'text-create-no-trailing-newline' -Path "$($script:ProbeDir)/notrailing.txt" `
        -ContentBytes (New-JsonContentBody -Text 'no trailing newline') `
        -Note 'a trailing newline must not be added'

    # #14 found POST on the file route is 405. Re-confirm it, because a create
    # mechanism is still the open question for #17 and a new verb would be the
    # first place to look.
    $postUri = New-ProbeFileUrl -Path $script:ProbeRootPath
    Assert-ProbeWriteAllowed -Case 'text-create-post-file-route' -Method 'POST' -Uri $postUri
    $postResponse = Invoke-ProbeHttp `
        -Method 'POST' `
        -Uri $postUri `
        -Headers $script:Headers `
        -BodyBytes (New-JsonContentBody -Text 'post to create') `
        -ContentType 'application/json'
    Add-ProbeEvidence -Case 'text-create-post-file-route' -Status 'PROBED' -Data @{
        note = 'POST on the file route; 405 means the route is PUT-only'
        path = $script:ProbeRootPath
        http = @{ status = $postResponse.Status; body = $postResponse.BodyText }
    }
    Write-ProbeLog ("[PROBED] text-create-post-file-route status={0}" -f $postResponse.Status)

    # A directory-shaped path: is there a separate create for a folder?
    Invoke-ProbeRoundTrip -Case 'text-create-directory-shaped-path' -Path "$($script:ProbeDir)/nested" `
        -ContentBytes (New-JsonContentBody -Text '') `
        -Note 'PUT with a directory-shaped path'
}

function Invoke-ScenarioTextOverwrite {
    # Target must be an existing probe-owned file, so create it first.
    Invoke-ProbeRoundTrip -Case 'text-overwrite-baseline' -Path $script:ProbeRootPath `
        -ContentBytes (New-JsonContentBody -Text 'baseline for overwrite cases') `
        -Note 'establishes the overwrite target if it is missing'

    Invoke-ProbeRoundTrip -Case 'text-overwrite-different-content' -Path $script:ProbeRootPath `
        -ContentBytes (New-JsonContentBody -Text "overwritten content $([Guid]::NewGuid().ToString('N'))") `
        -Note 'replace in place, or collision rename?'

    $identical = "identical content probe $([Guid]::NewGuid().ToString('N'))"
    Invoke-ProbeRoundTrip -Case 'text-overwrite-identical-first' -Path "$($script:ProbeDir)/identical.txt" `
        -ContentBytes (New-JsonContentBody -Text $identical) `
        -Note 'first write of a byte-identical pair'
    Invoke-ProbeRoundTrip -Case 'text-overwrite-identical-second' -Path "$($script:ProbeDir)/identical.txt" `
        -ContentBytes (New-JsonContentBody -Text $identical) `
        -Note 'second write, byte-identical'

    Invoke-ProbeRoundTrip -Case 'text-overwrite-with-empty' -Path $script:ProbeRootPath `
        -ContentBytes (New-JsonContentBody -Text '') `
        -Note 'empty content overwrite'

    # Collision survey: a suffixed sibling would prove collision renaming on
    # the text route, which #14 found does not happen.
    $paths = Get-ProbeListedPaths
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($script:ProbeRootPath)
    $extension = [System.IO.Path]::GetExtension($script:ProbeRootPath)
    $suffixed = @($paths | Where-Object {
        $_ -match ('(?i)' + [regex]::Escape($stem) + '-\d+' + [regex]::Escape($extension) + '$')
    })

    Add-ProbeEvidence -Case 'text-overwrite-collision-survey' -Status 'OBSERVED' -Data @{
        note             = 'suffixed siblings would prove collision renaming on the text route'
        target           = $script:ProbeRootPath
        suffixedSiblings = $suffixed
        totalFiles       = $paths.Count
    }
    Write-ProbeLog ("[OBSERVED] text collision siblings: {0}" -f $(if ($suffixed.Count) { $suffixed -join ', ' } else { 'none' }))
}

function Invoke-ScenarioTextVersion {
    $target = "$($script:ProbeDir)/version.txt"

    Invoke-ProbeRoundTrip -Case 'text-version-baseline' -Path $target `
        -ContentBytes (New-JsonContentBody -Text 'version probe baseline') `
        -Note 'establishes the version target'

    $rowA = Get-ProbeRowOrNull -Path $target
    $first = Invoke-ProbeTextPut -Path $target `
        -ContentBytes (New-JsonContentBody -Text "version probe A $([Guid]::NewGuid().ToString('N'))")
    $rowB = Get-ProbeRowOrNull -Path $target

    Start-Sleep -Seconds 2

    $second = Invoke-ProbeTextPut -Path $target `
        -ContentBytes (New-JsonContentBody -Text "version probe B $([Guid]::NewGuid().ToString('N'))")
    $rowC = Get-ProbeRowOrNull -Path $target

    $fieldsA = Get-ProbeRowFingerprint -Row $rowB
    $fieldsB = Get-ProbeRowFingerprint -Row $rowC

    $changed = @()
    $allNames = @()
    if ($null -ne $fieldsA) { $allNames += @($fieldsA.Keys) }
    if ($null -ne $fieldsB) { $allNames += @($fieldsB.Keys) }
    foreach ($name in ($allNames | Sort-Object -Unique)) {
        $valueA = if ($null -ne $fieldsA -and $fieldsA.Contains($name)) { $fieldsA[$name] } else { $null }
        $valueB = if ($null -ne $fieldsB -and $fieldsB.Contains($name)) { $fieldsB[$name] } else { $null }
        if ($valueA -ne $valueB) {
            $changed += @{ field = $name; before = $valueA; after = $valueB }
        }
    }

    Add-ProbeEvidence -Case 'text-version-field-diff' -Status 'OBSERVED' -Data @{
        note             = 'fields that changed across two writes of the same path'
        changedFields    = $changed
        fieldsBefore     = $fieldsA
        fieldsAfter      = $fieldsB
        firstHttpStatus  = $first.Status
        secondHttpStatus = $second.Status
    }
    Write-ProbeLog ("[OBSERVED] version fields changed: {0}" -f (($changed | ForEach-Object { $_.field }) -join ', '))
}

function Invoke-ScenarioTextConditional {
    $target = "$($script:ProbeDir)/conditional.txt"

    Invoke-ProbeRoundTrip -Case 'text-conditional-baseline' -Path $target `
        -ContentBytes (New-JsonContentBody -Text 'conditional baseline') `
        -Note 'establishes the conditional target'

    $row = Get-ProbeRowOrNull -Path $target
    $fields = Get-ProbeRowFingerprint -Row $row

    $etag = $null
    $version = $null
    if ($null -ne $fields) {
        foreach ($candidate in @('etag', 'version', 'revision', 'id', 'hash', 'sha256', 'contentHash')) {
            if ($fields.Contains($candidate)) {
                if ($candidate -eq 'etag') { $etag = $fields[$candidate] }
                if ($candidate -eq 'version' -or $candidate -eq 'revision') { $version = $fields[$candidate] }
            }
        }
    }

    Add-ProbeEvidence -Case 'text-conditional-available-fields' -Status 'OBSERVED' -Data @{
        note             = 'candidate precondition fields on the listed row'
        etagCandidate    = $etag
        versionCandidate = $version
        allFields        = $fields
    }
    Write-ProbeLog ("[OBSERVED] etagCandidate=$etag versionCandidate=$version")

    if ($null -ne $etag) {
        Invoke-ProbeRoundTrip -Case 'text-conditional-if-match-current' -Path $target `
            -ContentBytes (New-JsonContentBody -Text 'if-match with the current etag') `
            -ExtraHeaders @{ 'If-Match' = $etag } `
            -Note "If-Match with the listed etag"
    }
    else {
        Add-ProbeEvidence -Case 'text-conditional-if-match-current' -Status 'SKIPPED' -Data @{
            note = 'no etag field was listed'
        }
        Write-ProbeLog '[SKIPPED] text-conditional-if-match-current: no etag field was listed'
    }

    Invoke-ProbeRoundTrip -Case 'text-conditional-if-match-wrong' -Path $target `
        -ContentBytes (New-JsonContentBody -Text 'if-match with a wrong etag') `
        -ExtraHeaders @{ 'If-Match' = '"definitely-not-the-current-etag"' } `
        -Note 'If-Match with a value that cannot match; 412 would mean enforcement'

    Invoke-ProbeRoundTrip -Case 'text-conditional-if-match-garbage' -Path $target `
        -ContentBytes (New-JsonContentBody -Text 'if-match garbage') `
        -ExtraHeaders @{ 'If-Match' = 'not-an-etag' } `
        -Note 'malformed If-Match'

    Invoke-ProbeRoundTrip -Case 'text-conditional-if-none-match-star' -Path $target `
        -ContentBytes (New-JsonContentBody -Text 'if-none-match star') `
        -ExtraHeaders @{ 'If-None-Match' = '*' } `
        -Note 'If-None-Match: * against an existing resource'
}

function Invoke-ScenarioTextIdempotency {
    $target = "$($script:ProbeDir)/idempotent.txt"
    $content = New-JsonContentBody -Text "idempotency probe $([Guid]::NewGuid().ToString('N'))"

    Invoke-ProbeRoundTrip -Case 'text-idempotency-baseline' -Path $target `
        -ContentBytes $content `
        -Note 'first write; the repeats below must converge on the same hash'

    for ($i = 2; $i -le 3; $i++) {
        $response = Invoke-ProbeTextPut -Path $target -ContentBytes $content
        Start-Sleep -Milliseconds 300
        $read = Get-ProbeReadOrNull -Path $target
        $row = Get-ProbeRowOrNull -Path $target

        Add-ProbeEvidence -Case "text-idempotency-repeat-$i" -Status 'PROBED' -Data @{
            note        = "repeat $i of a byte-identical PUT"
            http        = @{ status = $response.Status; body = $response.BodyText }
            bytesAfter  = if ($null -ne $read) { $read.ByteCount } else { $null }
            shaAfter    = if ($null -ne $read) { $read.Sha256 } else { $null }
            fieldsAfter = Get-ProbeRowFingerprint -Row $row
        }
        Write-ProbeLog ("[PROBED] text-idempotency-repeat-{0} status={1}" -f $i, $response.Status)
    }

    $paths = Get-ProbeListedPaths
    $matching = @($paths | Where-Object { $_ -like '*idempotent*' })
    Add-ProbeEvidence -Case 'text-idempotency-duplicate-survey' -Status 'OBSERVED' -Data @{
        note  = 'more than one matching path would mean a collision rename'
        paths = $matching
    }
    Write-ProbeLog ("[OBSERVED] idempotency paths: {0}" -f ($matching -join ', '))
}

function Invoke-ProbeFailureCase {
    param(
        [string]$Case,
        [string]$Path,
        [string]$RawBody,
        [string]$ContentType = 'application/json',
        [hashtable]$ExtraHeaders,
        [switch]$JsonContent
    )

    $bodyBytes = if ($JsonContent) {
        New-JsonContentBody -Text $RawBody
    }
    else {
        Get-Utf8NoBomBytes -Text $RawBody
    }

    $uri = New-ProbeFileUrl -Path $Path
    Assert-ProbeWriteAllowed -Case $Case -Method 'PUT' -Uri $uri

    $requestHeaders = @{}
    foreach ($key in $script:Headers.Keys) { $requestHeaders[$key] = $script:Headers[$key] }
    if ($null -ne $ExtraHeaders) {
        foreach ($key in $ExtraHeaders.Keys) { $requestHeaders[$key] = $ExtraHeaders[$key] }
    }

    $response = Invoke-ProbeHttp `
        -Method 'PUT' `
        -Uri $uri `
        -Headers $requestHeaders `
        -BodyBytes $bodyBytes `
        -ContentType $ContentType

    $row = Get-ProbeRowOrNull -Path $Path
    $read = Get-ProbeReadOrNull -Path $Path

    Add-ProbeEvidence -Case $Case -Status 'PROBED' -Data @{
        note        = "sentBytes=$($bodyBytes.Length)"
        path        = $Path
        http        = @{
            status  = $response.Status
            body    = $response.BodyText
            headers = $response.ResponseHeaders
            error   = if ($null -ne $response.TransportError) { [string]$response.TransportError.Message } else { $null }
        }
        listedAfter = ($null -ne $row)
        fieldsAfter = Get-ProbeRowFingerprint -Row $row
        bytesAfter  = if ($null -ne $read) { $read.ByteCount } else { $null }
        shaAfter    = if ($null -ne $read) { $read.Sha256 } else { $null }
    }
    Write-ProbeLog ("[PROBED] {0} status={1}" -f $Case, $response.Status)
}

function Invoke-ScenarioTextFailure {
    $target = "$($script:ProbeDir)/failure-target.txt"

    Invoke-ProbeRoundTrip -Case 'text-failure-baseline' -Path $target `
        -ContentBytes (New-JsonContentBody -Text 'failure target baseline') `
        -Note 'establishes a target so body validation is not masked by a 404'

    $bodyCases = @(
        @{ Case = 'text-failure-missing-content-field'; Body = '{"notContent":"x"}'; Note = 'no content key' },
        @{ Case = 'text-failure-null-content'; Body = '{"content":null}'; Note = 'content is null' },
        @{ Case = 'text-failure-content-array'; Body = '{"content":["a","b"]}'; Note = 'content is an array' },
        @{ Case = 'text-failure-content-object'; Body = '{"content":{"a":1}}'; Note = 'content is an object' },
        @{ Case = 'text-failure-content-number'; Body = '{"content":42}'; Note = 'content is a number' },
        @{ Case = 'text-failure-malformed-json'; Body = '{not json'; Note = 'unparseable body' }
    )

    foreach ($case in $bodyCases) {
        Invoke-ProbeFailureCase -Case $case.Case -Path $target -RawBody $case.Body
    }

    Invoke-ProbeFailureCase -Case 'text-failure-wrong-content-type' -Path $target `
        -RawBody 'plain text body' -ContentType 'text/plain'

    # Path validation, absolute so the format rule is met.
    foreach ($badPath in @('/../escaped.txt', '/.git/probe.txt', '/.rundot/probe.txt')) {
        $badUri = New-ProbeFileUrl -Path $badPath
        Assert-ProbeWriteAllowed -Case "text-failure-path-validation:$badPath" -Method 'PUT' -Uri $badUri

        $response = Invoke-ProbeHttp `
            -Method 'PUT' `
            -Uri $badUri `
            -Headers $script:Headers `
            -BodyBytes (New-JsonContentBody -Text 'path validation probe') `
            -ContentType 'application/json'

        Add-ProbeEvidence -Case 'text-failure-path-validation' -Status 'PROBED' -Data @{
            note = 'absolute path rejected or accepted'
            path = $badPath
            http = @{ status = $response.Status; body = $response.BodyText }
        }
        Write-ProbeLog ("[PROBED] text-failure-path-validation $badPath status={0}" -f $response.Status)
    }

    # A NUL in the path. This cannot go through ConvertTo-CanonicalSyncPath
    # (which rejects embedded NULs by design), so the URI is built directly.
    # #14 found 400; re-confirming keeps the path-safety claim honest.
    $nulPath = "/sync-probe/nul" + [char]0 + ".txt"
    $nulEncoded = [System.Uri]::EscapeDataString($nulPath)
    $nulUri = "$StudioOrigin/api/projects/$ProjectId/file?path=$nulEncoded"
    Assert-ProbeWriteAllowed -Case 'text-failure-nul-path' -Method 'PUT' -Uri $nulUri

    $nulResponse = Invoke-ProbeHttp `
        -Method 'PUT' `
        -Uri $nulUri `
        -Headers $script:Headers `
        -BodyBytes (New-JsonContentBody -Text 'nul path probe') `
        -ContentType 'application/json'
    Add-ProbeEvidence -Case 'text-failure-nul-path' -Status 'PROBED' -Data @{
        note = 'path containing a NUL; #14 found 400'
        http = @{ status = $nulResponse.Status; body = $nulResponse.BodyText }
    }
    Write-ProbeLog ("[PROBED] text-failure-nul-path status={0}" -f $nulResponse.Status)

    # Auth probes.
    $authBody = New-JsonContentBody -Text 'auth probe'
    $targetUri = New-ProbeFileUrl -Path $target
    Assert-ProbeWriteAllowed -Case 'text-failure-auth-probes' -Method 'PUT' -Uri $targetUri

    $noAuth = Invoke-ProbeHttp `
        -Method 'PUT' `
        -Uri $targetUri `
        -Headers @{ Accept = '*/*' } `
        -BodyBytes $authBody `
        -ContentType 'application/json'
    Add-ProbeEvidence -Case 'text-failure-no-authorization' -Status 'PROBED' -Data @{
        note = 'PUT with no Authorization header'
        http = @{ status = $noAuth.Status; body = $noAuth.BodyText }
    }
    Write-ProbeLog ("[PROBED] text-failure-no-authorization status={0}" -f $noAuth.Status)

    $badAuth = Invoke-ProbeHttp `
        -Method 'PUT' `
        -Uri $targetUri `
        -Headers @{ Authorization = 'Bearer not-a-real-token'; Accept = '*/*' } `
        -BodyBytes $authBody `
        -ContentType 'application/json'
    Add-ProbeEvidence -Case 'text-failure-invalid-authorization' -Status 'PROBED' -Data @{
        note = 'PUT with a garbage bearer token'
        http = @{ status = $badAuth.Status; body = $badAuth.BodyText }
    }
    Write-ProbeLog ("[PROBED] text-failure-invalid-authorization status={0}" -f $badAuth.Status)

    # Size boundary. #14 found the limit is exactly 2,000,000 characters
    # inclusive; these confirm it is still there.
    $original = Get-ProbeReadOrNull -Path $target
    Assert-ProbeWriteAllowed -Case 'text-failure-size-probes' -Method 'PUT' -Uri $targetUri

    foreach ($size in @(1999999, 2000000, 2000001)) {
        $big = 'a' * $size
        $response = Invoke-ProbeHttp `
            -Method 'PUT' `
            -Uri $targetUri `
            -Headers $script:Headers `
            -BodyBytes (New-JsonContentBody -Text $big) `
            -ContentType 'application/json'

        Add-ProbeEvidence -Case "text-failure-size-$size" -Status 'PROBED' -Data @{
            note      = "content of $size characters"
            sentBytes = (New-JsonContentBody -Text $big).Length
            http      = @{ status = $response.Status; body = $response.BodyText }
        }
        Write-ProbeLog ("[PROBED] text-failure-size-{0} status={1}" -f $size, $response.Status)
    }

    if ($null -ne $original) {
        $restore = Invoke-ProbeTextPut `
            -Path $target `
            -ContentBytes (New-JsonContentBody -Text ([string]$original.Content))
        Start-Sleep -Milliseconds 300
        $verify = Get-ProbeReadOrNull -Path $target
        $ok = (
            $null -ne $verify -and
            [string]::Equals($verify.Sha256, $original.Sha256, [System.StringComparison]::OrdinalIgnoreCase)
        )
        Add-ProbeEvidence -Case 'text-failure-restore' -Status 'PROBED' -Data @{
            note = 'restored the target after the size probes'
            http = @{ status = $restore.Status }
            restoredExactly = $ok
        }
        if ($ok) { Write-ProbeLog '[RESTORED] text-failure target restored' }
        else {
            $script:Unrestored.Add($target)
            Write-ProbeLog '[UNRESTORED] text-failure target - fix by hand'
        }
    }
}

function Invoke-ScenarioTextConcurrencyPrepare {
    # Step 1. Write known bytes, then a human edits the same path in Studio.
    # Step 2 sends the pre-edit bytes back to see whether the edit survives.
    $target = $script:ProbeRootPath

    Invoke-ProbeRoundTrip -Case 'text-concurrency-baseline' -Path $target `
        -ContentBytes (New-JsonContentBody -Text 'concurrency baseline') `
        -Note 'establishes the concurrency target'

    $staleText = "stale baseline $([Guid]::NewGuid().ToString('N'))"
    $response = Invoke-ProbeTextPut -Path $target -ContentBytes (New-JsonContentBody -Text $staleText)
    $read = Get-ProbeReadOrNull -Path $target
    $row = Get-ProbeRowOrNull -Path $target

    $stateFile = Join-Path $OutDir 'probe-concurrency-stale.json'
    @{
        path        = $target
        staleText   = $staleText
        staleSha256 = if ($null -ne $read) { $read.Sha256 } else { $null }
        fields      = Get-ProbeRowFingerprint -Row $row
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stateFile -Encoding UTF8

    Add-ProbeEvidence -Case 'text-concurrency-prepare' -Status 'PROBED' -Data @{
        note   = 'baseline written; now edit this path in Studio'
        path   = $target
        http   = @{ status = $response.Status; body = $response.BodyText }
        sha    = if ($null -ne $read) { $read.Sha256 } else { $null }
        fields = Get-ProbeRowFingerprint -Row $row
    }

    Write-ProbeLog ''
    Write-ProbeLog 'NEXT (human step):'
    Write-ProbeLog "  1. In Studio, open $target and change its content. Save."
    Write-ProbeLog '  2. Run this probe again with -Scenario text-concurrency-apply'
    Write-ProbeLog '     so it re-sends the ORIGINAL bytes over your Studio edit.'
    Write-ProbeLog ''
}

function Invoke-ScenarioTextConcurrencyApply {
    # Step 2. Send the pre-edit bytes over the human's Studio edit. A silent
    # clobber, an error, and a conflict each mean something different for Push.
    $stateFile = Join-Path $OutDir 'probe-concurrency-stale.json'
    if (-not (Test-Path -LiteralPath $stateFile)) {
        throw "Run -Scenario text-concurrency-prepare first; $stateFile is missing."
    }

    $stale = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    $target = [string]$stale.path

    $currentRead = Get-ProbeReadOrNull -Path $target
    $remoteChanged = (
        $null -ne $currentRead -and
        -not [string]::Equals(
            [string]$currentRead.Sha256,
            [string]$stale.staleSha256,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    )

    $response = Invoke-ProbeTextPut `
        -Path $target `
        -ContentBytes (New-JsonContentBody -Text ([string]$stale.staleText))

    Start-Sleep -Milliseconds 300
    $afterRead = Get-ProbeReadOrNull -Path $target
    $afterRow = Get-ProbeRowOrNull -Path $target

    $clobbered = (
        $null -ne $afterRead -and
        [string]::Equals(
            [string]$afterRead.Sha256,
            [string]$stale.staleSha256,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    )

    Add-ProbeEvidence -Case 'text-concurrency-apply' -Status 'PROBED' -Data @{
        note                = 'stale PUT sent over a human Studio edit'
        path                = $target
        remoteChangedBefore = $remoteChanged
        staleSha            = [string]$stale.staleSha256
        shaBeforeApply      = if ($null -ne $currentRead) { $currentRead.Sha256 } else { $null }
        http                = @{
            status  = $response.Status
            body    = $response.BodyText
            headers = $response.ResponseHeaders
            error   = if ($null -ne $response.TransportError) { [string]$response.TransportError.Message } else { $null }
        }
        shaAfterApply       = if ($null -ne $afterRead) { $afterRead.Sha256 } else { $null }
        fieldsAfter         = Get-ProbeRowFingerprint -Row $afterRow
        clobbered           = $clobbered
    }

    if (-not $remoteChanged) {
        Write-ProbeLog '[WARNING] text-concurrency-apply: remote did not change; the human edit was not detected.'
    }
    if ($clobbered) {
        Write-ProbeLog '[PROBED] text-concurrency-apply: the human edit was silently clobbered.'
    }
}

function Invoke-ScenarioSurvey {
    # Lists every probe-created path so the human can delete them in the Studio
    # UI. There is no delete route in this milestone (#16 owns it).
    $paths = @(Get-ProbeListedPaths | Where-Object { $_ -like "*$($script:ProbeDir)*" } | Sort-Object)

    Add-ProbeEvidence -Case 'survey-probe-paths' -Status 'OBSERVED' -Data @{
        note  = 'delete these paths in the Studio UI to clean up the disposable project'
        paths = $paths
        count = $paths.Count
    }

    Write-ProbeLog ("[OBSERVED] {0} probe path(s) remain:" -f $paths.Count)
    foreach ($path in $paths) { Write-ProbeLog "  $path" }
}


# ---------------------------------------------------------------------------
# Binary scenarios (#15)
# ---------------------------------------------------------------------------

function Invoke-ScenarioBinaryDiscover {
    # The three request bodies are undocumented. Learn them from validation
    # errors instead of guessing, the same way #14 learned the text body.
    $fileName = Get-BinaryProbeName -Suffix 'discover'
    $targetPath = "$($script:ProbeDir)/$fileName"

    $bodies = @(
        @{ Case = 'binary-discover-empty-body'; Body = @{}; Note = 'empty object; validation should name the required fields' },
        @{ Case = 'binary-discover-filename-only'; Body = @{ fileName = $fileName }; Note = 'fileName alone' },
        @{ Case = 'binary-discover-path-only'; Body = @{ path = $targetPath }; Note = 'path alone' },
        @{ Case = 'binary-discover-name-and-path'; Body = @{ fileName = $fileName; path = $targetPath }; Note = 'fileName plus path' },
        @{ Case = 'binary-discover-name-path-type'; Body = @{ fileName = $fileName; path = $targetPath; contentType = 'image/png' }; Note = 'adds contentType' },
        @{ Case = 'binary-discover-size-too'; Body = @{ fileName = $fileName; path = $targetPath; contentType = 'image/png'; size = 100 }; Note = 'adds size' }
    )

    foreach ($candidate in $bodies) {
        $response = Invoke-ProbeUploadUrlRequest -Body $candidate.Body
        Add-ProbeEvidence -Case $candidate.Case -Status 'PROBED' -Data @{
            note   = $candidate.Note
            request = $candidate.Body
            http   = @{
                status  = $response.Status
                body    = $response.BodyText
                fields  = Get-ProbeResponseFields -Response $response
                headers = $response.ResponseHeaders
            }
        }
        Write-ProbeLog ("[PROBED] {0} status={1}" -f $candidate.Case, $response.Status)

        if ($response.Status -eq 200) {
            Write-ProbeLog ("[FOUND] {0} accepted the body: {1}" -f $candidate.Case, ($candidate.Body | ConvertTo-Json -Compress))
            break
        }
    }

    # Adopt validation, learned the same way.
    foreach ($candidate in @(
        @{ Case = 'binary-discover-adopt-empty'; Body = @{}; Note = 'empty adopt body' },
        @{ Case = 'binary-discover-adopt-filename'; Body = @{ fileName = $fileName }; Note = 'adopt with fileName' },
        @{ Case = 'binary-discover-adopt-path'; Body = @{ path = $targetPath }; Note = 'adopt with path' },
        @{ Case = 'binary-discover-adopt-name-path'; Body = @{ fileName = $fileName; path = $targetPath }; Note = 'adopt with fileName and path' }
    )) {
        $response = Invoke-ProbeUploadAdoptRequest -Body $candidate.Body
        Add-ProbeEvidence -Case $candidate.Case -Status 'PROBED' -Data @{
            note    = $candidate.Note
            request = $candidate.Body
            http    = @{
                status  = $response.Status
                body    = $response.BodyText
                fields  = Get-ProbeResponseFields -Response $response
            }
        }
        Write-ProbeLog ("[PROBED] {0} status={1}" -f $candidate.Case, $response.Status)
    }
}

function Invoke-ScenarioBinaryCreate {
    # Create a new binary through the full three-step flow.
    $fileName = Get-BinaryProbeName -Suffix 'create'
    $bytes = Get-BinaryProbeBytes -Variant 1

    $result = Invoke-ProbeBinaryUpload -Case 'binary-create-new' -FileName $fileName -Bytes $bytes `
        -Note 'new binary, full upload-url -> presigned PUT -> upload-adopt flow'

    if ($null -ne $result.listedAfter -and $result.listedAfter.Count -gt 0) {
        $created = [string]$result.listedAfter[0]
        $read = Get-ProbeReadOrNull -Path $created
        Add-ProbeEvidence -Case 'binary-create-readback' -Status 'PROBED' -Data @{
            note          = 'what the created binary reads back as'
            path          = $created
            encoding      = if ($null -ne $read) { $read.Encoding } else { $null }
            byteCount     = if ($null -ne $read) { $read.ByteCount } else { $null }
            sha256        = if ($null -ne $read) { $read.Sha256 } else { $null }
            sentSha256    = $result.sha256
            roundTripped  = ($null -ne $read -and [string]::Equals($read.Sha256, $result.sha256, [System.StringComparison]::OrdinalIgnoreCase))
            fields        = Get-ProbeRowFingerprint -Row (Get-ProbeRowOrNull -Path $created)
        }
        Write-ProbeLog ("[PROBED] binary-create-readback encoding={0} bytes={1}" -f `
            $(if ($null -ne $read) { $read.Encoding } else { '-' }), `
            $(if ($null -ne $read) { $read.ByteCount } else { '-' }))
    }
}

function Invoke-ScenarioBinaryCollision {
    # Upload the same filename repeatedly and capture the exact suffix rule.
    $fileName = Get-BinaryProbeName -Suffix 'collide'
    $bytes = Get-BinaryProbeBytes -Variant 2

    for ($i = 1; $i -le 4; $i++) {
        $result = Invoke-ProbeBinaryUpload `
            -Case "binary-collision-repeat-$i" `
            -FileName $fileName `
            -Bytes $bytes `
            -Note "repeat $i with an identical filename and identical bytes"

        $matching = @(Get-ProbeListedPaths | Where-Object { $_ -like "*$($script:ProbeDir)*" })
        Add-ProbeEvidence -Case "binary-collision-survey-$i" -Status 'OBSERVED' -Data @{
            note    = "probe paths after repeat $i"
            paths   = $matching
            count   = $matching.Count
            attempt = $i
        }
        Write-ProbeLog ("[OBSERVED] binary-collision-survey-{0}: {1} path(s)" -f $i, $matching.Count)
    }

    # Suffix edge cases: extensionless, multi-dot, leading dot, and a name
    # that already ends in a numeric suffix.
    foreach ($edge in @(
        @{ Suffix = 'noext'; Name = "probe-$([Guid]::NewGuid().ToString('N').Substring(0,8))-noext" },
        @{ Suffix = 'multidot'; Name = "probe.$([Guid]::NewGuid().ToString('N').Substring(0,8)).tar.png" },
        @{ Suffix = 'dotfile'; Name = ".probe-$([Guid]::NewGuid().ToString('N').Substring(0,8))" },
        @{ Suffix = 'numbered'; Name = "probe-$([Guid]::NewGuid().ToString('N').Substring(0,8))-1.png" }
    )) {
        $first = Invoke-ProbeBinaryUpload -Case "binary-collision-edge-$($edge.Suffix)-1" -FileName $edge.Name `
            -Bytes (Get-BinaryProbeBytes -Variant 3) `
            -Note "edge case $($edge.Suffix), first upload"
        $second = Invoke-ProbeBinaryUpload -Case "binary-collision-edge-$($edge.Suffix)-2" -FileName $edge.Name `
            -Bytes (Get-BinaryProbeBytes -Variant 4) `
            -Note "edge case $($edge.Suffix), second upload with the same name"

        Add-ProbeEvidence -Case "binary-collision-edge-$($edge.Suffix)-result" -Status 'OBSERVED' -Data @{
            note       = 'paths listed after the second upload'
            edgeCase   = $edge.Suffix
            fileName   = $edge.Name
            firstPaths = $first.listedAfter
            secondPaths = $second.listedAfter
        }
    }

    # Where does the collision rename apply: basename, or full path?
    $nestedName = Get-BinaryProbeName -Suffix 'nested'
    $nestedPath = "$($script:ProbeDir)/nested/$nestedName"
    foreach ($i in @(1, 2)) {
        $response = Invoke-ProbeUploadUrlRequest -Body @{
            fileName = $nestedName
            path     = $nestedPath
            contentType = 'image/png'
        }
        $presigned = Get-ProbePresignedUrl -Response $response
        if ($null -ne $presigned) {
            $rawPut = Invoke-ProbeRawPut -PresignedUrl $presigned -Bytes (Get-BinaryProbeBytes -Variant 5)
            $adopt = Invoke-ProbeUploadAdoptRequest -Body @{ fileName = $nestedName; path = $nestedPath }
            Add-ProbeEvidence -Case "binary-collision-nested-$i" -Status 'PROBED' -Data @{
                note       = 'nested directory collision'
                requestPath = $nestedPath
                uploadUrlStatus = $response.Status
                putStatus  = $rawPut.Status
                adoptStatus = $adopt.Status
                adoptBody  = $adopt.BodyText
            }
        }
    }

    $nested = @(Get-ProbeListedPaths | Where-Object { $_ -like '*nested*' })
    Add-ProbeEvidence -Case 'binary-collision-nested-survey' -Status 'OBSERVED' -Data @{
        note  = 'nested paths after two uploads of the same basename'
        paths = $nested
    }
}

function Invoke-ScenarioBinaryOverwrite {
    # Can an existing binary be replaced, or does every upload add a sibling?
    # Create a probe-owned binary first, then try every plausible replace
    # mechanism against it.
    $fileName = Get-BinaryProbeName -Suffix 'replace'
    $targetPath = "$($script:ProbeDir)/$fileName"

    $create = Invoke-ProbeBinaryUpload -Case 'binary-overwrite-create-target' -FileName $fileName `
        -Bytes (Get-BinaryProbeBytes -Variant 6) `
        -Note 'establishes the binary that the replace cases will target'

    $createdPath = if ($null -ne $create.listedAfter -and $create.listedAfter.Count -gt 0) {
        [string]$create.listedAfter[0]
    }
    else {
        $targetPath
    }

    $before = Get-ProbeReadOrNull -Path $createdPath

    # Attempt 1: a fresh upload-url and adopt for the exact same path.
    $replaceBytes = Get-BinaryProbeBytes -Variant 7
    $replace = Invoke-ProbeBinaryUpload -Case 'binary-overwrite-same-path' -FileName $fileName `
        -Bytes $replaceBytes `
        -Note 'same filename and same path, new bytes; in-place replace or new sibling?'

    $after = Get-ProbeReadOrNull -Path $createdPath
    $allMatching = @(Get-ProbeListedPaths | Where-Object { $_ -like "*$([System.IO.Path]::GetFileNameWithoutExtension($fileName))*" })

    Add-ProbeEvidence -Case 'binary-overwrite-result' -Status 'OBSERVED' -Data @{
        note             = 'did the original path change, or did a sibling appear?'
        targetPath       = $createdPath
        shaBefore        = if ($null -ne $before) { $before.Sha256 } else { $null }
        bytesBefore      = if ($null -ne $before) { $before.ByteCount } else { $null }
        sentSha256       = Get-Sha256Hex -Bytes $replaceBytes
        shaAfter         = if ($null -ne $after) { $after.Sha256 } else { $null }
        bytesAfter       = if ($null -ne $after) { $after.ByteCount } else { $null }
        replacedInPlace  = (
            $null -ne $before -and $null -ne $after -and
            [string]::Equals($after.Sha256, (Get-Sha256Hex -Bytes $replaceBytes), [System.StringComparison]::OrdinalIgnoreCase)
        )
        originalIntact   = (
            $null -ne $before -and $null -ne $after -and
            [string]::Equals($after.Sha256, $before.Sha256, [System.StringComparison]::OrdinalIgnoreCase)
        )
        matchingPaths    = $allMatching
    }

    # Attempt 2: re-adopt the same upload id, if the discover step exposed one.
    $reAdoptUrl = Invoke-ProbeUploadUrlRequest -Body @{
        fileName = $fileName
        path     = $createdPath
        contentType = 'image/png'
    }
    $reAdopt = Invoke-ProbeUploadAdoptRequest -Body @{ fileName = $fileName; path = $createdPath }
    Add-ProbeEvidence -Case 'binary-overwrite-readopt' -Status 'PROBED' -Data @{
        note            = 're-adopt the same path without a new presigned upload'
        uploadUrlStatus = $reAdoptUrl.Status
        adoptStatus     = $reAdopt.Status
        adoptBody       = $reAdopt.BodyText
        pathsAfter      = @(Get-ProbeListedPaths | Where-Object { $_ -like "*$($script:ProbeDir)*" })
    }

    # Attempt 3: PUT new bytes to the existing presigned URL for this path.
    if ($null -ne $create.presigned) {
        Add-ProbeEvidence -Case 'binary-overwrite-presigned-reuse' -Status 'OBSERVED' -Data @{
            note = 'a presigned URL is single-use unless proven otherwise; recorded for the doc'
            note2 = 'the first presigned PUT status was recorded on the create case'
            putStatus = $create.presigned.status
        }
    }
}

function Invoke-ScenarioBinaryIdempotency {
    # Identical bytes and identical filename, twice. Converge or duplicate?
    $fileName = Get-BinaryProbeName -Suffix 'idem'
    $bytes = Get-BinaryProbeBytes -Variant 8

    $first = Invoke-ProbeBinaryUpload -Case 'binary-idempotency-first' -FileName $fileName -Bytes $bytes `
        -Note 'first upload'
    $second = Invoke-ProbeBinaryUpload -Case 'binary-idempotency-second' -FileName $fileName -Bytes $bytes `
        -Note 'second upload, byte-identical'

    $paths = @(Get-ProbeListedPaths | Where-Object { $_ -like "*$($script:ProbeDir)*" })
    Add-ProbeEvidence -Case 'binary-idempotency-survey' -Status 'OBSERVED' -Data @{
        note        = 'identical uploads converge on one path, or multiply it?'
        firstPaths  = $first.listedAfter
        secondPaths = $second.listedAfter
        allPaths    = $paths
    }
    Write-ProbeLog ("[OBSERVED] binary-idempotency: first={0} second={1}" -f `
        (@($first.listedAfter).Count), (@($second.listedAfter).Count))

    # Retry an ambiguous failure: send the presigned PUT twice.
    $retryName = Get-BinaryProbeName -Suffix 'retry'
    $uploadUrl = Invoke-ProbeUploadUrlRequest -Body @{
        fileName = $retryName
        path     = "$($script:ProbeDir)/$retryName"
        contentType = 'image/png'
    }
    $presigned = Get-ProbePresignedUrl -Response $uploadUrl
    if ($null -ne $presigned) {
        $firstPut = Invoke-ProbeRawPut -PresignedUrl $presigned -Bytes (Get-BinaryProbeBytes -Variant 9)
        $secondPut = Invoke-ProbeRawPut -PresignedUrl $presigned -Bytes (Get-BinaryProbeBytes -Variant 9)
        $adopt = Invoke-ProbeUploadAdoptRequest -Body @{
            fileName = $retryName
            path     = "$($script:ProbeDir)/$retryName"
        }
        Add-ProbeEvidence -Case 'binary-idempotency-presigned-retry' -Status 'PROBED' -Data @{
            note           = 'PUT the same presigned URL twice, then adopt once'
            firstPutStatus = $firstPut.Status
            secondPutStatus = $secondPut.Status
            secondPutBody  = $secondPut.BodyText
            adoptStatus    = $adopt.Status
            adoptBody      = $adopt.BodyText
            listedAfter    = @(Get-ProbeListedPaths | Where-Object { $_ -like "*$retryName*" })
        }
    }
}

function Invoke-ScenarioBinaryFailure {
    # Failure, auth, and validation behavior across all three steps.
    $fileName = Get-BinaryProbeName -Suffix 'fail'
    $targetPath = "$($script:ProbeDir)/$fileName"
    $bytes = Get-BinaryProbeBytes -Variant 10

    # Adopt before any upload.
    $earlyAdopt = Invoke-ProbeUploadAdoptRequest -Body @{ fileName = $fileName; path = $targetPath }
    Add-ProbeEvidence -Case 'binary-failure-adopt-without-upload' -Status 'PROBED' -Data @{
        note = 'adopt a file that was never uploaded'
        http = @{ status = $earlyAdopt.Status; body = $earlyAdopt.BodyText }
    }
    Write-ProbeLog ("[PROBED] binary-failure-adopt-without-upload status={0}" -f $earlyAdopt.Status)

    # Adopt an unknown upload id.
    $bogusAdopt = Invoke-ProbeUploadAdoptRequest -Body @{
        fileName = $fileName
        path     = $targetPath
        uploadId = 'not-a-real-upload-id'
        key      = 'not/a/real/key'
    }
    Add-ProbeEvidence -Case 'binary-failure-adopt-unknown-id' -Status 'PROBED' -Data @{
        note = 'adopt with a fabricated upload identity'
        http = @{ status = $bogusAdopt.Status; body = $bogusAdopt.BodyText }
    }
    Write-ProbeLog ("[PROBED] binary-failure-adopt-unknown-id status={0}" -f $bogusAdopt.Status)

    # Upload-url validation.
    foreach ($case in @(
        @{ Case = 'binary-failure-upload-url-empty'; Body = @{}; Note = 'empty body' },
        @{ Case = 'binary-failure-upload-url-bad-type'; Body = @{ fileName = $fileName; contentType = 'application/x-not-real' }; Note = 'unknown content type' }
    )) {
        $response = Invoke-ProbeUploadUrlRequest -Body $case.Body
        Add-ProbeEvidence -Case $case.Case -Status 'PROBED' -Data @{
            note = $case.Note
            request = $case.Body
            http = @{ status = $response.Status; body = $response.BodyText; fields = Get-ProbeResponseFields -Response $response }
        }
        Write-ProbeLog ("[PROBED] {0} status={1}" -f $case.Case, $response.Status)
    }

    # Auth: the Studio routes need the bearer token; the presigned URL must not.
    $noAuthUploadUrl = Invoke-ProbeHttp `
        -Method 'POST' `
        -Uri (New-ProbeApiUrl -RelativePath "/api/projects/$ProjectId/upload-url") `
        -Headers @{ Accept = '*/*' } `
        -BodyBytes (Get-Utf8NoBomBytes -Text '{}') `
        -ContentType 'application/json'
    Add-ProbeEvidence -Case 'binary-failure-upload-url-no-auth' -Status 'PROBED' -Data @{
        note = 'upload-url with no Authorization header'
        http = @{ status = $noAuthUploadUrl.Status; body = $noAuthUploadUrl.BodyText }
    }
    Write-ProbeLog ("[PROBED] binary-failure-upload-url-no-auth status={0}" -f $noAuthUploadUrl.Status)

    $badAuthAdopt = Invoke-ProbeHttp `
        -Method 'POST' `
        -Uri (New-ProbeApiUrl -RelativePath "/api/projects/$ProjectId/upload-adopt") `
        -Headers @{ Authorization = 'Bearer not-a-real-token'; Accept = '*/*' } `
        -BodyBytes (Get-Utf8NoBomBytes -Text '{}') `
        -ContentType 'application/json'
    Add-ProbeEvidence -Case 'binary-failure-adopt-bad-auth' -Status 'PROBED' -Data @{
        note = 'upload-adopt with a garbage bearer token'
        http = @{ status = $badAuthAdopt.Status; body = $badAuthAdopt.BodyText }
    }
    Write-ProbeLog ("[PROBED] binary-failure-adopt-bad-auth status={0}" -f $badAuthAdopt.Status)

    # Presigned URL: correct bytes but a wrong content type.
    $uploadUrl = Invoke-ProbeUploadUrlRequest -Body @{
        fileName = $fileName
        path     = $targetPath
        contentType = 'image/png'
    }
    $presigned = Get-ProbePresignedUrl -Response $uploadUrl
    if ($null -ne $presigned) {
        $wrongType = Invoke-ProbeRawPut -PresignedUrl $presigned -Bytes $bytes -ContentType 'application/octet-stream'
        Add-ProbeEvidence -Case 'binary-failure-presigned-wrong-content-type' -Status 'PROBED' -Data @{
            note = 'presigned PUT declared application/octet-stream for PNG bytes'
            http = @{ status = $wrongType.Status; body = $wrongType.BodyText; headers = $wrongType.ResponseHeaders }
        }
        Write-ProbeLog ("[PROBED] binary-failure-presigned-wrong-content-type status={0}" -f $wrongType.Status)
    }

    # Presigned URL: a malformed one.
    $malformed = Invoke-ProbeRawPut -PresignedUrl 'https://example.invalid/not-a-presigned-url' -Bytes $bytes
    Add-ProbeEvidence -Case 'binary-failure-presigned-malformed' -Status 'PROBED' -Data @{
        note = 'PUT to a URL that is not a real presigned target'
        http = @{ status = $malformed.Status; error = if ($null -ne $malformed.TransportError) { [string]$malformed.TransportError.Message } else { $null } }
    }
    Write-ProbeLog ("[PROBED] binary-failure-presigned-malformed status={0}" -f $malformed.Status)
}


# ---------------------------------------------------------------------------
# Whole-investigation runners
#
# One command per issue instead of seven, for the human running the probe.
# Every sub-scenario keeps its own per-case evidence; these only sequence them
# and keep going when one case fails, so a single rejection does not cost the
# rest of the run.
# ---------------------------------------------------------------------------

function Invoke-ProbeStep {
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    Write-ProbeLog ''
    Write-ProbeLog "=== $Name ==="

    try {
        & $Action
    }
    catch {
        # A refusal or a transport failure is a finding, not a reason to abort
        # the whole run.
        Add-ProbeEvidence -Case "$Name-aborted" -Status 'ERROR' -Data @{
            note  = 'this step threw; the runner continued'
            error = $_.Exception.Message
        }
        Write-ProbeLog ("[ERROR] {0}: {1}" -f $Name, $_.Exception.Message)
    }
}

function Invoke-ScenarioRunTextAll {
    # Re-runs the #14 text investigation end to end. Useful as a regression
    # check that the documented text semantics still hold.
    Invoke-ProbeStep 'text-create' { Invoke-ScenarioTextCreate }
    Invoke-ProbeStep 'text-overwrite' { Invoke-ScenarioTextOverwrite }
    Invoke-ProbeStep 'text-version' { Invoke-ScenarioTextVersion }
    Invoke-ProbeStep 'text-conditional' { Invoke-ScenarioTextConditional }
    Invoke-ProbeStep 'text-idempotency' { Invoke-ScenarioTextIdempotency }
    Invoke-ProbeStep 'text-failure' { Invoke-ScenarioTextFailure }
    Invoke-ProbeStep 'text-survey' { Invoke-ScenarioSurvey }
}

function Invoke-ScenarioRunBinaryAll {
    # The #15 characterization, in the order the evidence needs to be read:
    # discover the contract, then create, collide, try to replace, then
    # idempotency and failure, then list what is left behind.
    Invoke-ProbeStep 'binary-discover' { Invoke-ScenarioBinaryDiscover }
    Invoke-ProbeStep 'binary-create' { Invoke-ScenarioBinaryCreate }
    Invoke-ProbeStep 'binary-collision' { Invoke-ScenarioBinaryCollision }
    Invoke-ProbeStep 'binary-overwrite' { Invoke-ScenarioBinaryOverwrite }
    Invoke-ProbeStep 'binary-idempotency' { Invoke-ScenarioBinaryIdempotency }
    Invoke-ProbeStep 'binary-failure' { Invoke-ScenarioBinaryFailure }
    Invoke-ProbeStep 'binary-survey' { Invoke-ScenarioSurvey }
}



# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

switch ($Scenario) {
    'text-create'                { Invoke-ScenarioTextCreate }
    'text-overwrite'             { Invoke-ScenarioTextOverwrite }
    'text-version'               { Invoke-ScenarioTextVersion }
    'text-conditional'           { Invoke-ScenarioTextConditional }
    'text-idempotency'           { Invoke-ScenarioTextIdempotency }
    'text-failure'               { Invoke-ScenarioTextFailure }
    'text-concurrency-prepare'   { Invoke-ScenarioTextConcurrencyPrepare }
    'text-concurrency-apply'     { Invoke-ScenarioTextConcurrencyApply }
    'text-survey'                { Invoke-ScenarioSurvey }
    'binary-discover'            { Invoke-ScenarioBinaryDiscover }
    'binary-create'              { Invoke-ScenarioBinaryCreate }
    'binary-collision'           { Invoke-ScenarioBinaryCollision }
    'binary-overwrite'           { Invoke-ScenarioBinaryOverwrite }
    'binary-idempotency'         { Invoke-ScenarioBinaryIdempotency }
    'binary-failure'             { Invoke-ScenarioBinaryFailure }
    'binary-survey'              { Invoke-ScenarioSurvey }
    'run-text-all'               { Invoke-ScenarioRunTextAll }
    'run-binary-all'             { Invoke-ScenarioRunBinaryAll }
    default {
        throw "Scenario '$Scenario' is not implemented."
    }
}

Save-ProbeEvidence

# Drop the bearer token before the process exits.
$script:Headers.Authorization = $null
Write-ProbeLog 'Done.'










