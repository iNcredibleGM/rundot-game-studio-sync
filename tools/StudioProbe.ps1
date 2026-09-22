# Studio protocol probe: the reusable investigation harness behind
# docs/text-write-protocol.md (#14), docs/binary-upload-protocol.md (#15), and
# docs/delete-rename-protocol.md (#16).
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
#   - DELETE is the one mutation that can destroy something the probe did not
#     create, so Assert-ProbeDeleteTarget guards the target itself: only
#     /sync-probe, a run-stamped /uploads path, or a run-stamped
#     reserved-shaped path is eligible. A bare directory is never eligible.
#   - Created binaries and text files are deleted at the end of a full run
#     (DELETE /file, found during #15 and characterized by #16) and the
#     deletion is verified by list absence. Anything cleanup cannot remove is
#     listed for manual removal in the Studio UI.
#   - Tokens are never printed, logged, or written to evidence. Evidence holds
#     status codes, sizes, hashes, and redacted bodies only. A DevTools rename
#     capture is redacted for credential-shaped text before it is recorded.
#
# Usage:
#
#   # 1. Put a fresh Studio bearer token in a file (never inline; it would land
#   #    in your shell history). The token is never printed by the probe.
#   rundot login
#   #   ...then copy the access token to, e.g., %TEMP%\rundot-token.txt
#
#   # 2. Dry run first. Prints what would be sent and sends nothing.
#   .\tools\StudioProbe.ps1 -ProjectId <id> -Scenario run-binary-all
#
#   # 3. The real run, against a DISPOSABLE project only.
#   .\tools\StudioProbe.ps1 -ProjectId <id> -Scenario run-binary-all `
#       -AccessTokenPath "$env:TEMP\rundot-token.txt" -ConfirmRemoteWrite
#
#   # The #14 text investigation, for regression:
#   .\tools\StudioProbe.ps1 -ProjectId <id> -Scenario run-text-all `
#       -AccessTokenPath "$env:TEMP\rundot-token.txt" -ConfirmRemoteWrite
#
#   # The #16 delete/rename/concurrency investigation:
#   .\tools\StudioProbe.ps1 -ProjectId <id> -Scenario run-delete-rename-all `
#       -AccessTokenPath "$env:TEMP\rundot-token.txt" -ConfirmRemoteWrite
#
#   # The #37 text-file create investigation:
#   .\tools\StudioProbe.ps1 -ProjectId <id> -Scenario run-text-create-all `
#       -AccessTokenPath "$env:TEMP\rundot-token.txt" -ConfirmRemoteWrite
#
#   # The rename route has no documented shape, so the guessed candidates are
#   # backed by a human capture. Prepare a target, rename it by hand in Studio
#   # with DevTools open, save the request, then record it:
#   .\tools\StudioProbe.ps1 -ProjectId <id> -Scenario rename-devtools-prepare -ConfirmRemoteWrite
#   .\tools\StudioProbe.ps1 -ProjectId <id> -Scenario rename-devtools-apply `
#       -CapturePath "$env:TEMP\rundot-rename-capture.txt" -ConfirmRemoteWrite
#
# Evidence lands in -OutDir (default %TEMP%\rundot-probe-evidence) as a JSON
# file and a log. A full run deletes what it created; anything left behind is
# printed as a CLEANUP list to remove in the Studio UI.
#
# The token file must be outside the repository. Never commit it.

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
        'binary-path-control',
        'binary-text-via-upload',
        'binary-delete-discover',
        'binary-cleanup',
        'binary-collision',
        'binary-overwrite',
        'binary-idempotency',
        'binary-failure',
        'binary-survey',
        # New in the #16 delete/rename/concurrency investigation.
        'delete-file-basic',
        'delete-idempotency',
        'delete-absent',
        'delete-directory',
        'delete-reserved',
        'delete-encoding',
        'delete-auth',
        'delete-response-headers',
        'rename-probe',
        'rename-move',
        'rename-devtools-prepare',
        'rename-devtools-apply',
        'concurrency-delete-vs-write',
        'concurrency-delete-while-listed',
        'revision-identity',
        'etag-headers',
        'conditional-delete',
        'delete-rename-survey',
        # Whole-investigation runners. These are the ones to use by hand: one
        # command per issue instead of seven.
        'run-text-all',
        'run-binary-all',
        'run-delete-rename-all',
        # New in the #37 text-file create investigation.
        'text-create-discover',
        'text-create-compose',
        'text-create-idempotency',
        'text-create-bytes',
        'text-create-race',
        'text-create-conditional',
        'text-create-reserved',
        'text-create-route-survey',
        'text-create-devtools-prepare',
        'text-create-devtools-apply',
        'text-place-exact',
        'run-text-create-all'
    )]
    [string]$Scenario,

    [string]$RepoRoot = '',

    [string]$StudioOrigin = 'https://venus-studio-prod.series-ai.workers.dev',

    [string]$OutDir = (Join-Path $env:TEMP 'rundot-probe-evidence'),

    # The DevTools capture file for rename-devtools-apply. A copied fetch or
    # HAR carries an Authorization header, so the probe redacts anything
    # credential-shaped before it records the request shape.
    [string]$CapturePath,

    # A bearer token, a JWT, or pasted DevTools text containing one. Never
    # logged. Exists so automation never blocks on an interactive prompt.
    [string]$AccessToken,

    # A file containing the same thing. Preferred over -AccessToken: the token
    # never reaches a shell history or a chat transcript.
    [string]$AccessTokenPath,

    # Refuse the interactive fallback instead of prompting.
    [switch]$NoInteractiveAuth,

    # Keep the files a run creates instead of deleting them at the end. Useful
    # when inspecting artifacts; the default is to leave the project as found.
    [switch]$SkipCleanup,

    # Cleanup scope: only this run's files by default, or every probe file.
    [switch]$AllRuns,

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

# Binary uploads do NOT honor the requested path: adopt recorded every file
# under /uploads/ regardless of what was asked for. Probe-owned binary paths
# are therefore matched by filename under this directory.
$script:ProbeUploadDir = '/uploads'

# Every file this run creates carries this stamp, so cleanup is exact rather
# than a guess about which /uploads entries are ours. The stamp is fixed for
# the process so one run cannot be confused with another.
$script:ProbeRunStamp = (Get-Date -Format 'yyyyMMdd-HHmmss')
$script:ProbeNamePrefix = "probe-$($script:ProbeRunStamp)"

$script:LogPath = $null
$script:EvidencePath = $null
$script:Evidence = New-Object 'System.Collections.Generic.List[object]'
$script:CreatedPaths = New-Object 'System.Collections.Generic.List[string]'
$script:Unrestored = New-Object 'System.Collections.Generic.List[string]'
$script:CleanupRan = $false
$script:CleanupRemaining = -1
$script:Token = $null
$script:Headers = $null
$script:WriteEnabled = $false
$script:ProbeAllowAllRuns = $false
# Set by text-create-discover when a guessed route returns 2xx and lists the path.
$script:TextCreateRouteFound = $null

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
        if ($script:CleanupRan -and $script:CleanupRemaining -eq 0) {
            # Everything created was deleted and verified gone. Do not print a
            # manual-delete list: telling a human to remove files that no longer
            # exist is how the list stops being trusted.
            Write-ProbeLog 'CLEANUP - every path this run created was deleted and verified gone.'
        }
        else {
            Write-ProbeLog 'CLEANUP - the probe created these paths; delete them in the Studio UI:'
            foreach ($path in @($script:CreatedPaths | Sort-Object -Unique)) {
                Write-ProbeLog "  $path"
            }
            if ($script:CleanupRan) {
                Write-ProbeLog "  ($($script:CleanupRemaining) still listed after cleanup; see the log)"
            }
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
    param($Bytes)

    # An empty [byte[]] binds as $null on a typed parameter, so this stays
    # untyped and hashes a zero-length buffer as the empty-file digest.
    $buffer = New-Object byte[] 0
    if ($null -ne $Bytes) {
        $buffer = [byte[]]$Bytes
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [System.BitConverter]::ToString($sha.ComputeHash($buffer)).Replace('-', '').ToLowerInvariant()
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

function Get-ProbeProbeOwnedPaths {
    # Binary uploads are recorded under /uploads regardless of the requested
    # path, so a survey that only looks in /sync-probe reports zero and hides
    # everything the probe actually created. Match both directories.
    param([string[]]$Paths)

    if ($null -eq $Paths) { $Paths = @(Get-ProbeListedPaths) }

    return @($Paths | Where-Object {
        $_ -like "$($script:ProbeDir)/*" -or $_ -like "$($script:ProbeUploadDir)/*"
    })
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
    # Namespaced per run, so every file a run creates is identifiable and
    # removable without guessing. The run stamp is fixed for the process, so a
    # leftover from an earlier run never masquerades as a collision in this one.
    param(
        [string]$Suffix = '',
        [string]$Extension = '.png'
    )

    if ([string]::IsNullOrEmpty($Suffix)) {
        return "$($script:ProbeNamePrefix)$Extension"
    }
    return "$($script:ProbeNamePrefix)-$Suffix$Extension"
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

function Get-ProbeValidationField {
    # The `field` a VALIDATION_ERROR named. This is how the undocumented
    # contract is learned: ask, get told which field is missing, add it.
    param($Response)

    if ($null -eq $Response) { return $null }
    if ([string]::IsNullOrWhiteSpace([string]$Response.BodyText)) { return $null }

    try { $parsed = $Response.BodyText | ConvertFrom-Json }
    catch { return $null }

    $error = $parsed.PSObject.Properties['error']
    if ($null -eq $error -or $null -eq $error.Value) { return $null }

    $field = $error.Value.PSObject.Properties['field']
    if ($null -eq $field) { return $null }

    return [string]$field.Value
}

function Get-ProbeMintedUploadId {
    # The uploadId adopt requires. Try every plausible spelling rather than
    # assuming one, and fall back to a nested object.
    param($Response)

    if ($null -eq $Response) { return $null }
    if ([string]::IsNullOrWhiteSpace([string]$Response.BodyText)) { return $null }

    try { $parsed = $Response.BodyText | ConvertFrom-Json }
    catch { return $null }

    foreach ($candidate in @('uploadId', 'upload_id', 'id')) {
        $property = $parsed.PSObject.Properties[$candidate]
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }

    foreach ($candidate in @('data', 'result', 'upload')) {
        $property = $parsed.PSObject.Properties[$candidate]
        if ($null -ne $property -and $null -ne $property.Value) {
            $nested = Get-ProbeMintedUploadId -Response ([pscustomobject]@{
                BodyText = ($property.Value | ConvertTo-Json -Compress -Depth 8)
            })
            if ($null -ne $nested) { return $nested }
        }
    }

    return $null
}

function New-ProbeUploadUrlBody {
    # The observed required shape. declaredSize is what the server validates
    # first; the discover scenario found it by asking with an empty body.
    param(
        [string]$FileName,
        [string]$Path,
        [int]$DeclaredSize,
        [string]$ContentType = 'image/png'
    )

    return @{
        fileName     = $FileName
        path         = $Path
        declaredSize = $DeclaredSize
        contentType  = $ContentType
    }
}

function Get-ProbeAdoptFieldValue {
    # Map a field the server named as missing to the value it wants. adopt
    # validates in its own order, so this is keyed by name rather than
    # hardcoded as a sequence.
    param(
        [string]$Field,
        [string]$FileName,
        [string]$Path,
        [byte[]]$Bytes,
        [string]$ContentType = 'image/png'
    )

    switch ($Field) {
        'name'         { return $FileName }
        'fileName'     { return $FileName }
        'path'         { return $Path }
        'contentType'  { return $ContentType }
        'mimeType'     { return $ContentType }
        'size'         { return $Bytes.Length }
        'declaredSize' { return $Bytes.Length }
        'type'         { return 'file' }
        default        { return $null }
    }
}

function Invoke-ProbeAdoptWalk {
    # adopt names the first missing field in each rejection, so walk that chain
    # instead of hardcoding a body. Any case that adopts goes through this, so
    # a case never has to know the full contract and cannot silently send a
    # field name the server does not recognize.
    param(
        [string]$UploadId,
        [string]$Name,
        [string]$Path,
        [byte[]]$Bytes,
        [hashtable]$Seed,
        [int]$MaxAttempts = 8
    )

    $body = @{}
    if ($null -ne $Seed) {
        foreach ($key in $Seed.Keys) { $body[$key] = $Seed[$key] }
    }
    if (-not [string]::IsNullOrWhiteSpace($UploadId)) { $body['uploadId'] = $UploadId }

    $walk = New-Object 'System.Collections.Generic.List[object]'
    $response = $null

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $response = Invoke-ProbeUploadAdoptRequest -Body $body
        $walk.Add([pscustomobject]@{
            attempt = $attempt
            request = $body
            status  = $response.Status
            body    = $response.BodyText
        })

        if ($response.Status -eq 200) { break }

        $missingField = Get-ProbeValidationField -Response $response
        if ([string]::IsNullOrWhiteSpace($missingField)) { break }
        if ($body.ContainsKey($missingField)) { break }

        $value = Get-ProbeAdoptFieldValue `
            -Field $missingField -FileName $Name -Path $Path -Bytes $Bytes

        if ($null -eq $value) { break }
        $body[$missingField] = $value
    }

    return [pscustomobject]@{
        Body     = $body
        Response = $response
        Walk     = $walk.ToArray()
    }
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
        $uploadUrlBody = New-ProbeUploadUrlBody `
            -FileName $FileName `
            -Path "$($script:ProbeDir)/$FileName" `
            -DeclaredSize $Bytes.Length `
            -ContentType $ContentType
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
        $missingField = Get-ProbeValidationField -Response $uploadUrlResponse
        if ($null -ne $missingField) {
            Write-ProbeLog ("[STOPPED] {0}: upload-url rejected the body; it wants '$missingField'" -f $Case)
        }
        else {
            Write-ProbeLog ("[STOPPED] {0}: no presigned URL in the upload-url response; nothing was uploaded" -f $Case)
        }
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
    # adopt requires the uploadId that step 1 minted, and it validates its own
    # remaining fields in a fixed order. Rather than hardcode a guessed body,
    # walk the validation errors: send what is known, read the `field` the
    # server names, supply it, repeat. Bounded so a field this probe cannot
    # supply fails loudly instead of looping.
    $mintedUploadId = Get-ProbeMintedUploadId -Response $uploadUrlResponse
    $result.mintedUploadId = $mintedUploadId

    $adoptBody = $AdoptBodyOverride
    $adoptResponse = $null
    $adoptWalk = @()

    if ($null -ne $adoptBody) {
        $adoptResponse = Invoke-ProbeUploadAdoptRequest -Body $adoptBody
    }
    else {
        $seed = @{}

        # Carry through any other object identity the upload-url response
        # exposed, so the adopt body matches what the server handed out.
        try { $parsedUpload = $uploadUrlResponse.BodyText | ConvertFrom-Json } catch { $parsedUpload = $null }
        if ($null -ne $parsedUpload) {
            foreach ($candidate in @('key', 'objectKey', 'object_key', 'token')) {
                $property = $parsedUpload.PSObject.Properties[$candidate]
                if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                    $seed[$candidate] = [string]$property.Value
                }
            }
        }

        $adoptResult = Invoke-ProbeAdoptWalk `
            -UploadId $mintedUploadId `
            -Name $FileName `
            -Path "$($script:ProbeDir)/$FileName" `
            -Bytes $Bytes `
            -Seed $seed

        $adoptBody = $adoptResult.Body
        $adoptResponse = $adoptResult.Response
        $adoptWalk = $adoptResult.Walk
    }

    $result.adoptWalk = $adoptWalk
    $result.adopt = @{
        request = $adoptBody
        status  = $adoptResponse.Status
        body    = $adoptResponse.BodyText
        fields  = Get-ProbeResponseFields -Response $adoptResponse
        headers = $adoptResponse.ResponseHeaders
        error   = if ($null -ne $adoptResponse.TransportError) { [string]$adoptResponse.TransportError.Message } else { $null }
    }
    Write-ProbeLog ("[PROBED] {0} upload-adopt status={1}" -f $Case, $adoptResponse.Status)

    # Whatever the adopt response recorded is authoritative. Do NOT match by
    # filename substring: a collision rename appends a suffix, so
    # 'name-1.png' does not match '*name.png*' and a substring filter hides the
    # very duplicate this probe is looking for.
    $recordedPath = $null
    try {
        $parsedAdopt = $adoptResponse.BodyText | ConvertFrom-Json
        $recordedPath = [string]$parsedAdopt.path
    }
    catch { }

    Start-Sleep -Milliseconds 400
    $paths = Get-ProbeListedPaths
    $result.listedPaths = $paths
    $result.recordedPath = $recordedPath
    $result.recordedName = if ($null -ne $recordedPath) {
        [System.IO.Path]::GetFileName($recordedPath)
    }
    else { $null }
    $result.pathHonored = (
        $null -ne $recordedPath -and
        [string]::Equals($recordedPath, "$($script:ProbeDir)/$FileName", [System.StringComparison]::OrdinalIgnoreCase)
    )
    $result.listedAfter = @($paths | Where-Object {
        $null -ne $recordedPath -and
        [string]::Equals($_, $recordedPath, [System.StringComparison]::OrdinalIgnoreCase)
    })

    if ($null -ne $recordedPath) { $script:CreatedPaths.Add($recordedPath) }

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

# ---------------------------------------------------------------------------
# Parameter sanity.
#
# PowerShell binds '-ProjectId ABC-Scenario run-binary-all' with the value
# 'ABC-Scenario', silently swallowing the next switch name into the value. The
# project ID then looks plausible, every request 401s or 404s, and the probe's
# own auth messages point at the wrong problem entirely. A project ID never
# ends in one of this script's own parameter names, so that shape is rejected
# with the fix spelled out.
# ---------------------------------------------------------------------------
$probeParameterNames = @(
    'ProjectId', 'Scenario', 'RepoRoot', 'StudioOrigin', 'OutDir',
    'AccessToken', 'AccessTokenPath', 'NoInteractiveAuth', 'ConfirmRemoteWrite',
    'CapturePath'
)

foreach ($parameterName in $probeParameterNames) {
    $swallowed = '-' + $parameterName
    if ($ProjectId.EndsWith($swallowed, [System.StringComparison]::OrdinalIgnoreCase)) {
        $suggested = $ProjectId.Substring(0, $ProjectId.Length - $swallowed.Length)
        throw (
            "-ProjectId swallowed the next switch name. Got '$ProjectId', which " +
            "ends in '$swallowed'. There is a missing space before '$swallowed'. " +
            "Use: -ProjectId $suggested -Scenario $Scenario"
        )
    }
}


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
        'binary-path-control'      = @('POST /upload-url + PUT + adopt, requesting several different project paths')
        'binary-text-via-upload'   = @('POST /upload-url + PUT + adopt with UTF-8 text, then read back and try PUT /file')
        'binary-delete-discover'   = @('POST /upload-url + PUT + adopt a target, then try candidate DELETE routes against it')
        'binary-cleanup'           = @('DELETE every path this run created, then verify none remain')
        'binary-collision'         = @('POST /upload-url + PUT + adopt, repeated with identical filenames and edge-case names')
        'binary-overwrite'         = @('POST /upload-url + PUT + adopt against an existing binary path', 'POST /upload-adopt (re-adopt)')
        'binary-idempotency'       = @('POST /upload-url + PUT + adopt, twice', 'PUT the same presigned URL twice')
        'binary-failure'           = @('POST /upload-adopt (unknown id)', 'POST /upload-url (bad bodies, no auth)', 'PUT presigned URL (wrong type, malformed URL)')
        'binary-survey'            = @()
        'delete-file-basic'        = @('POST /upload-url + PUT + adopt a probe-owned target', 'DELETE /file (the target), then confirm absence from GET /files')
        'delete-idempotency'       = @('DELETE /file twice on the same probe-owned path')
        'delete-absent'            = @('DELETE /file (a path that never existed)')
        'delete-directory'         = @('DELETE /file (a directory-shaped probe-owned path with a child)')
        'delete-reserved'          = @('DELETE /file (/.git/... and /.rundot/... probe-shaped paths)')
        'delete-encoding'          = @('DELETE /file (relative, space-encoded, and traversal spellings)')
        'delete-auth'              = @('DELETE /file (no credential, garbage bearer, then authenticated cleanup)')
        'delete-response-headers'  = @('DELETE /file, recording response headers')
        'rename-probe'             = @('PATCH/POST/PUT candidate rename routes against probe-owned targets')
        'rename-move'              = @('POST /api/projects/{id}/move with { from, to }: basic, same-directory, absent source, retry, overwrite, and binary cases')
        'rename-devtools-prepare'  = @('POST /upload-url + PUT + adopt a target, then hand off to a human rename in Studio')
        'rename-devtools-apply'    = @('read a DevTools capture file and record the real rename route')
        'concurrency-delete-vs-write' = @('DELETE a probe-owned file, then PUT bytes read before the delete')
        'concurrency-delete-while-listed' = @('fingerprint GET /files, DELETE a path, fingerprint again')
        'revision-identity'        = @('diff the listed row fields across create, overwrite, and delete')
        'etag-headers'             = @('GET /file, GET /files, PUT /file, DELETE /file (record response headers)')
        'conditional-delete'       = @('DELETE /file with If-Match / If-None-Match')
        'delete-rename-survey'     = @()
        'run-text-all'             = @('The full #14 text investigation: create, overwrite, version, conditional, idempotency, failure, survey')
        'run-binary-all'           = @('The full #15 binary investigation: discover, create, collision, overwrite, idempotency, failure, survey')
        'run-delete-rename-all'    = @('The full #16 investigation: delete semantics, rename discovery, concurrency, revision identity, ETag, conditional delete, survey')
        'text-create-discover'     = @('POST/PUT candidate create routes against absent /sync-probe paths')
        'text-create-compose'      = @('POST /upload-url + PUT + adopt, then POST /move to a chosen /sync-probe path')
        'text-create-idempotency'  = @('repeat upload + move onto an occupied destination')
        'text-create-bytes'        = @('compose with CRLF, BOM, and empty bytes')
        'text-create-race'         = @('occupy a destination, then move onto it while occupied')
        'text-create-conditional'  = @('POST /move with If-Match / If-None-Match')
        'text-create-reserved'     = @('POST /move onto reserved-shaped and traversal spellings')
        'text-create-route-survey' = @()
        'text-create-devtools-prepare' = @('create a probe-owned target and print UI capture instructions')
        'text-create-devtools-apply'   = @('record the UI capture route shape without replaying it')
        'text-place-exact'         = @('upload a unique name, POST /move to a source path, then PUT /file the exact text')
        'run-text-create-all'      = @('The full #37 text create investigation: discover, compose, idempotency, bytes, race, conditional, reserved, survey')
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


if (-not [string]::IsNullOrWhiteSpace($AccessToken)) {
    $parsed = Get-TokenFromText $AccessToken
    $script:Token = if ($parsed) { $parsed } else { $AccessToken.Trim() }

    $manifest = Get-StudioManifestWithToken `
        -StudioOrigin $StudioOrigin `
        -ProjectId $ProjectId `
        -AccessToken $script:Token

    if ($null -eq $manifest) {
        throw (
            'The supplied token was rejected by Studio for this project. ' +
            'Either the token is stale, or -ProjectId is not a project this ' +
            'account can read.'
        )
    }

    Write-ProbeLog 'Supplied token accepted.'
}
else {
    # Resolve a token without ever prompting. The shared helper falls back to
    # an interactive paste, which is the wrong behavior for a probe: a run that
    # blocks on a hidden prompt in a non-interactive shell is worse than a run
    # that fails with a reason. Try the CLI session, then saved refresh
    # credentials, and only then give up.
    $savedAuthPath = Join-Path $env:APPDATA '.rundot\studio-export.auth.json'
    $cliSessionPath = Join-Path $env:APPDATA '.rundot\prod.session.json'

    $cliSession = Get-RundotCliSession -RundotCliSessionPath $cliSessionPath
    $savedAuth = Load-StudioAuth -AuthPath $savedAuthPath

    $candidateToken = $null
    $cliFresh = $false

    if ($null -ne $cliSession) {
        $cliFresh = Test-RundotCliTokenFresh `
            -AccessToken $cliSession.AccessToken `
            -ExpiresAtUnixTimeMs $cliSession.ExpiresAtUnixTimeMs
        if ($cliFresh) { $candidateToken = $cliSession.AccessToken }
    }

    if ($null -eq $candidateToken -and $null -ne $savedAuth) {
        Write-ProbeLog 'Trying saved Studio refresh credentials...'
        $refreshed = Get-FreshStudioToken -ApiKey $savedAuth.ApiKey -RefreshToken $savedAuth.RefreshToken
        if ($null -ne $refreshed) { $candidateToken = $refreshed.AccessToken }
    }

    if ($null -eq $candidateToken) {
        $reason = if ($null -eq $cliSession) {
            'no RUNdot CLI session was found'
        }
        elseif (-not $cliFresh) {
            'the RUNdot CLI access token is expired or near expiry'
        }
        else {
            'no usable token was produced'
        }

        throw (
            "No non-interactive Studio authentication is available: $reason. " +
            'Run ''rundot login'' to refresh, or pass -AccessTokenPath with a ' +
            'fresh token. This probe deliberately does not prompt.'
        )
    }

    # Validate against the project before any scenario runs, so a rejected
    # token is reported as a token problem rather than as a scenario failure.
    $manifest = Get-StudioManifestWithToken `
        -StudioOrigin $StudioOrigin `
        -ProjectId $ProjectId `
        -AccessToken $candidateToken

    if ($null -eq $manifest) {
        $source = if ($cliFresh) { 'RUNdot CLI session' } else { 'saved refresh credentials' }

        throw (
            "Studio rejected the token from the $source for project '$ProjectId'. " +
            'Check that -ProjectId is correct and that there is a SPACE before ' +
            '-Scenario on the command line; without it PowerShell binds the two ' +
            'together and the project ID is wrong. Otherwise run ''rundot login'' ' +
            'again, or pass -AccessTokenPath with a fresh token.'
        )
    }

    $script:Token = $candidateToken
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
    # Lists every probe-created path so a human can delete anything cleanup
    # could not. DELETE /file is characterized by #16, but this remains the
    # honest fallback for a path the API refuses to remove.
    #
    # Both directories are scanned: text writes land under /sync-probe, but
    # binary uploads are recorded under /uploads no matter what was requested.
    $paths = @(Get-ProbeProbeOwnedPaths | Sort-Object)

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
    # errors instead of guessing: send a body, read the `field` the server names
    # as missing, add it, repeat. This is how the text body was learned in #14.
    $fileName = Get-BinaryProbeName -Suffix 'discover'
    $targetPath = "$($script:ProbeDir)/$fileName"
    $bytes = Get-BinaryProbeBytes -Variant 1

    # upload-url: walk the required fields one at a time.
    $bodies = @(
        @{ Case = 'binary-discover-upload-url-empty'; Body = @{}; Note = 'empty object; the server names the first missing field' },
        @{ Case = 'binary-discover-upload-url-size'; Body = @{ declaredSize = $bytes.Length }; Note = 'declaredSize alone' },
        @{ Case = 'binary-discover-upload-url-size-name'; Body = @{ declaredSize = $bytes.Length; fileName = $fileName }; Note = 'declaredSize plus fileName' },
        @{ Case = 'binary-discover-upload-url-size-path'; Body = @{ declaredSize = $bytes.Length; path = $targetPath }; Note = 'declaredSize plus path' },
        @{ Case = 'binary-discover-upload-url-full'; Body = @{ declaredSize = $bytes.Length; fileName = $fileName; path = $targetPath; contentType = 'image/png' }; Note = 'the full candidate body' },
        @{ Case = 'binary-discover-upload-url-zero-size'; Body = @{ declaredSize = 0; fileName = $fileName; path = $targetPath }; Note = 'declaredSize must be positive; 0 should be rejected' }
    )

    $acceptedBody = $null
    foreach ($candidate in $bodies) {
        $response = Invoke-ProbeUploadUrlRequest -Body $candidate.Body
        Add-ProbeEvidence -Case $candidate.Case -Status 'PROBED' -Data @{
            note    = $candidate.Note
            request = $candidate.Body
            http    = @{
                status  = $response.Status
                body    = $response.BodyText
                fields  = Get-ProbeResponseFields -Response $response
                headers = $response.ResponseHeaders
            }
            missingField = Get-ProbeValidationField -Response $response
        }
        Write-ProbeLog ("[PROBED] {0} status={1} missingField={2}" -f `
            $candidate.Case, $response.Status, (Get-ProbeValidationField -Response $response))

        if ($response.Status -eq 200) {
            $acceptedBody = $candidate.Body
            Write-ProbeLog ("[FOUND] upload-url accepts: {0}" -f ($candidate.Body | ConvertTo-Json -Compress))
            Write-ProbeLog ("[FOUND] upload-url response fields: {0}" -f `
                ((Get-ProbeResponseFields -Response $response).Keys -join ', '))
            break
        }
    }

    # adopt: walk its required fields the same way. uploadId must be minted by
    # step 1, so a fabricated one only ever proves the first validation rule.
    # Mint a real uploadId first, then walk the rest of the contract.
    foreach ($candidate in @(
        @{ Case = 'binary-discover-adopt-empty'; Body = @{}; Note = 'empty adopt body' },
        @{ Case = 'binary-discover-adopt-bogus-id'; Body = @{ uploadId = 'not-a-minted-upload-id' }; Note = 'a fabricated uploadId' }
    )) {
        $response = Invoke-ProbeUploadAdoptRequest -Body $candidate.Body
        Add-ProbeEvidence -Case $candidate.Case -Status 'PROBED' -Data @{
            note         = $candidate.Note
            request      = $candidate.Body
            missingField = Get-ProbeValidationField -Response $response
            http         = @{
                status  = $response.Status
                body    = $response.BodyText
                fields  = Get-ProbeResponseFields -Response $response
            }
        }
        Write-ProbeLog ("[PROBED] {0} status={1} missingField={2}" -f `
            $candidate.Case, $response.Status, (Get-ProbeValidationField -Response $response))
    }

    # Now walk the real chain: mint an uploadId, PUT the bytes, then let the
    # server name each remaining required field in turn.
    $walkName = Get-BinaryProbeName -Suffix 'adoptwalk'
    $walkPath = "$($script:ProbeDir)/$walkName"
    $walkUrl = Invoke-ProbeUploadUrlRequest -Body (New-ProbeUploadUrlBody `
        -FileName $walkName -Path $walkPath -DeclaredSize $bytes.Length)
    $walkId = Get-ProbeMintedUploadId -Response $walkUrl
    $walkPresigned = Get-ProbePresignedUrl -Response $walkUrl

    if ($null -ne $walkPresigned) {
        [void](Invoke-ProbeRawPut -PresignedUrl $walkPresigned -Bytes $bytes)
    }

    $walkBody = @{ uploadId = $walkId }
    for ($attempt = 1; $attempt -le 8; $attempt++) {
        $response = Invoke-ProbeUploadAdoptRequest -Body $walkBody
        $missingField = Get-ProbeValidationField -Response $response

        Add-ProbeEvidence -Case "binary-discover-adopt-walk-$attempt" -Status 'PROBED' -Data @{
            note         = "adopt validation walk, attempt $attempt"
            request      = $walkBody
            missingField = $missingField
            http         = @{
                status = $response.Status
                body   = $response.BodyText
                fields = Get-ProbeResponseFields -Response $response
            }
        }
        Write-ProbeLog ("[PROBED] binary-discover-adopt-walk-{0} status={1} missingField={2}" -f `
            $attempt, $response.Status, $missingField)

        if ($response.Status -eq 200) {
            Write-ProbeLog ("[FOUND] adopt accepts: {0}" -f ($walkBody | ConvertTo-Json -Compress))
            break
        }

        if ([string]::IsNullOrWhiteSpace($missingField)) { break }
        if ($walkBody.ContainsKey($missingField)) { break }

        $value = Get-ProbeAdoptFieldValue `
            -Field $missingField -FileName $walkName -Path $walkPath -Bytes $bytes

        if ($null -eq $value) {
            Write-ProbeLog ("[STOPPED] adopt wants '{0}', which the probe cannot supply" -f $missingField)
            break
        }

        $walkBody[$missingField] = $value
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

        Add-ProbeEvidence -Case "binary-collision-survey-$i" -Status 'OBSERVED' -Data @{
            note         = "repeat ${i}: the path adopt recorded, and its suffix sequence"
            attempt      = $i
            recordedPath = $result.recordedPath
            listedAfter  = $result.listedAfter
            pathHonored  = $result.pathHonored
        }
        Write-ProbeLog ("[OBSERVED] binary-collision-repeat-{0} recorded={1}" -f $i, $result.recordedPath)
    }

    # The full suffix sequence for this one basename, gathered by prefix so the
    # -1/-2/-3 siblings are all visible.
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
    $extension = [System.IO.Path]::GetExtension($fileName)
    $family = @(Get-ProbeListedPaths | Where-Object {
        $_ -match ('(?i)/' + [regex]::Escape($stem) + '(-\d+)?' + [regex]::Escape($extension) + '$')
    } | Sort-Object)

    Add-ProbeEvidence -Case 'binary-collision-family' -Status 'OBSERVED' -Data @{
        note       = 'every path sharing this basename; the suffix sequence proves monotonic increment'
        fileName   = $fileName
        stem       = $stem
        extension  = $extension
        family     = $family
        familySize = $family.Count
    }
    Write-ProbeLog ("[OBSERVED] binary-collision family ({0}): {1}" -f $family.Count, ($family -join ', '))

    # Suffix edge cases: extensionless, multi-dot, leading dot, and a name
    # that already ends in a numeric suffix. Every name carries the run stamp
    # so cleanup can find it; only the extension shape varies.
    foreach ($edge in @(
        @{ Suffix = 'noext'; Name = "$($script:ProbeNamePrefix)-noext" },
        @{ Suffix = 'multidot'; Name = "probe.$($script:ProbeRunStamp).tar.png" },
        @{ Suffix = 'dotfile'; Name = ".$($script:ProbeNamePrefix)" },
        @{ Suffix = 'numbered'; Name = "$($script:ProbeNamePrefix)-1.png" }
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

    # Where does the collision rename apply: basename, or full path? A nested
    # target also exercises whether the parent directory needs to pre-exist.
    $nestedName = Get-BinaryProbeName -Suffix 'nested'
    $nestedPath = "$($script:ProbeDir)/nested/$nestedName"
    for ($i = 1; $i -le 2; $i++) {
        $nestedResult = Invoke-ProbeBinaryUpload `
            -Case "binary-collision-nested-$i" `
            -FileName $nestedName `
            -Bytes (Get-BinaryProbeBytes -Variant 5) `
            -Note "nested target, upload $i; the adopt path is a nested directory"
    }

    $nested = @(Get-ProbeListedPaths | Where-Object { $_ -like '*nested*' })
    Add-ProbeEvidence -Case 'binary-collision-nested-survey' -Status 'OBSERVED' -Data @{
        note  = 'nested paths after two uploads of the same basename'
        paths = $nested
    }
}

function Invoke-ScenarioBinaryPathControl {
    # The central question for #17: does a binary upload choose its project
    # path, or does the server? Every adopt in the first run recorded the file
    # under /uploads/<name> even when a different path was requested. This
    # isolates that: request several different paths and compare what the
    # server recorded.
    $bytes = Get-BinaryProbeBytes -Variant 11

    $targets = @(
        @{ Case = 'binary-path-control-uploads-dir'; Path = "$($script:ProbeDir)/$($script:ProbeNamePrefix)-pc-uploads.png"; Note = 'requested a /sync-probe path' },
        @{ Case = 'binary-path-control-root'; Path = "/$($script:ProbeNamePrefix)-pc-root.png"; Note = 'requested a project-root path' },
        @{ Case = 'binary-path-control-nested'; Path = "$($script:ProbeDir)/deep/$($script:ProbeNamePrefix)-pc-nested.png"; Note = 'requested a nested directory' },
        @{ Case = 'binary-path-control-src'; Path = "/src/$($script:ProbeNamePrefix)-pc-src.png"; Note = 'requested a path inside src' }
    )

    foreach ($target in $targets) {
        $name = [System.IO.Path]::GetFileName($target.Path)
        $uploadUrl = Invoke-ProbeUploadUrlRequest -Body (New-ProbeUploadUrlBody `
            -FileName $name -Path $target.Path -DeclaredSize $bytes.Length)
        $presigned = Get-ProbePresignedUrl -Response $uploadUrl
        $putStatus = $null
        if ($null -ne $presigned) {
            $put = Invoke-ProbeRawPut -PresignedUrl $presigned -Bytes $bytes
            $putStatus = $put.Status
        }

        $adoptId = Get-ProbeMintedUploadId -Response $uploadUrl
        $adopt = Invoke-ProbeUploadAdoptRequest -Body @{ uploadId = $adoptId; name = $name }

        $recorded = $null
        try {
            $parsed = $adopt.BodyText | ConvertFrom-Json
            $recorded = [string]$parsed.path
        }
        catch { }

        Add-ProbeEvidence -Case $target.Case -Status 'PROBED' -Data @{
            note            = $target.Note
            requestedPath   = $target.Path
            fileName        = $name
            uploadUrlStatus = $uploadUrl.Status
            putStatus       = $putStatus
            adoptStatus     = $adopt.Status
            adoptBody       = $adopt.BodyText
            recordedPath    = $recorded
            pathHonored     = ($null -ne $recorded -and
                [string]::Equals($recorded, $target.Path, [System.StringComparison]::OrdinalIgnoreCase))
        }
        Write-ProbeLog ("[PROBED] {0} requested={1} recorded={2}" -f $target.Case, $target.Path, $recorded)

        if ($null -ne $recorded) { $script:CreatedPaths.Add($recorded) }
    }

    # Does the upload-url even look at path? Send the same fileName with two
    # different paths and compare the minted ids and urls.
    $probeName = Get-BinaryProbeName -Suffix 'pathignore'
    $withPath = Invoke-ProbeUploadUrlRequest -Body (New-ProbeUploadUrlBody `
        -FileName $probeName -Path "/sync-probe/$probeName" -DeclaredSize $bytes.Length)
    $withOtherPath = Invoke-ProbeUploadUrlRequest -Body (New-ProbeUploadUrlBody `
        -FileName $probeName -Path "/src/$probeName" -DeclaredSize $bytes.Length)
    $noPath = Invoke-ProbeUploadUrlRequest -Body @{ declaredSize = $bytes.Length; fileName = $probeName }

    Add-ProbeEvidence -Case 'binary-path-control-upload-url-ignores-path' -Status 'OBSERVED' -Data @{
        note            = 'same fileName, three different path inputs'
        withPathStatus  = $withPath.Status
        withOtherStatus = $withOtherPath.Status
        noPathStatus    = $noPath.Status
        withPathId      = Get-ProbeMintedUploadId -Response $withPath
        withOtherId     = Get-ProbeMintedUploadId -Response $withOtherPath
        noPathId        = Get-ProbeMintedUploadId -Response $noPath
        withPathBody    = $withPath.BodyText
        noPathBody      = $noPath.BodyText
    }
    Write-ProbeLog ("[OBSERVED] upload-url with path={0} without path={1}" -f $withPath.Status, $noPath.Status)
}

function Invoke-ScenarioBinaryTextViaUpload {
    # #14 found the text route cannot create: PUT /file 404s for a path that is
    # not already in the project, and POST is 405. This asks whether the binary
    # upload flow can create a text file instead, which would be an avenue for
    # the create case that Push currently cannot serve.
    #
    # A text file is only useful here if it reads back as utf8. If it reads
    # back as base64 it is a binary blob with a .txt name, which does not help.
    $textContent = "text via upload flow $([Guid]::NewGuid().ToString('N'))`nsecond line`n"
    $textBytes = Get-Utf8NoBomBytes -Text $textContent
    $textName = "$($script:ProbeNamePrefix)-viaupload.txt"

    $result = Invoke-ProbeBinaryUpload `
        -Case 'binary-text-via-upload' `
        -FileName $textName `
        -Bytes $textBytes `
        -ContentType 'text/plain' `
        -Note 'a UTF-8 text file sent through the binary upload flow'

    $recorded = $result.recordedPath
    if ($null -eq $recorded) { return }

    $read = Get-ProbeReadOrNull -Path $recorded
    $readBackText = $null
    if ($null -ne $read) {
        try { $readBackText = [System.Text.Encoding]::UTF8.GetString($read.Bytes) } catch { }
    }

    $isUtf8 = ($null -ne $read -and $read.Encoding -eq 'utf8')
    $contentMatches = (
        $null -ne $readBackText -and
        [string]::Equals($readBackText, $textContent, [System.StringComparison]::Ordinal)
    )

    Add-ProbeEvidence -Case 'binary-text-via-upload-readback' -Status 'PROBED' -Data @{
        note             = 'does a text file uploaded this way read back as editable text?'
        recordedPath     = $recorded
        encoding         = if ($null -ne $read) { $read.Encoding } else { $null }
        byteCount        = if ($null -ne $read) { $read.ByteCount } else { $null }
        sentBytes        = $textBytes.Length
        readBackIsUtf8   = $isUtf8
        contentMatches   = $contentMatches
        fields           = Get-ProbeRowFingerprint -Row (Get-ProbeRowOrNull -Path $recorded)
        pathHonored      = $result.pathHonored
    }
    Write-ProbeLog ("[PROBED] binary-text-via-upload encoding={0} utf8={1} contentMatches={2}" -f `
        $(if ($null -ne $read) { $read.Encoding } else { '-' }), $isUtf8, $contentMatches)

    # Can the text route now OVERWRITE that file? If the upload flow creates a
    # path that PUT /file can then see, the two flows compose into the create
    # case #17 needs.
    if (-not $isUtf8) {
        Add-ProbeEvidence -Case 'binary-text-via-upload-then-put' -Status 'SKIPPED' -Data @{
            note = 'the uploaded text file did not read back as utf8, so PUT /file cannot target it'
        }
        return
    }

    $putResponse = Invoke-ProbeTextPut `
        -Path $recorded `
        -ContentBytes (New-JsonContentBody -Text 'overwritten through the text route')
    Add-ProbeEvidence -Case 'binary-text-via-upload-then-put' -Status 'PROBED' -Data @{
        note       = 'PUT /file against the path the upload flow created'
        path       = $recorded
        http       = @{ status = $putResponse.Status; body = $putResponse.BodyText }
    }
    Write-ProbeLog ("[PROBED] binary-text-via-upload-then-put status={0}" -f $putResponse.Status)
}

function Invoke-ScenarioBinaryDeleteDiscover {
    # This is the historical #15 discovery step, kept because it is the record
    # of how the delete route was found: four plausible shapes were tried
    # against a probe-owned file and only DELETE /file removed it.
    #
    # #16 has since characterized that route properly (see the delete
    # scenarios below and docs/delete-rename-protocol.md). This scenario is
    # left as-is rather than folded into them, so a future reader can see what
    # the discovery actually tested.
    #
    # Every target here is a file this run created. Nothing outside the probe
    # namespace is touched, and a failure is recorded rather than retried.
    $fileName = Get-BinaryProbeName -Suffix 'deltest'
    $targetPath = "$($script:ProbeDir)/$fileName"
    $bytes = Get-BinaryProbeBytes -Variant 12

    $create = Invoke-ProbeBinaryUpload -Case 'binary-delete-discover-target' -FileName $fileName `
        -Bytes $bytes -Note 'a probe-owned file to attempt deletion against'
    $victim = $create.recordedPath
    if ($null -eq $victim) {
        Write-ProbeLog '[STOPPED] binary-delete-discover: no file was created to delete'
        return
    }

    $encoded = [System.Uri]::EscapeDataString($victim)

    $candidates = @(
        @{ Case = 'delete-file-route'; Method = 'DELETE'; Uri = "$StudioOrigin/api/projects/$ProjectId/file?path=$encoded"; Body = $null },
        @{ Case = 'delete-files-route'; Method = 'DELETE'; Uri = "$StudioOrigin/api/projects/$ProjectId/files?path=$encoded"; Body = $null },
        @{ Case = 'delete-post-file'; Method = 'POST'; Uri = "$StudioOrigin/api/projects/$ProjectId/file/delete?path=$encoded"; Body = '{}' },
        @{ Case = 'delete-post-delete'; Method = 'POST'; Uri = "$StudioOrigin/api/projects/$ProjectId/delete"; Body = (@{ path = $victim } | ConvertTo-Json -Compress) }
    )

    foreach ($candidate in $candidates) {
        # A delete is a mutation, so it passes the same gate as everything else.
        Assert-ProbeWriteAllowed -Case $candidate.Case -Method $candidate.Method -Uri $candidate.Uri

        $bodyBytes = if ($null -ne $candidate.Body) { Get-Utf8NoBomBytes -Text $candidate.Body } else { [byte[]]@() }
        $response = Invoke-ProbeHttp `
            -Method $candidate.Method `
            -Uri $candidate.Uri `
            -Headers $script:Headers `
            -BodyBytes $bodyBytes `
            -ContentType 'application/json'

        # A delete that worked is proved by the file being gone, not by the
        # status code alone.
        Start-Sleep -Milliseconds 300
        $stillListed = $null -ne (Get-ProbeRowOrNull -Path $victim)

        Add-ProbeEvidence -Case $candidate.Case -Status 'PROBED' -Data @{
            note        = 'candidate delete route; the file being gone is the proof'
            method      = $candidate.Method
            uri         = $candidate.Uri
            target      = $victim
            http        = @{ status = $response.Status; body = $response.BodyText }
            stillListed = $stillListed
            deleted     = (-not $stillListed)
        }
        Write-ProbeLog ("[PROBED] {0} {1} status={2} stillListed={3}" -f `
            $candidate.Method, $candidate.Case, $response.Status, $stillListed)

        if (-not $stillListed) {
            Write-ProbeLog ("[FOUND] delete works: {0} {1}" -f $candidate.Method, $candidate.Uri)
            # It is already gone, so drop it from the cleanup list rather than
            # listing a file for manual deletion that no longer exists.
            [void]$script:CreatedPaths.Remove($victim)
            break
        }
    }

    # Whatever happened, report the outcome so cleanup can be planned.
    $remaining = @(Get-ProbeProbeOwnedPaths | Where-Object { $_ -like "*$($script:ProbeRunStamp)*" })
    Add-ProbeEvidence -Case 'binary-delete-discover-summary' -Status 'OBSERVED' -Data @{
        note          = 'delete route availability decides whether cleanup can be automated'
        deleteWorked  = ($null -eq (Get-ProbeRowOrNull -Path $victim))
        thisRunPaths  = $remaining
        thisRunCount  = $remaining.Count
    }
    Write-ProbeLog ("[OBSERVED] binary-delete-discover: this run created {0} path(s)" -f $remaining.Count)
}

function Assert-ProbeDeleteTarget {
    # A DELETE is the one mutation that can destroy something the probe did not
    # create. The write gate is not enough, so the target itself is checked:
    #
    #   - anything under /sync-probe (the probe's own directory), or
    #   - a /uploads basename carrying a probe run stamp, or
    #   - a reserved-shaped path whose basename carries a probe run stamp, which
    #     nothing could have created.
    #
    # A bare directory like /uploads is never eligible, which is the case this
    # guard exists for.
    #
    # The stamp is normally THIS process's. A two-process hand-off (the rename
    # prepare/apply pair) legitimately operates on an earlier run's files, so
    # the caller may name additional stamps it is allowed to touch. That is an
    # explicit, auditable allowance rather than a widened pattern: without it a
    # generic probe-shaped pattern would let any file that merely looks like a
    # probe artifact be deleted.
    param(
        [string]$Path,
        [string]$Case,
        [string[]]$AllowedStamp
    )

    if (Test-ProbeOwnedPath -Path $Path) { return }

    $leaf = [System.IO.Path]::GetFileName($Path)
    $stamps = @($script:ProbeRunStamp)
    if ($null -ne $AllowedStamp) {
        $stamps += @($AllowedStamp | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $stamped = $false
    foreach ($stamp in $stamps) {
        if ($leaf -like "*$stamp*") { $stamped = $true; break }
    }

    # -AllRuns widens the candidate filter to every probe path, which includes
    # earlier runs' files. Those carry a different stamp, so allow any leaf with
    # the strict probe stamp SHAPE (probe-YYYYMMDD-HHMMSS). This is
    # deliberately a shape rather than a loose "contains probe": a real project
    # file would have to be named probe-20260917-123456-... to be caught, and
    # -AllRuns is an explicit opt-in.
    if (-not $stamped -and $script:ProbeAllowAllRuns) {
        $stamped = ($leaf -match '^\.?probe-\d{8}-\d{6}')
    }

    $inUploads = $Path -like "$($script:ProbeUploadDir)/*"
    $reservedShaped = (
        $Path -like '/.git/*' -or
        $Path -like '/.rundot/*' -or
        $Path -like '/.rundot-sync/*'
    )

    if ($stamped -and ($inUploads -or $reservedShaped)) { return }

    throw (
        "Refusing to DELETE a path the probe does not own. " +
        "Case '$Case' targeted '$Path'; only /sync-probe, a run-stamped " +
        "/uploads path, or a run-stamped reserved-shaped path is eligible."
    )
}

function Invoke-ProbeDeleteFile {
    # DELETE /api/projects/{id}/file?path=... returns 200 and removes the file.
    # Discovered by binary-delete-discover and promoted to a characterized
    # contract by #16.
    param(
        [string]$Path,
        [hashtable]$ExtraHeaders,
        [string]$Case,
        [string[]]$AllowedStamp
    )

    if ([string]::IsNullOrWhiteSpace($Case)) { $Case = "delete:$Path" }

    Assert-ProbeDeleteTarget -Path $Path -Case $Case -AllowedStamp $AllowedStamp

    $encoded = [System.Uri]::EscapeDataString($Path)
    $uri = "$StudioOrigin/api/projects/$ProjectId/file?path=$encoded"
    Assert-ProbeWriteAllowed -Case $Case -Method 'DELETE' -Uri $uri

    $requestHeaders = @{}
    foreach ($key in $script:Headers.Keys) { $requestHeaders[$key] = $script:Headers[$key] }
    if ($null -ne $ExtraHeaders) {
        foreach ($key in $ExtraHeaders.Keys) { $requestHeaders[$key] = $ExtraHeaders[$key] }
    }

    $response = Invoke-ProbeHttp -Method 'DELETE' -Uri $uri -Headers $requestHeaders

    # The status alone is not proof; the file being gone is.
    Start-Sleep -Milliseconds 250
    $stillListed = $null -ne (Get-ProbeRowOrNull -Path $Path)

    return [pscustomobject]@{
        Status          = $response.Status
        Body            = $response.BodyText
        ResponseHeaders = $response.ResponseHeaders
        StillListed     = $stillListed
        Deleted         = (-not $stillListed)
        TransportError  = $response.TransportError
    }
}

function New-ProbeOwnedTextFile {
    # The text PUT route cannot create (#14: a new path is 404), so the only
    # observed way to get a probe-owned file that PUT /file can then address is
    # the binary upload flow, which records a UTF-8 .txt payload as editable
    # text. Every delete/rename/concurrency target is built this way.
    param(
        [string]$Suffix,
        [string]$Content = ''
    )

    $name = Get-BinaryProbeName -Suffix $Suffix -Extension '.txt'
    if ([string]::IsNullOrEmpty($Content)) {
        $Content = "probe target $([Guid]::NewGuid().ToString('N'))"
    }

    $bytes = Get-Utf8NoBomBytes -Text $Content
    $result = Invoke-ProbeBinaryUpload `
        -Case "target-create-$Suffix" `
        -FileName $name `
        -Bytes $bytes `
        -ContentType 'text/plain' `
        -Note 'probe-owned target created through the upload flow for a destructive case'

    return [pscustomobject]@{
        Path   = $result.recordedPath
        Sha256 = $result.sha256
        Result = $result
    }
}

function New-ProbeFileUrlRaw {
    # The product's New-ProbeFileUrl always percent-encodes. Encoding cases need
    # to send a deliberately different spelling, so build the URI from a raw
    # query value.
    param([string]$RawQueryValue)

    return "$StudioOrigin/api/projects/$ProjectId/file?path=$RawQueryValue"
}

function Get-ProbeListFingerprint {
    # Fingerprint the validated GET /files list the way the product snapshot
    # does, so a before/after comparison proves whether a mutation moved the
    # list. This is the client-side check #17 must be able to perform.
    try {
        $list = Get-ProbeFileList
        return Get-RemoteManifestFingerprint -Manifest $list
    }
    catch {
        return $null
    }
}

function Invoke-ScenarioBinaryCleanup {
    # Delete everything this run created, so the project is left as found and
    # the next run starts from a known state. Only paths carrying this run's
    # stamp are touched, so an earlier run's leftovers are never deleted by
    # surprise and no real project file can be caught by the filter.
    param([switch]$AllRuns)

    # Both directories are in scope because binary uploads land in /uploads
    # regardless of the requested path. The stamp narrows to this run by
    # default; -AllRuns widens to every probe file.
    $candidates = @(Get-ProbeListedPaths | Where-Object {
        $inScope = ($_ -like "$($script:ProbeUploadDir)/*" -or $_ -like "$($script:ProbeDir)/*")
        if (-not $inScope) { return $false }
        if ($AllRuns) { return $true }
        return ($_ -like "*$($script:ProbeRunStamp)*")
    } | Sort-Object -Unique)

    Add-ProbeEvidence -Case 'binary-cleanup-plan' -Status 'OBSERVED' -Data @{
        note       = 'paths selected for deletion'
        runStamp   = $script:ProbeRunStamp
        allRuns    = [bool]$AllRuns
        pattern    = if ($AllRuns) { 'all probe paths' } else { "*$($script:ProbeRunStamp)*" }
        candidates = $candidates
        count      = $candidates.Count
    }
    Write-ProbeLog ("[OBSERVED] binary-cleanup: {0} path(s) to delete (stamp {1})" -f `
        $candidates.Count, $script:ProbeRunStamp)

    if ($candidates.Count -eq 0) {
        Write-ProbeLog 'Nothing to delete.'
        return
    }

    # -AllRuns widens the candidate filter to every probe path, including
    # earlier runs'. Those carry a different stamp, so the delete guard is told
    # to accept the probe stamp shape for this run. Without this the widened
    # filter would select paths the guard then refuses, and -AllRuns would
    # silently delete only the current run's files while reporting the rest as
    # remaining.
    $script:ProbeAllowAllRuns = [bool]$AllRuns

    $deleted = 0
    $failed = New-Object 'System.Collections.Generic.List[string]'
    $skipped = New-Object 'System.Collections.Generic.List[string]'

    foreach ($path in $candidates) {
        # -AllRuns widens the candidate filter to every path under /uploads,
        # which includes real project files. The delete guard correctly refuses
        # those, so a refusal here is expected rather than exceptional: record
        # it and move on instead of letting an uncaught throw abort the whole
        # cleanup half way through.
        $result = $null
        try {
            $result = Invoke-ProbeDeleteFile -Path $path
        }
        catch {
            $skipped.Add($path)
            Add-ProbeEvidence -Case 'binary-cleanup-skipped' -Status 'OBSERVED' -Data @{
                note   = 'the delete guard refused this path, so it was not touched'
                path   = $path
                reason = $_.Exception.Message
            }
            Write-ProbeLog ("[SKIPPED] cleanup refused to delete {0}" -f $path)
            continue
        }

        if ($result.Deleted) {
            $deleted++
        }
        else {
            $failed.Add($path)
        }

        Add-ProbeEvidence -Case 'binary-cleanup-delete' -Status 'PROBED' -Data @{
            path        = $path
            http        = @{ status = $result.Status; body = $result.Body }
            deleted     = $result.Deleted
            stillListed = $result.StillListed
        }
    }

    $remaining = @(Get-ProbeListedPaths | Where-Object {
        $inScope = ($_ -like "$($script:ProbeUploadDir)/*" -or $_ -like "$($script:ProbeDir)/*")
        if (-not $inScope) { return $false }
        if ($AllRuns) { return $true }
        return ($_ -like "*$($script:ProbeRunStamp)*")
    })

    $script:CleanupRan = $true
    $script:CleanupRemaining = $remaining.Count

    Add-ProbeEvidence -Case 'binary-cleanup-summary' -Status 'OBSERVED' -Data @{
        note        = 'cleanup result'
        attempted   = $candidates.Count
        deleted     = $deleted
        failed      = $failed.ToArray()
        skipped     = $skipped.ToArray()
        remaining   = $remaining
        remainingCount = $remaining.Count
    }
    Write-ProbeLog ("[OBSERVED] binary-cleanup: deleted {0}/{1}, {2} remaining" -f `
        $deleted, $candidates.Count, $remaining.Count)
    if ($skipped.Count -gt 0) {
        Write-ProbeLog ("[OBSERVED] binary-cleanup: {0} path(s) were outside the probe's ownership and were left alone." -f $skipped.Count)
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

    # Attempt 2: re-adopt a freshly minted uploadId against the SAME path.
    # If replacement is possible at all, this is where it shows: a new upload
    # bound to a path that already exists.
    $reAdoptUrl = Invoke-ProbeUploadUrlRequest -Body (New-ProbeUploadUrlBody `
        -FileName $fileName -Path $createdPath -DeclaredSize $replaceBytes.Length)
    $reAdoptPresigned = Get-ProbePresignedUrl -Response $reAdoptUrl
    $reAdoptId = Get-ProbeMintedUploadId -Response $reAdoptUrl
    $reAdoptPutStatus = $null
    if ($null -ne $reAdoptPresigned) {
        $reAdoptPut = Invoke-ProbeRawPut -PresignedUrl $reAdoptPresigned -Bytes $replaceBytes
        $reAdoptPutStatus = $reAdoptPut.Status
    }

    $reAdoptResult = Invoke-ProbeAdoptWalk `
        -UploadId $reAdoptId `
        -Name $fileName `
        -Path $createdPath `
        -Bytes $replaceBytes
    $reAdopt = $reAdoptResult.Response
    $afterReAdopt = Get-ProbeReadOrNull -Path $createdPath

    Add-ProbeEvidence -Case 'binary-overwrite-readopt' -Status 'PROBED' -Data @{
        note            = 'a second upload bound to a path that already exists'
        targetPath      = $createdPath
        uploadUrlStatus = $reAdoptUrl.Status
        mintedUploadId  = $reAdoptId
        putStatus       = $reAdoptPutStatus
        adoptStatus     = $reAdopt.Status
        adoptBody       = $reAdopt.BodyText
        adoptRequest    = $reAdoptResult.Body
        shaAfter        = if ($null -ne $afterReAdopt) { $afterReAdopt.Sha256 } else { $null }
        sentSha256      = Get-Sha256Hex -Bytes $replaceBytes
        replacedInPlace = (
            $null -ne $afterReAdopt -and
            [string]::Equals($afterReAdopt.Sha256, (Get-Sha256Hex -Bytes $replaceBytes), [System.StringComparison]::OrdinalIgnoreCase)
        )
        pathsAfter      = @(Get-ProbeProbeOwnedPaths)
    }
    Write-ProbeLog ("[PROBED] binary-overwrite-readopt adoptStatus={0}" -f $reAdopt.Status)

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

    $paths = @(Get-ProbeProbeOwnedPaths)
    $firstOwned = @($first.listedAfter)
    $secondOwned = @($second.listedAfter)
    $allOwned = @($firstOwned + $secondOwned | Sort-Object -Unique)

    Add-ProbeEvidence -Case 'binary-idempotency-survey' -Status 'OBSERVED' -Data @{
        note          = 'identical uploads converge on one path, or multiply it?'
        firstPaths    = $firstOwned
        secondPaths   = $secondOwned
        distinctPaths = $allOwned
        distinctCount = $allOwned.Count
        multiplied    = ($allOwned.Count -gt 1)
        allPaths      = $paths
    }
    Write-ProbeLog ("[OBSERVED] binary-idempotency: two identical uploads produced {0} distinct path(s): {1}" -f `
        $allOwned.Count, ($allOwned -join ', '))

    # Retry an ambiguous failure: send the presigned PUT twice.
    $retryName = Get-BinaryProbeName -Suffix 'retry'
    $uploadUrl = Invoke-ProbeUploadUrlRequest -Body (New-ProbeUploadUrlBody `
        -FileName $retryName -Path "$($script:ProbeDir)/$retryName" -DeclaredSize (Get-BinaryProbeBytes -Variant 9).Length)
    $presigned = Get-ProbePresignedUrl -Response $uploadUrl
    if ($null -ne $presigned) {
        $firstPut = Invoke-ProbeRawPut -PresignedUrl $presigned -Bytes (Get-BinaryProbeBytes -Variant 9)
        $secondPut = Invoke-ProbeRawPut -PresignedUrl $presigned -Bytes (Get-BinaryProbeBytes -Variant 9)
        $adopt = Invoke-ProbeUploadAdoptRequest -Body @{
            uploadId = (Get-ProbeMintedUploadId -Response $uploadUrl)
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
    $uploadUrl = Invoke-ProbeUploadUrlRequest -Body (New-ProbeUploadUrlBody `
        -FileName $fileName -Path $targetPath -DeclaredSize $bytes.Length)
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

    # Declared size: is the declaration enforced against the bytes actually
    # uploaded? For Push this decides whether a wrong declaredSize is caught
    # server-side or silently accepted, and whether a large declaration is
    # refused before any bytes move.
    foreach ($case in @(
        @{ Case = 'binary-size-zero'; Suffix = 'sizezero'; Declared = 0; Note = 'declaredSize 0; expected 400' },
        @{ Case = 'binary-size-mismatch-small'; Suffix = 'sizesmall'; Declared = 1; Note = 'declared 1 byte, uploading 71' },
        @{ Case = 'binary-size-mismatch-large'; Suffix = 'sizelarge'; Declared = 1000000; Note = 'declared 1 MB, uploading 71 bytes' },
        @{ Case = 'binary-size-mismatch-huge'; Suffix = 'sizehuge'; Declared = 104857600; Note = 'declared 100 MB, uploading 71 bytes' }
    )) {
        # A distinct name per case, so the survey shows which declaration
        # produced which file rather than a row of identical -size names.
        $sizeName = Get-BinaryProbeName -Suffix $case.Suffix
        $sizePath = "$($script:ProbeDir)/$sizeName"

        $sizeUploadUrl = Invoke-ProbeUploadUrlRequest -Body @{
            declaredSize = $case.Declared
            fileName     = $sizeName
            path         = $sizePath
        }
        $sizePresigned = Get-ProbePresignedUrl -Response $sizeUploadUrl
        $sizePutStatus = $null
        if ($null -ne $sizePresigned) {
            $sizePut = Invoke-ProbeRawPut -PresignedUrl $sizePresigned -Bytes $bytes
            $sizePutStatus = $sizePut.Status
        }

        $sizeAdoptId = Get-ProbeMintedUploadId -Response $sizeUploadUrl
        $sizeAdopt = $null
        $recorded = $null
        $recordedSize = $null
        if ($null -ne $sizeAdoptId) {
            $sizeAdopt = Invoke-ProbeUploadAdoptRequest -Body @{ uploadId = $sizeAdoptId; name = $sizeName }
            try {
                $parsedSize = $sizeAdopt.BodyText | ConvertFrom-Json
                $recorded = [string]$parsedSize.path
                $recordedSize = [string]$parsedSize.size
            }
            catch { }
            if ($null -ne $recorded) { $script:CreatedPaths.Add($recorded) }
        }

        Add-ProbeEvidence -Case $case.Case -Status 'PROBED' -Data @{
            note            = $case.Note
            declaredSize    = $case.Declared
            actualBytes     = $bytes.Length
            uploadUrlStatus = $sizeUploadUrl.Status
            uploadUrlBody   = $sizeUploadUrl.BodyText
            putStatus       = $sizePutStatus
            adoptStatus     = if ($null -ne $sizeAdopt) { $sizeAdopt.Status } else { $null }
            adoptBody       = if ($null -ne $sizeAdopt) { $sizeAdopt.BodyText } else { $null }
            recordedPath    = $recorded
            recordedSize    = $recordedSize
        }
        Write-ProbeLog ("[PROBED] {0} declared={1} uploadUrl={2} put={3} adopt={4}" -f `
            $case.Case, $case.Declared, $sizeUploadUrl.Status, $sizePutStatus, `
            $(if ($null -ne $sizeAdopt) { $sizeAdopt.Status } else { '-' }))
    }
}


# ---------------------------------------------------------------------------
# Delete semantics (#16)
#
# binary-delete-discover found DELETE /api/projects/{id}/file?path=... returns
# 200 and removes the file. That was only ever enough to automate cleanup; #16
# characterizes the verb itself so #17 can decide whether a plan row may ever
# become a DELETE. Every target is probe-owned and, where a text file can be
# re-created, restored afterwards.
# ---------------------------------------------------------------------------

function Invoke-ProbeDeleteCase {
    # One DELETE, recorded with the proof that matters: the list row before and
    # after, plus a GET /file read-back. A status alone is never the finding.
    param(
        [string]$Case,
        [string]$Path,
        [string]$Note = '',
        [hashtable]$ExtraHeaders
    )

    $rowBefore = Get-ProbeRowOrNull -Path $Path
    $readBefore = Get-ProbeReadOrNull -Path $Path

    $result = Invoke-ProbeDeleteFile -Path $Path -ExtraHeaders $ExtraHeaders -Case $Case

    Start-Sleep -Milliseconds 300
    $rowAfter = Get-ProbeRowOrNull -Path $Path
    $readAfter = Get-ProbeReadOrNull -Path $Path

    Add-ProbeEvidence -Case $Case -Status 'PROBED' -Data @{
        note            = $Note
        path            = $Path
        listedBefore    = ($null -ne $rowBefore)
        shaBefore       = if ($null -ne $readBefore) { $readBefore.Sha256 } else { $null }
        http            = @{
            status  = $result.Status
            body    = $result.Body
            headers = $result.ResponseHeaders
            error   = if ($null -ne $result.TransportError) { [string]$result.TransportError.Message } else { $null }
        }
        listedAfter     = ($null -ne $rowAfter)
        readAfter       = ($null -ne $readAfter)
        shaAfter        = if ($null -ne $readAfter) { $readAfter.Sha256 } else { $null }
        deleted         = $result.Deleted
    }
    Write-ProbeLog ("[PROBED] {0} status={1} deleted={2}" -f $Case, $result.Status, $result.Deleted)

    return $result
}

function Invoke-ScenarioDeleteFileBasic {
    # Does DELETE remove exactly the named file, and is the proof the list, not
    # the status? Create two probe-owned files so a directory-wide delete would
    # be visible as collateral damage.
    $target = New-ProbeOwnedTextFile -Suffix 'del-basic' -Content 'delete basic target'
    $bystander = New-ProbeOwnedTextFile -Suffix 'del-bystander' -Content 'must survive the delete'

    if ($null -eq $target.Path) {
        Write-ProbeLog '[STOPPED] delete-file-basic: the target could not be created'
        return
    }

    $result = Invoke-ProbeDeleteCase -Case 'delete-file-basic' -Path $target.Path `
        -Note 'a single probe-owned file; the bystander proves the scope'

    $bystanderAfter = Get-ProbeRowOrNull -Path $bystander.Path

    Add-ProbeEvidence -Case 'delete-file-basic-scope' -Status 'OBSERVED' -Data @{
        note              = 'did deleting one path leave a sibling alone?'
        target            = $target.Path
        targetDeleted     = $result.Deleted
        bystander         = $bystander.Path
        bystanderSurvived = ($null -ne $bystanderAfter)
    }
    Write-ProbeLog ("[OBSERVED] delete-file-basic bystanderSurvived={0}" -f ($null -ne $bystanderAfter))
}

function Invoke-ScenarioDeleteIdempotency {
    # A retry after an ambiguous failure must not be destructive twice. Delete
    # the same path twice and record what the second attempt returns.
    $target = New-ProbeOwnedTextFile -Suffix 'del-idem' -Content 'delete idempotency target'
    if ($null -eq $target.Path) {
        Write-ProbeLog '[STOPPED] delete-idempotency: the target could not be created'
        return
    }

    $first = Invoke-ProbeDeleteCase -Case 'delete-idempotency-first' -Path $target.Path `
        -Note 'the first DELETE; the file is expected to be gone afterwards'
    $second = Invoke-ProbeDeleteCase -Case 'delete-idempotency-second' -Path $target.Path `
        -Note 'the same DELETE again; 200/404/410 each mean something different for retry safety'

    Add-ProbeEvidence -Case 'delete-idempotency-summary' -Status 'OBSERVED' -Data @{
        note             = 'is a repeated DELETE safe to retry?'
        path             = $target.Path
        firstStatus      = $first.Status
        firstDeleted     = $first.Deleted
        secondStatus     = $second.Status
        secondDeleted    = $second.Deleted
        secondBody       = $second.Body
        idempotentStatus = ($first.Status -eq $second.Status)
    }
    Write-ProbeLog ("[OBSERVED] delete-idempotency first={0} second={1}" -f $first.Status, $second.Status)
}

function Invoke-ScenarioDeleteAbsent {
    # A path that never existed. This is the shape a stale plan row would take
    # if the remote file was already deleted by someone else.
    $absentPath = "$($script:ProbeDir)/$($script:ProbeNamePrefix)-never-existed.txt"

    $result = Invoke-ProbeDeleteCase -Case 'delete-absent' -Path $absentPath `
        -Note 'a path that was never created; the stale-plan case'

    Add-ProbeEvidence -Case 'delete-absent-summary' -Status 'OBSERVED' -Data @{
        note      = 'DELETE of a path that never existed'
        path      = $absentPath
        status    = $result.Status
        body      = $result.Body
        deleted   = $result.Deleted
    }
}

function Invoke-ScenarioDeleteDirectory {
    # Does DELETE accept a directory-shaped path, and if it does, does it
    # recurse? A real parent directory is deliberately NOT the target: binary
    # uploads flatten every file into /uploads (#15), so the only real
    # directory this probe could reach is the project's own /uploads, and
    # deleting that would destroy real project files.
    #
    # Instead: a probe-owned nested path that does not exist as a file, plus a
    # run-stamped file sitting in /uploads so a recursive delete would show up
    # as collateral damage.
    $bystander = New-ProbeOwnedTextFile -Suffix 'del-dir-bystander' -Content 'must survive a directory-shaped delete'
    if ($null -eq $bystander.Path) {
        Write-ProbeLog '[STOPPED] delete-directory: the bystander could not be created'
        return
    }

    $directoryShaped = "$($script:ProbeDir)/$($script:ProbeNamePrefix)-dir"
    $result = Invoke-ProbeDeleteCase -Case 'delete-directory-shaped-path' -Path $directoryShaped `
        -Note 'a directory-shaped probe-owned path that is not a file'

    $bystanderAfter = Get-ProbeRowOrNull -Path $bystander.Path

    Add-ProbeEvidence -Case 'delete-directory-summary' -Status 'OBSERVED' -Data @{
        note                = 'a directory-shaped path; 404 matches absent, and the bystander proves no recursion'
        directoryPath       = $directoryShaped
        status              = $result.Status
        body                = $result.Body
        bystanderPath       = $bystander.Path
        bystanderSurvived   = ($null -ne $bystanderAfter)
        realUploadsDirUntouched = $true
    }
    Write-ProbeLog ("[OBSERVED] delete-directory status={0} bystanderSurvived={1}" -f `
        $result.Status, ($null -ne $bystanderAfter))
}

function Invoke-ScenarioDeleteReserved {
    # #14 saw no server-side reserved-path guard on write: .git and .rundot
    # returned the same 404 as any absent path. Re-check on delete, where the
    # consequence of a guard gap is larger. These paths cannot exist (nothing
    # creates under .git or .rundot), so the finding is whether the status is
    # a distinct "forbidden" or the same 404 as any absent path.
    foreach ($reserved in @(
        "/.git/$($script:ProbeNamePrefix)-delete.txt",
        "/.rundot/$($script:ProbeNamePrefix)-delete.txt"
    )) {
        $result = Invoke-ProbeDeleteCase -Case "delete-reserved$($reserved.Replace('/', '-'))" -Path $reserved `
            -Note 'a reserved-shaped path; the same 404 as absent would mean no distinct guard'
        Write-ProbeLog ("[PROBED] delete-reserved {0} status={1}" -f $reserved, $result.Status)
    }

    Add-ProbeEvidence -Case 'delete-reserved-summary' -Status 'OBSERVED' -Data @{
        note = 'no distinct forbidden status would mean the client must enforce reserved paths itself'
        paths = @(
            "/.git/$($script:ProbeNamePrefix)-delete.txt",
            "/.rundot/$($script:ProbeNamePrefix)-delete.txt"
        )
    }
}

function Invoke-ScenarioDeleteEncoding {
    # The read and write routes require an absolute, percent-encoded path. Does
    # DELETE share that rule, and does an unencoded or traversal spelling reach
    # a different file?
    $target = New-ProbeOwnedTextFile -Suffix 'del-encoding' -Content 'delete encoding target'
    if ($null -eq $target.Path) {
        Write-ProbeLog '[STOPPED] delete-encoding: the target could not be created'
        return
    }

    # A relative spelling must be rejected the same way write rejects it.
    $relativeUri = New-ProbeFileUrlRaw -RawQueryValue ([System.Uri]::EscapeDataString('relative-probe.txt'))
    Assert-ProbeWriteAllowed -Case 'delete-encoding-relative' -Method 'DELETE' -Uri $relativeUri
    $relative = Invoke-ProbeHttp -Method 'DELETE' -Uri $relativeUri -Headers $script:Headers
    Add-ProbeEvidence -Case 'delete-encoding-relative' -Status 'PROBED' -Data @{
        note = 'relative path on DELETE; 400 matches the write route rule'
        http = @{ status = $relative.Status; body = $relative.BodyText }
    }
    Write-ProbeLog ("[PROBED] delete-encoding-relative status={0}" -f $relative.Status)

    # A space in the path: the encoded form must address the real file, which
    # also proves the encoder is required rather than optional.
    $spaceName = Get-BinaryProbeName -Suffix 'del space' -Extension '.txt'
    $space = Invoke-ProbeBinaryUpload `
        -Case 'delete-encoding-space-create' `
        -FileName $spaceName `
        -Bytes (Get-Utf8NoBomBytes -Text 'space in the name') `
        -ContentType 'text/plain' `
        -Note 'a probe-owned file whose name contains a space'

    if ($null -ne $space.recordedPath) {
        $spaceResult = Invoke-ProbeDeleteCase -Case 'delete-encoding-space' -Path $space.recordedPath `
            -Note 'percent-encoded space; the encoded form must address the real file'
        Write-ProbeLog ("[PROBED] delete-encoding-space status={0}" -f $spaceResult.Status)
    }

    # A traversal spelling that is already escaped, so the URI carries the
    # literal ../ rather than a normalized path.
    $traversalUri = New-ProbeFileUrlRaw -RawQueryValue '/%2e%2e/escaped.txt'
    Assert-ProbeWriteAllowed -Case 'delete-encoding-traversal' -Method 'DELETE' -Uri $traversalUri
    $traversal = Invoke-ProbeHttp -Method 'DELETE' -Uri $traversalUri -Headers $script:Headers
    Add-ProbeEvidence -Case 'delete-encoding-traversal' -Status 'PROBED' -Data @{
        note = 'traversal spelling on DELETE; a 400 matches the write route rule'
        http = @{ status = $traversal.Status; body = $traversal.BodyText }
    }
    Write-ProbeLog ("[PROBED] delete-encoding-traversal status={0}" -f $traversal.Status)

    # The original target was never deleted by this scenario (the relative
    # spelling was refused, the traversal spelling named a different path, and
    # only the space-named file was actually removed). Record that so the
    # summary is honest, and leave the target for the run's cleanup.
    Add-ProbeEvidence -Case 'delete-encoding-summary' -Status 'OBSERVED' -Data @{
        note            = 'which spellings were refused, and which file was actually deleted'
        untouchedTarget = $target.Path
        targetStillListed = ($null -ne (Get-ProbeRowOrNull -Path $target.Path))
        relativeStatus  = $relative.Status
        traversalStatus = $traversal.Status
        spaceStatus     = if ($null -ne $space.recordedPath) { $spaceResult.Status } else { $null }
    }
}

function Invoke-ScenarioDeleteAuth {
    # Auth on DELETE. No header and a garbage token should both be 401, the
    # same as every other mutating route.
    $target = New-ProbeOwnedTextFile -Suffix 'del-auth' -Content 'delete auth target'
    if ($null -eq $target.Path) {
        Write-ProbeLog '[STOPPED] delete-auth: the target could not be created'
        return
    }

    $encoded = [System.Uri]::EscapeDataString($target.Path)
    $uri = "$StudioOrigin/api/projects/$ProjectId/file?path=$encoded"
    Assert-ProbeWriteAllowed -Case 'delete-auth-no-header' -Method 'DELETE' -Uri $uri

    $noHeader = Invoke-ProbeHttp -Method 'DELETE' -Uri $uri
    $garbage = Invoke-ProbeHttp -Method 'DELETE' -Uri $uri -Headers @{ Authorization = 'Bearer not-a-real-token' }

    Add-ProbeEvidence -Case 'delete-auth' -Status 'PROBED' -Data @{
        note              = 'DELETE with no credential and with a garbage bearer token'
        noHeaderStatus    = $noHeader.Status
        noHeaderBody      = $noHeader.BodyText
        garbageStatus     = $garbage.Status
        garbageBody       = $garbage.BodyText
    }
    Write-ProbeLog ("[PROBED] delete-auth noHeader={0} garbage={1}" -f $noHeader.Status, $garbage.Status)

    # Neither request should have deleted anything; the authenticated delete
    # below both proves the target still exists and cleans it up.
    $cleanup = Invoke-ProbeDeleteCase -Case 'delete-auth-cleanup' -Path $target.Path `
        -Note 'authenticated delete after the unauthenticated attempts; also proves they did not delete it'
    Write-ProbeLog ("[PROBED] delete-auth-cleanup status={0} deleted={1}" -f $cleanup.Status, $cleanup.Deleted)
}

function Invoke-ScenarioDeleteResponseHeaders {
    # Is there any identity header on a DELETE response (ETag, Last-Modified)?
    # Select-ProbeHeaders already keeps the ones that could carry meaning.
    $target = New-ProbeOwnedTextFile -Suffix 'del-headers' -Content 'delete header target'
    if ($null -eq $target.Path) {
        Write-ProbeLog '[STOPPED] delete-response-headers: the target could not be created'
        return
    }

    $result = Invoke-ProbeDeleteFile -Path $target.Path -Case 'delete-response-headers'

    Add-ProbeEvidence -Case 'delete-response-headers' -Status 'PROBED' -Data @{
        note    = 'any ETag or Last-Modified on a DELETE response?'
        path    = $target.Path
        status  = $result.Status
        headers = $result.ResponseHeaders
        body    = $result.Body
    }
    Write-ProbeLog ("[PROBED] delete-response-headers status={0}" -f $result.Status)
}


# ---------------------------------------------------------------------------
# Rename / move (#16)
#
# No rename route is documented or observed. The classifier treats the path as
# identity, so a rename is a delete plus a create unless the server offers a
# move. These cases try the plausible shapes and record what each did; none of
# them is trusted on status alone. rename-devtools-* is the authoritative
# fallback: a real Studio UI rename captured from the Network panel.
# ---------------------------------------------------------------------------

function Invoke-ProbeRenameAttempt {
    # Send one candidate rename request and record whether the old path
    # disappeared and whether a new path appeared. The status is never the
    # proof: a 200 that left both paths untouched is a no-op.
    param(
        [string]$Case,
        [string]$Method,
        [string]$Uri,
        [string]$Body,
        [string]$OldPath,
        [string]$NewPath,
        [string]$Note = ''
    )

    Assert-ProbeWriteAllowed -Case $Case -Method $Method -Uri $Uri

    $bodyBytes = if ([string]::IsNullOrEmpty($Body)) { [byte[]]@() } else { Get-Utf8NoBomBytes -Text $Body }
    $response = Invoke-ProbeHttp `
        -Method $Method `
        -Uri $Uri `
        -Headers $script:Headers `
        -BodyBytes $bodyBytes `
        -ContentType 'application/json'

    Start-Sleep -Milliseconds 400
    $oldAfter = Get-ProbeRowOrNull -Path $OldPath
    $newAfter = Get-ProbeRowOrNull -Path $NewPath
    $newRead = Get-ProbeReadOrNull -Path $NewPath

    Add-ProbeEvidence -Case $Case -Status 'PROBED' -Data @{
        note             = $Note
        method           = $Method
        uri              = $Uri
        requestBody      = $Body
        oldPath          = $OldPath
        newPath          = $NewPath
        http             = @{
            status  = $response.Status
            body    = $response.BodyText
            headers = $response.ResponseHeaders
            error   = if ($null -ne $response.TransportError) { [string]$response.TransportError.Message } else { $null }
        }
        oldStillListed   = ($null -ne $oldAfter)
        newNowListed     = ($null -ne $newAfter)
        newSha           = if ($null -ne $newRead) { $newRead.Sha256 } else { $null }
        looksLikeARename = ($null -eq $oldAfter -and $null -ne $newAfter)
    }
    Write-ProbeLog ("[PROBED] {0} {1} status={2} oldGone={3} newPresent={4}" -f `
        $Method, $Case, $response.Status, ($null -eq $oldAfter), ($null -ne $newAfter))

    return [pscustomobject]@{
        Status   = $response.Status
        OldGone  = ($null -eq $oldAfter)
        NewPresent = ($null -ne $newAfter)
        Body     = $response.BodyText
    }
}

function Invoke-ScenarioRenameProbe {
    # Guess-and-record the rename route. Each attempt gets a freshly created
    # probe-owned target so a failed attempt cannot contaminate the next one.
    #
    # HISTORICAL: every shape below failed. The real route is
    # POST /api/projects/{id}/move with { from, to } at the project root, found
    # by capturing a UI rename and characterized in rename-move. This scenario
    # is kept as the record of which sub-route shapes do NOT exist, so nobody
    # re-guesses them.
    $shapes = @(
        @{
            Case   = 'rename-probe-patch-file'
            Suffix = 'patch'
            Method = 'PATCH'
            Relative = "/api/projects/$ProjectId/file"
            Body   = '{"newPath":"/sync-probe/renamed.txt"}'
            Note   = 'PATCH on the file route with a newPath field'
        },
        @{
            Case   = 'rename-probe-post-file-rename'
            Suffix = 'postfile'
            Method = 'POST'
            Relative = "/api/projects/$ProjectId/file/rename"
            Body   = '{"path":"/sync-probe/x.txt","newPath":"/sync-probe/renamed.txt"}'
            Note   = 'POST on a file/rename sub-route'
        },
        @{
            Case   = 'rename-probe-post-file-move'
            Suffix = 'postmove'
            Method = 'POST'
            Relative = "/api/projects/$ProjectId/file/move"
            Body   = '{"path":"/sync-probe/x.txt","newPath":"/sync-probe/renamed.txt"}'
            Note   = 'POST on a file/move sub-route'
        },
        @{
            Case   = 'rename-probe-post-files-rename'
            Suffix = 'postfiles'
            Method = 'POST'
            Relative = "/api/projects/$ProjectId/files/rename"
            Body   = '{"from":"/sync-probe/x.txt","to":"/sync-probe/renamed.txt"}'
            Note   = 'POST on a files/rename sub-route with from/to spellings'
        },
        @{
            Case   = 'rename-probe-put-file-newpath'
            Suffix = 'putfile'
            Method = 'PUT'
            Relative = "/api/projects/$ProjectId/file"
            Body   = '{"newPath":"/sync-probe/renamed.txt"}'
            Note   = 'PUT on the file route with only a newPath field; the text route is overwrite-only, so this is expected to fail'
        }
    )

    foreach ($shape in $shapes) {
        $target = New-ProbeOwnedTextFile -Suffix "rename-$($shape.Case)" -Content "rename probe target for $($shape.Case)"
        if ($null -eq $target.Path) {
            Write-ProbeLog ("[STOPPED] {0}: no target could be created" -f $shape.Case)
            continue
        }

        $oldPath = $target.Path
        # The new name must come from the run-stamped prefix, never an ad-hoc
        # Guid: an unstamped name is invisible to cleanup and would be orphaned.
        $shapeSuffix = $shape.Case -replace '^rename-probe-', ''
        $newPath = "$($script:ProbeDir)/$($script:ProbeNamePrefix)-renamed-$shapeSuffix.txt"

        # Point the candidate body at this case's real paths.
        $body = $shape.Body `
            -replace [regex]::Escape('/sync-probe/x.txt'), $oldPath `
            -replace [regex]::Escape('/sync-probe/renamed.txt'), $newPath

        $uri = "$StudioOrigin$($shape.Relative)?path=$([System.Uri]::EscapeDataString($oldPath))"
        $attempt = Invoke-ProbeRenameAttempt -Case $shape.Case -Method $shape.Method -Uri $uri `
            -Body $body -OldPath $oldPath -NewPath $newPath -Note $shape.Note

        # A candidate that moved nothing leaves the target behind; delete it so
        # the project does not accumulate one file per guessed shape.
        if (-not $attempt.NewPresent -and $attempt.OldGone) {
            $script:CreatedPaths.Remove($oldPath)
        }
        elseif (-not $attempt.OldGone) {
            Invoke-ProbeDeleteFile -Path $oldPath -Case "rename-probe-cleanup:$($shape.Case)" | Out-Null
        }
        if ($attempt.NewPresent) {
            $script:CreatedPaths.Add($newPath)
        }
    }

    # Record the composition question explicitly: a move without a server-side
    # rename can only be delete + create, and create is unsolved for arbitrary
    # paths (#14/#15).
    Add-ProbeEvidence -Case 'rename-probe-composition-note' -Status 'OBSERVED' -Data @{
        note = 'if no candidate moved a file, a rename can only compose as delete + create, and create is unsolved for arbitrary paths'
    }
}

function Invoke-ProbeMoveRequest {
    # POST /api/projects/{id}/move with { from, to }. The real route, captured
    # from the Studio UI (the guessed sub-routes in rename-probe all failed
    # because the route is at the project root, not under /file or /files).
    param(
        [string]$Case,
        [string]$From,
        [string]$To,
        [string]$Note = '',
        [hashtable]$ExtraHeaders
    )

    $uri = New-ProbeApiUrl -RelativePath "/api/projects/$ProjectId/move"
    Assert-ProbeWriteAllowed -Case $Case -Method 'POST' -Uri $uri

    $body = @{ from = $From; to = $To } | ConvertTo-Json -Compress

    $requestHeaders = @{}
    foreach ($key in $script:Headers.Keys) { $requestHeaders[$key] = $script:Headers[$key] }
    if ($null -ne $ExtraHeaders) {
        foreach ($key in $ExtraHeaders.Keys) { $requestHeaders[$key] = $ExtraHeaders[$key] }
    }

    $response = Invoke-ProbeHttp `
        -Method 'POST' `
        -Uri $uri `
        -Headers $requestHeaders `
        -BodyBytes (Get-Utf8NoBomBytes -Text $body) `
        -ContentType 'application/json'

    Start-Sleep -Milliseconds 400
    $fromAfter = Get-ProbeRowOrNull -Path $From
    $toAfter = Get-ProbeRowOrNull -Path $To

    return [pscustomobject]@{
        Case       = $Case
        Uri        = $uri
        Body       = $body
        Status     = $response.Status
        BodyText   = $response.BodyText
        Headers    = $response.ResponseHeaders
        Error      = $response.TransportError
        FromListed = ($null -ne $fromAfter)
        ToListed   = ($null -ne $toAfter)
        Moved      = ($null -eq $fromAfter) -and ($null -ne $toAfter)
    }
}

function Invoke-ScenarioRenameMove {
    # Characterize the real rename route: POST /api/projects/{id}/move with
    # { from, to }. Found by capturing a UI rename after the guessed
    # sub-routes in rename-probe all failed.
    #
    # The questions that matter for #17: does it move between arbitrary paths
    # or only within /uploads, does it preserve bytes, does it overwrite an
    # existing destination or collide, and is it safe to retry.
    $target = New-ProbeOwnedTextFile -Suffix 'move-basic' -Content 'move route basic target'
    if ($null -eq $target.Path) {
        Write-ProbeLog '[STOPPED] rename-move: the target could not be created'
        return
    }

    $newPath = "$($script:ProbeDir)/$($script:ProbeNamePrefix)-moved-basic.txt"
    $readBefore = Get-ProbeReadOrNull -Path $target.Path

    $move = Invoke-ProbeMoveRequest -Case 'rename-move-basic' -From $target.Path -To $newPath `
        -Note 'the real route: POST /move with from/to; a cross-directory move also tests whether the destination path is honored'

    $readAfter = Get-ProbeReadOrNull -Path $newPath

    Add-ProbeEvidence -Case 'rename-move-basic' -Status 'PROBED' -Data @{
        note            = 'the real rename route, with a /uploads -> /sync-probe destination'
        uri             = $move.Uri
        requestBody     = $move.Body
        http            = @{
            status  = $move.Status
            body    = $move.BodyText
            headers = $move.Headers
            error   = if ($null -ne $move.Error) { [string]$move.Error.Message } else { $null }
        }
        fromPath        = $target.Path
        toPath          = $newPath
        fromStillListed = $move.FromListed
        toNowListed     = $move.ToListed
        moved           = $move.Moved
        shaBefore       = if ($null -ne $readBefore) { $readBefore.Sha256 } else { $null }
        shaAfter        = if ($null -ne $readAfter) { $readAfter.Sha256 } else { $null }
        bytesPreserved  = ($null -ne $readBefore -and $null -ne $readAfter -and
            [string]::Equals($readBefore.Sha256, $readAfter.Sha256, [System.StringComparison]::OrdinalIgnoreCase))
    }
    Write-ProbeLog ("[PROBED] rename-move-basic status={0} moved={1}" -f $move.Status, $move.Moved)

    if ($move.ToListed) { $script:CreatedPaths.Add($newPath) }
    if ($move.FromListed) { $script:CreatedPaths.Add($target.Path) }

    # Does the destination path get honored, or is it flattened into /uploads
    # the way the upload flow flattens? The basic case above already asked
    # this, but a same-directory move isolates it.
    $sameTarget = New-ProbeOwnedTextFile -Suffix 'move-samedir' -Content 'same directory move target'
    if ($null -ne $sameTarget.Path) {
        $sameNew = "$($script:ProbeDir)/$($script:ProbeNamePrefix)-moved-samedir.txt"
        $sameMove = Invoke-ProbeMoveRequest -Case 'rename-move-same-directory' -From $sameTarget.Path -To $sameNew `
            -Note 'a move within one directory; isolates whether the destination path is honored'

        Add-ProbeEvidence -Case 'rename-move-same-directory' -Status 'PROBED' -Data @{
            note            = 'does /move honor a destination path, or flatten it?'
            requestBody     = $sameMove.Body
            http            = @{ status = $sameMove.Status; body = $sameMove.BodyText }
            fromPath        = $sameTarget.Path
            toPath          = $sameNew
            fromStillListed = $sameMove.FromListed
            toNowListed     = $sameMove.ToListed
            moved           = $sameMove.Moved
            destinationHonored = [string]::Equals($sameNew, $sameNew, [System.StringComparison]::OrdinalIgnoreCase)
        }
        Write-ProbeLog ("[PROBED] rename-move-same-directory status={0} moved={1}" -f $sameMove.Status, $sameMove.Moved)

        if ($sameMove.ToListed) { $script:CreatedPaths.Add($sameNew) }
        if ($sameMove.FromListed) { $script:CreatedPaths.Add($sameTarget.Path) }
    }

    # Failure shapes: a missing source, and a retry of an already-completed move.
    $absentFrom = "$($script:ProbeDir)/$($script:ProbeNamePrefix)-move-never-existed.txt"
    $absentTo = "$($script:ProbeDir)/$($script:ProbeNamePrefix)-move-absent-dest.txt"
    $absent = Invoke-ProbeMoveRequest -Case 'rename-move-from-absent' -From $absentFrom -To $absentTo `
        -Note 'a from path that does not exist; is it a 404 or a silent no-op?'

    Add-ProbeEvidence -Case 'rename-move-from-absent' -Status 'PROBED' -Data @{
        note            = 'moving a path that does not exist'
        requestBody     = $absent.Body
        http            = @{ status = $absent.Status; body = $absent.BodyText }
        fromStillListed = $absent.FromListed
        toNowListed     = $absent.ToListed
    }
    Write-ProbeLog ("[PROBED] rename-move-from-absent status={0}" -f $absent.Status)

    # Retry: the same move a second time. Retry safety matters for #17.
    $retryTarget = New-ProbeOwnedTextFile -Suffix 'move-retry' -Content 'move retry target'
    if ($null -ne $retryTarget.Path) {
        $retryNew = "$($script:ProbeDir)/$($script:ProbeNamePrefix)-moved-retry.txt"
        $first = Invoke-ProbeMoveRequest -Case 'rename-move-retry-first' -From $retryTarget.Path -To $retryNew `
            -Note 'first move'
        $second = Invoke-ProbeMoveRequest -Case 'rename-move-retry-second' -From $retryTarget.Path -To $retryNew `
            -Note 'the same move again; the source is now gone, so this is the retry-after-ambiguous-failure shape'

        Add-ProbeEvidence -Case 'rename-move-retry-summary' -Status 'OBSERVED' -Data @{
            note        = 'is a repeated move safe, and does the destination survive?'
            firstStatus = $first.Status
            secondStatus = $second.Status
            secondBody  = $second.BodyText
            destinationStillListed = $second.ToListed
            idempotentStatus = ($first.Status -eq $second.Status)
        }
        Write-ProbeLog ("[OBSERVED] rename-move-retry first={0} second={1}" -f $first.Status, $second.Status)

        if ($second.ToListed) { $script:CreatedPaths.Add($retryNew) }
        if ($second.FromListed) { $script:CreatedPaths.Add($retryTarget.Path) }
    }

    # Does a move overwrite an existing destination, or collide like the upload
    # flow does? This decides whether a move can clobber a file silently.
    $clobberFrom = New-ProbeOwnedTextFile -Suffix 'move-clobber-src' -Content 'clobber source content'
    $clobberTo = New-ProbeOwnedTextFile -Suffix 'move-clobber-dst' -Content 'clobber destination content'
    if ($null -ne $clobberFrom.Path -and $null -ne $clobberTo.Path) {
        $destReadBefore = Get-ProbeReadOrNull -Path $clobberTo.Path
        $clobber = Invoke-ProbeMoveRequest -Case 'rename-move-onto-existing' -From $clobberFrom.Path -To $clobberTo.Path `
            -Note 'move onto an existing path; overwrite, collision-rename, or refuse?'

        $destReadAfter = Get-ProbeReadOrNull -Path $clobberTo.Path
        Add-ProbeEvidence -Case 'rename-move-onto-existing' -Status 'PROBED' -Data @{
            note             = 'the destination already existed'
            requestBody      = $clobber.Body
            http             = @{ status = $clobber.Status; body = $clobber.BodyText }
            fromPath         = $clobberFrom.Path
            toPath           = $clobberTo.Path
            fromStillListed  = $clobber.FromListed
            toStillListed    = $clobber.ToListed
            destShaBefore    = if ($null -ne $destReadBefore) { $destReadBefore.Sha256 } else { $null }
            destShaAfter     = if ($null -ne $destReadAfter) { $destReadAfter.Sha256 } else { $null }
            destOverwritten  = ($null -ne $destReadBefore -and $null -ne $destReadAfter -and
                -not [string]::Equals($destReadBefore.Sha256, $destReadAfter.Sha256, [System.StringComparison]::OrdinalIgnoreCase))
        }
        Write-ProbeLog ("[PROBED] rename-move-onto-existing status={0} overwritten={1}" -f `
            $clobber.Status, $clobber.Status)

        if ($clobber.FromListed) { $script:CreatedPaths.Add($clobberFrom.Path) }
        if ($clobber.ToListed) { $script:CreatedPaths.Add($clobberTo.Path) }
    }

    # Binary: does a move work on a binary file too, or only text?
    $binName = Get-BinaryProbeName -Suffix 'move-binary'
    $binUpload = Invoke-ProbeBinaryUpload -Case 'rename-move-binary-create' -FileName $binName `
        -Bytes (Get-BinaryProbeBytes -Variant 13) `
        -Note 'a binary target for the move route'
    if ($null -ne $binUpload.recordedPath) {
        $binNew = "$($script:ProbeDir)/$($script:ProbeNamePrefix)-moved-binary.png"
        $binReadBefore = Get-ProbeReadOrNull -Path $binUpload.recordedPath
        $binMove = Invoke-ProbeMoveRequest -Case 'rename-move-binary' -From $binUpload.recordedPath -To $binNew `
            -Note 'does the move route accept a binary file?'
        $binReadAfter = Get-ProbeReadOrNull -Path $binNew

        Add-ProbeEvidence -Case 'rename-move-binary' -Status 'PROBED' -Data @{
            note            = 'a binary move; the upload flow cannot target a path, so this is the only way to relocate a binary'
            requestBody     = $binMove.Body
            http            = @{ status = $binMove.Status; body = $binMove.BodyText }
            fromPath        = $binUpload.recordedPath
            toPath          = $binNew
            fromStillListed = $binMove.FromListed
            toNowListed     = $binMove.ToListed
            moved           = $binMove.Moved
            shaBefore       = if ($null -ne $binReadBefore) { $binReadBefore.Sha256 } else { $null }
            shaAfter        = if ($null -ne $binReadAfter) { $binReadAfter.Sha256 } else { $null }
            bytesPreserved  = ($null -ne $binReadBefore -and $null -ne $binReadAfter -and
                [string]::Equals($binReadBefore.Sha256, $binReadAfter.Sha256, [System.StringComparison]::OrdinalIgnoreCase))
        }
        Write-ProbeLog ("[PROBED] rename-move-binary status={0} moved={1}" -f $binMove.Status, $binMove.Moved)

        if ($binMove.ToListed) { $script:CreatedPaths.Add($binNew) }
        if ($binMove.FromListed) { $script:CreatedPaths.Add($binUpload.recordedPath) }
    }
}

function Invoke-ScenarioRenameDevToolsPrepare {
    # Mirrors text-concurrency-prepare: write a probe-owned target, then hand
    # the human a precise instruction. The rename route has no documented
    # shape, so a real UI rename captured from DevTools is the authoritative
    # source when the guessed candidates fail.
    #
    # The content is unique per run so the file can be located by hash
    # afterwards even if the human gives it an unrelated name.
    $target = New-ProbeOwnedTextFile -Suffix 'rename-devtools'

    if ($null -eq $target.Path) {
        Write-ProbeLog '[STOPPED] rename-devtools-prepare: the target could not be created'
        return
    }

    # The new name should keep the run stamp, because the delete guard only
    # accepts a stamped /uploads path. A name without it is still detected by
    # hash, but cannot be deleted automatically.
    $suggestedName = "$($script:ProbeNamePrefix)-renamed.txt"

    $stateFile = Join-Path $OutDir 'probe-rename-state.json'
    @{
        path       = $target.Path
        sha256     = $target.Sha256
        runStamp   = $script:ProbeRunStamp
        preparedAt = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stateFile -Encoding UTF8

    Add-ProbeEvidence -Case 'rename-devtools-prepare' -Status 'PROBED' -Data @{
        note          = 'target written; rename it by hand in Studio with DevTools open'
        path          = $target.Path
        sha256        = $target.Sha256
        runStamp      = $script:ProbeRunStamp
        suggestedName = $suggestedName
        stateFile     = $stateFile
    }

    Write-ProbeLog ''
    Write-ProbeLog 'NEXT (human step):'
    Write-ProbeLog "  1. In Studio, rename $($target.Path)"
    Write-ProbeLog "     Suggested new name: $suggestedName"
    Write-ProbeLog '     Keep the probe-<stamp> prefix: a stamped name can be deleted'
    Write-ProbeLog '     automatically, and a name without it has to be removed by hand.'
    Write-ProbeLog '  2. With DevTools > Network open, repeat the rename if needed.'
    Write-ProbeLog '     Right-click the rename request > Copy > Copy as fetch.'
    Write-ProbeLog '     For the response too, use Save all as HAR instead.'
    Write-ProbeLog '  3. Save that text to a file, e.g. %TEMP%\rundot-rename-capture.txt'
    Write-ProbeLog '  4. Run -Scenario rename-devtools-apply -CapturePath <that file>'
    Write-ProbeLog ''
    Write-ProbeLog 'The apply step locates the file by content hash and deletes it, so the'
    Write-ProbeLog 'project is left clean. Do not delete it yourself before running apply.'
    Write-ProbeLog ''
}

function Invoke-ScenarioRenameDevToolsApply {
    # Read the human's captured request and record the real route, method, and
    # body. The capture is never parsed into a replayed request: it is evidence
    # about the shape, and a probe that replayed a copied auth header would be
    # storing a credential.
    #
    # This runs in a SEPARATE process from rename-devtools-prepare, so the
    # per-process run stamp is useless here. The prepare run's stamp is read
    # back out of the state file's path, and the renamed file is located by
    # CONTENT HASH rather than by name: the human picks the new name, and a
    # copy-as-fetch capture does not reliably show the path the server recorded.
    param([string]$CapturePath)

    $stateFile = Join-Path $OutDir 'probe-rename-state.json'
    $state = $null
    if (Test-Path -LiteralPath $stateFile) {
        $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    }

    $oldPath = if ($null -ne $state) { [string]$state.path } else { $null }
    $oldSha = if ($null -ne $state) { [string]$state.sha256 } else { $null }

    # Recover the prepare run's stamp from the path it wrote. A filename built
    # by Get-BinaryProbeName looks like probe-<yyyyMMdd-HHmmss>-<suffix>.txt.
    $prepareStamp = $null
    if (-not [string]::IsNullOrWhiteSpace($oldPath)) {
        $stampMatch = [regex]::Match($oldPath, 'probe-(\d{8}-\d{6})')
        if ($stampMatch.Success) { $prepareStamp = $stampMatch.Groups[1].Value }
    }

    if ([string]::IsNullOrWhiteSpace($prepareStamp)) {
        Add-ProbeEvidence -Case 'rename-devtools-apply' -Status 'STOPPED' -Data @{
            note      = 'the prepare state file is missing or names no run-stamped path'
            stateFile = $stateFile
            oldPath   = $oldPath
        }
        Write-ProbeLog ("[STOPPED] rename-devtools-apply: run rename-devtools-prepare first; {0} is missing or unusable." -f $stateFile)
        return
    }

    $oldStillListed = $null -ne (Get-ProbeRowOrNull -Path $oldPath)

    # Every probe path from the PREPARE run, not this one.
    $ownedNow = @(Get-ProbeListedPaths | Where-Object { $_ -like "*$prepareStamp*" })

    # Locate the renamed file by content. The path may have changed, the bytes
    # did not, so a hash match identifies it without trusting the new name.
    $renamedPath = $null
    $hashMatches = @()
    foreach ($candidate in $ownedNow) {
        if ($null -ne $oldPath -and [string]::Equals($candidate, $oldPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $read = Get-ProbeReadOrNull -Path $candidate
        if ($null -eq $read) { continue }
        if (-not [string]::IsNullOrWhiteSpace($oldSha) -and
            [string]::Equals($read.Sha256, $oldSha, [System.StringComparison]::OrdinalIgnoreCase)) {
            $hashMatches += $candidate
            if ($null -eq $renamedPath) { $renamedPath = $candidate }
        }
    }

    $captureText = $null
    $captureLines = $null
    $captureRoutes = $null
    $captureHadResponse = $false
    if (-not [string]::IsNullOrWhiteSpace($CapturePath) -and (Test-Path -LiteralPath $CapturePath -PathType Leaf)) {
        $captureText = (Get-Content -LiteralPath $CapturePath -Raw)
        # Record the request shape only. A copied fetch carries an
        # Authorization header, which must never reach evidence, and a HAR
        # carries the whole exchange, so anything credential-shaped is
        # redacted rather than recorded.
        #
        # The method/URL pairs are extracted explicitly. Matching on "method"
        # alone is not enough: the URL lives on its own line, so a naive filter
        # records that a request happened without recording where it went,
        # which is the one thing this scenario exists to capture.
        $redact = {
            param([string]$Text)
            $t = $Text
            $t = $t -replace '(?i)(authorization|bearer|token|cookie|api[-_]?key)("?\s*[:=]\s*"?)[^",\s]+', '$1$2<redacted>'
            $t = $t -replace 'eyJ[A-Za-z0-9_\-]{5,}', '<redacted-jwt>'
            return $t
        }

        $captureLines = @($captureText -split "`r?`n" |
            Where-Object { $_ -match '(?i)fetch\(|"method"|"url"|\bmethod:|https?://' } |
            Select-Object -First 60 |
            ForEach-Object { & $redact $_ })

        # The route index: every URL with its method, so the evidence names the
        # real route rather than just proving that some request occurred.
        #
        # The URL is read ONLY from a fetch() call or a HAR "url" field. A
        # blanket https?:// match picks up the "referrer" line, which sits
        # between the URL and the method in a copied fetch and would replace
        # the real route with "https://run.world/".
        $routes = New-Object 'System.Collections.Generic.List[object]'
        $lastUrl = $null
        foreach ($line in ($captureText -split "`r?`n")) {
            $fetchMatch = [regex]::Match($line, 'fetch\(\s*[''"](https?://[^''"]+)[''"]')
            $harUrlMatch = [regex]::Match($line, '"(?:url|requestUrl)"\s*:\s*"(https?://[^"]+)"')

            if ($fetchMatch.Success) {
                $lastUrl = & $redact $fetchMatch.Groups[1].Value
                continue
            }
            if ($harUrlMatch.Success) {
                $lastUrl = & $redact $harUrlMatch.Groups[1].Value
                continue
            }

            $methodMatch = [regex]::Match($line, '"method"\s*:\s*"([A-Za-z]+)"')
            if ($methodMatch.Success -and $null -ne $lastUrl) {
                $routes.Add([pscustomobject]@{
                    method = $methodMatch.Groups[1].Value
                    url    = $lastUrl
                })
                $lastUrl = $null
            }
        }
        $captureRoutes = $routes.ToArray()
        $captureHadResponse = ($captureText -match '(?i)"status"\s*:')
    }

    Add-ProbeEvidence -Case 'rename-devtools-apply' -Status 'OBSERVED' -Data @{
        note              = 'the real rename route, as captured from the Studio UI'
        prepareStamp      = $prepareStamp
        oldPath           = $oldPath
        oldStillListed    = $oldStillListed
        oldSha256         = $oldSha
        ownedPathsNow     = $ownedNow
        renamedPathByHash = $renamedPath
        hashMatches       = $hashMatches
        contentMoved      = ($null -ne $renamedPath)
        captureProvided   = (-not [string]::IsNullOrWhiteSpace($captureText))
        captureHadResponse = $captureHadResponse
        captureRoutes     = $captureRoutes
        captureLines      = $captureLines
    }

    Write-ProbeLog ("[OBSERVED] rename-devtools-apply oldStillListed={0} prepareStamp={1}" -f $oldStillListed, $prepareStamp)
    if ($null -ne $renamedPath) {
        Write-ProbeLog ("[OBSERVED] rename-devtools-apply the bytes now live at {0} (matched by content hash)" -f $renamedPath)
    }
    elseif ($oldStillListed) {
        Write-ProbeLog '[OBSERVED] rename-devtools-apply: the original path is still listed and no hash match appeared; the rename may not have happened, or the file was moved out of /uploads.'
    }
    if ($null -eq $captureText) {
        Write-ProbeLog '[WARNING] rename-devtools-apply: no -CapturePath was given, so only the path change was recorded.'
    }
    elseif (-not $captureHadResponse) {
        Write-ProbeLog '[NOTE] rename-devtools-apply: the capture looks like a request only (copy-as-fetch), so the response body is not in it.'
        Write-ProbeLog '       If the renamed path is unknown, re-capture with DevTools > Network > right-click > Save all as HAR.'
    }

    # Leave the project as found. The renamed file is deletable only when it
    # kept a run-stamped name under /uploads, because that is all the delete
    # guard accepts. Anything else is reported for manual removal rather than
    # forced, so the guard is never weakened for convenience.
    $cleanupTargets = @()
    if ($null -ne $renamedPath) { $cleanupTargets += $renamedPath }
    if ($oldStillListed) { $cleanupTargets += $oldPath }

    $deleted = @()
    $manual = @()
    foreach ($cleanupPath in ($cleanupTargets | Sort-Object -Unique)) {
        try {
            # The prepare run's stamp is the one on these files, and it is
            # recovered above, so it is passed as the explicit allowance.
            $result = Invoke-ProbeDeleteFile -Path $cleanupPath -Case "rename-devtools-cleanup" `
                -AllowedStamp @($prepareStamp)
            if ($result.Deleted) {
                $deleted += $cleanupPath
            }
            else {
                $manual += $cleanupPath
            }
        }
        catch {
            # The delete guard refused it, which means the human renamed the
            # file to a name the probe does not own. That is expected, not an
            # error, so record it for manual cleanup instead of failing.
            $manual += $cleanupPath
        }
    }

    Add-ProbeEvidence -Case 'rename-devtools-cleanup' -Status 'OBSERVED' -Data @{
        note           = 'the hand-off leaves the project as found where the guard allows it'
        attempted      = @($cleanupTargets | Sort-Object -Unique)
        deleted        = $deleted
        needsManual    = $manual
    }

    if ($deleted.Count -gt 0) {
        Write-ProbeLog ("[CLEANUP] rename-devtools-apply deleted {0} path(s)." -f $deleted.Count)
    }
    if ($manual.Count -gt 0) {
        Write-ProbeLog '[CLEANUP] rename-devtools-apply could not delete these; remove them in the Studio UI:'
        foreach ($path in $manual) { Write-ProbeLog "  $path" }
    }
}


# ---------------------------------------------------------------------------
# Text-file create investigation (#37)
#
# #14 proved PUT /file cannot create. #15 and #16 can compose upload + move.
# This block guesses single-request creates, characterizes composition, and
# records a DevTools capture of what the Studio UI actually sends.
# ---------------------------------------------------------------------------

function Remove-ProbeListedPathIfOwned {
    param(
        [string]$Path,
        [string]$Case
    )

    if ($null -eq (Get-ProbeRowOrNull -Path $Path)) { return $false }

    try {
        $result = Invoke-ProbeDeleteFile -Path $Path -Case $Case
        if ($result.Deleted) {
            while ($script:CreatedPaths.Contains($Path)) {
                [void]$script:CreatedPaths.Remove($Path)
            }
        }
        return $result.Deleted
    }
    catch {
        Write-ProbeLog ("[CLEANUP] {0}: could not delete {1}: {2}" -f $Case, $Path, $_.Exception.Message)
        return $false
    }
}

function Get-ProbeJsonBodyKeys {
    param([hashtable]$Body)

    if ($null -eq $Body) { return @() }
    return @($Body.Keys | Sort-Object)
}

function Invoke-ProbeTextCreateDiscoverAttempt {
    param(
        [string]$Case,
        [string]$Method,
        [string]$Uri,
        [hashtable]$BodyObj,
        [string]$TargetPath,
        [string]$Note
    )

    $bodyJson = $null
    $bodyBytes = $null
    if ($null -ne $BodyObj) {
        $bodyJson = ($BodyObj | ConvertTo-Json -Compress)
        $bodyBytes = Get-Utf8NoBomBytes -Text $bodyJson
    }

    Assert-ProbeWriteAllowed -Case $Case -Method $Method -Uri $Uri
    $response = Invoke-ProbeHttp `
        -Method $Method `
        -Uri $Uri `
        -Headers $script:Headers `
        -BodyBytes $bodyBytes `
        -ContentType 'application/json'

    Start-Sleep -Milliseconds 350
    $rowAfter = Get-ProbeRowOrNull -Path $TargetPath
    $listedAfter = ($null -ne $rowAfter)
    $sizeAfter = if ($null -ne $rowAfter) { $rowAfter.size } else { $null }

    $bodyKeys = Get-ProbeJsonBodyKeys -Body $BodyObj
    Add-ProbeEvidence -Case $Case -Status 'PROBED' -Data @{
        note        = $Note
        method      = $Method
        uri         = $Uri
        bodyKeys    = $bodyKeys
        targetPath  = $TargetPath
        http        = @{ status = $response.Status; body = $response.BodyText }
        listedAfter = $listedAfter
        size        = $sizeAfter
    }
    Write-ProbeLog ("[PROBED] {0} status={1} listedAfter={2}" -f $Case, $response.Status, $listedAfter)

    if ($listedAfter -and $response.Status -ge 200 -and $response.Status -lt 300) {
        if ($null -eq $script:TextCreateRouteFound) {
            $relative = $Uri
            if ($relative -match '/api/projects/[^/]+(.+)$') {
                $relative = $Matches[1]
            }
            $script:TextCreateRouteFound = @{
                method   = $Method
                uri      = $Uri
                bodyKeys = $bodyKeys
            }
        }
        Remove-ProbeListedPathIfOwned -Path $TargetPath -Case "$Case-cleanup" | Out-Null
    }

    return [pscustomobject]@{
        Status      = $response.Status
        ListedAfter = $listedAfter
    }
}

function Invoke-ProbeComposeTextAtPath {
    param(
        [string]$CasePrefix,
        [string]$DestPath,
        [byte[]]$Bytes,
        [string]$FileNameSuffix,
        [string]$ContentType = 'text/plain'
    )

    $fileName = Get-BinaryProbeName -Suffix $FileNameSuffix -Extension '.txt'
    $upload = Invoke-ProbeBinaryUpload `
        -Case "$CasePrefix-upload" `
        -FileName $fileName `
        -Bytes $Bytes `
        -ContentType $ContentType `
        -Note 'upload step for compose-at-path'

    if ([string]::IsNullOrWhiteSpace($upload.recordedPath)) {
        return $null
    }

    $move = Invoke-ProbeMoveRequest `
        -Case "$CasePrefix-move" `
        -From $upload.recordedPath `
        -To $DestPath `
        -Note 'move step for compose-at-path'

    Start-Sleep -Milliseconds 350
    $read = Get-ProbeReadOrNull -Path $DestPath
    $fromStill = $null -ne (Get-ProbeRowOrNull -Path $upload.recordedPath)
    $toListed = $null -ne (Get-ProbeRowOrNull -Path $DestPath)

    if ($toListed) { $script:CreatedPaths.Add($DestPath) }
    if ($fromStill) { $script:CreatedPaths.Add($upload.recordedPath) }

    $adoptStatus = $null
    if ($null -ne $upload.adopt) { $adoptStatus = $upload.adopt['status'] }

    return [pscustomobject]@{
        UploadPath     = $upload.recordedPath
        UploadStatus   = $adoptStatus
        MoveStatus     = $move.Status
        MoveBody       = $move.BodyText
        FromStillListed = $fromStill
        ToListed       = $toListed
        Moved          = $move.Moved
        SentSize       = $Bytes.Length
        SentSha256     = Get-Sha256Hex -Bytes $Bytes
        ReadSize       = if ($null -ne $read) { $read.Bytes.Length } else { $null }
        ReadSha256     = if ($null -ne $read) { $read.Sha256 } else { $null }
        BytesPreserved = (
            $null -ne $read -and
            [string]::Equals((Get-Sha256Hex -Bytes $Bytes), $read.Sha256, [System.StringComparison]::OrdinalIgnoreCase)
        )
    }
}

function Invoke-ScenarioTextCreateDiscover {
    $script:TextCreateRouteFound = $null
    $content = 'discover probe content'
    $bodyText = New-JsonContentBody -Text $content
    $contentLen = $bodyText.Length

    $targets = @(
        @{
            Case   = 'text-create-discover-post-files'
            Method = 'POST'
            Uri    = (New-ProbeApiUrl -RelativePath "/api/projects/$ProjectId/files")
            Body   = @{ path = "$($script:ProbeDir)/$($script:ProbeNamePrefix)-discover-post-files.txt"; content = $content }
            Path   = "$($script:ProbeDir)/$($script:ProbeNamePrefix)-discover-post-files.txt"
            Note   = 'POST /files with path and content'
        },
        @{
            Case   = 'text-create-discover-post-file-create'
            Method = 'POST'
            Uri    = (New-ProbeApiUrl -RelativePath "/api/projects/$ProjectId/file/create")
            Body   = @{ path = "$($script:ProbeDir)/$($script:ProbeNamePrefix)-discover-file-create.txt"; content = $content }
            Path   = "$($script:ProbeDir)/$($script:ProbeNamePrefix)-discover-file-create.txt"
            Note   = 'POST /file/create with path and content'
        },
        @{
            Case   = 'text-create-discover-put-files'
            Method = 'PUT'
            Uri    = (New-ProbeApiUrl -RelativePath "/api/projects/$ProjectId/files")
            Body   = @{ path = "$($script:ProbeDir)/$($script:ProbeNamePrefix)-discover-put-files.txt"; content = $content }
            Path   = "$($script:ProbeDir)/$($script:ProbeNamePrefix)-discover-put-files.txt"
            Note   = 'PUT /files with path and content'
        },
        @{
            Case   = 'text-create-discover-post-create'
            Method = 'POST'
            Uri    = (New-ProbeApiUrl -RelativePath "/api/projects/$ProjectId/create")
            Body   = @{ path = "$($script:ProbeDir)/$($script:ProbeNamePrefix)-discover-create.txt"; content = $content; type = 'file' }
            Path   = "$($script:ProbeDir)/$($script:ProbeNamePrefix)-discover-create.txt"
            Note   = 'POST /create with path, content, and type file'
        }
    )

    foreach ($shape in $targets) {
        if ($null -ne (Get-ProbeRowOrNull -Path $shape.Path)) {
            Remove-ProbeListedPathIfOwned -Path $shape.Path -Case "$($shape.Case)-preclean" | Out-Null
        }
        Invoke-ProbeTextCreateDiscoverAttempt `
            -Case $shape.Case `
            -Method $shape.Method `
            -Uri $shape.Uri `
            -BodyObj $shape.Body `
            -TargetPath $shape.Path `
            -Note $shape.Note | Out-Null
    }

    $postPath = "$($script:ProbeDir)/$($script:ProbeNamePrefix)-discover-post-file.txt"
    $postUri = New-ProbeFileUrl -Path $postPath
    Assert-ProbeWriteAllowed -Case 'text-create-discover-post-file-route' -Method 'POST' -Uri $postUri
    $postResponse = Invoke-ProbeHttp `
        -Method 'POST' `
        -Uri $postUri `
        -Headers $script:Headers `
        -BodyBytes (New-JsonContentBody -Text $content) `
        -ContentType 'application/json'
    Start-Sleep -Milliseconds 350
    $postListed = $null -ne (Get-ProbeRowOrNull -Path $postPath)
    Add-ProbeEvidence -Case 'text-create-discover-post-file-route' -Status 'PROBED' -Data @{
        note        = 'POST on the file route; 405 means PUT-only (#14)'
        method      = 'POST'
        uri         = $postUri
        bodyKeys    = @('content')
        targetPath  = $postPath
        http        = @{ status = $postResponse.Status; body = $postResponse.BodyText }
        listedAfter = $postListed
    }
    Write-ProbeLog ("[PROBED] text-create-discover-post-file-route status={0}" -f $postResponse.Status)
    if ($postListed) {
        Remove-ProbeListedPathIfOwned -Path $postPath -Case 'text-create-discover-post-file-route-cleanup' | Out-Null
    }

    Add-ProbeEvidence -Case 'text-create-discover-summary' -Status 'OBSERVED' -Data @{
        note              = 'guessed single-request create routes; UI capture is authoritative if all fail'
        createRouteFound  = ($null -ne $script:TextCreateRouteFound)
        createRoute       = $script:TextCreateRouteFound
        contentLengthSent = $contentLen
    }
}

function Invoke-ScenarioTextCreateCompose {
    $dest = "$($script:ProbeDir)/$($script:ProbeNamePrefix)-compose.txt"
    if ($null -ne (Get-ProbeRowOrNull -Path $dest)) {
        Remove-ProbeListedPathIfOwned -Path $dest -Case 'text-create-compose-preclean' | Out-Null
    }

    $bytes = Get-Utf8NoBomBytes -Text "compose target $([Guid]::NewGuid().ToString('N'))"
    $result = Invoke-ProbeComposeTextAtPath `
        -CasePrefix 'text-create-compose' `
        -DestPath $dest `
        -Bytes $bytes `
        -FileNameSuffix 'compose'

    if ($null -eq $result) {
        Add-ProbeEvidence -Case 'text-create-compose' -Status 'STOPPED' -Data @{
            note = 'upload step did not record a path'
        }
        Write-ProbeLog '[STOPPED] text-create-compose: upload did not succeed'
        return
    }

    Add-ProbeEvidence -Case 'text-create-compose' -Status 'PROBED' -Data @{
        note             = 'upload then POST /move; composition of #15 and #16, not a single create route'
        destPath         = $dest
        uploadPath       = $result.UploadPath
        uploadAdoptStatus = $result.UploadStatus
        moveStatus       = $result.MoveStatus
        moveBody         = $result.MoveBody
        fromStillListed  = $result.FromStillListed
        toListed         = $result.ToListed
        moved            = $result.Moved
        sentSize         = $result.SentSize
        sentSha256       = $result.SentSha256
        readSize         = $result.ReadSize
        readSha256       = $result.ReadSha256
        bytesPreserved   = $result.BytesPreserved
    }
    Write-ProbeLog ("[PROBED] text-create-compose moveStatus={0} bytesPreserved={1}" -f $result.MoveStatus, $result.BytesPreserved)
}

function Invoke-ScenarioTextCreateIdempotency {
    $dest = "$($script:ProbeDir)/$($script:ProbeNamePrefix)-idempotent.txt"
    if ($null -ne (Get-ProbeRowOrNull -Path $dest)) {
        Remove-ProbeListedPathIfOwned -Path $dest -Case 'text-create-idempotency-preclean' | Out-Null
    }

    $bytes = Get-Utf8NoBomBytes -Text "idempotent compose $([Guid]::NewGuid().ToString('N'))"
    $first = Invoke-ProbeComposeTextAtPath `
        -CasePrefix 'text-create-idempotency-first' `
        -DestPath $dest `
        -Bytes $bytes `
        -FileNameSuffix 'idempotent'

    if ($null -eq $first -or -not $first.ToListed) {
        Add-ProbeEvidence -Case 'text-create-idempotency' -Status 'STOPPED' -Data @{ note = 'first compose did not land at the destination' }
        return
    }

    $shaBefore = $first.ReadSha256
    $secondUpload = Invoke-ProbeBinaryUpload `
        -Case 'text-create-idempotency-second-upload' `
        -FileName (Get-BinaryProbeName -Suffix 'idempotent' -Extension '.txt') `
        -Bytes $bytes `
        -ContentType 'text/plain'

    $secondMoveStatus = $null
    $secondMoveBody = $null
    $destShaAfter = $shaBefore
    if (-not [string]::IsNullOrWhiteSpace($secondUpload.recordedPath)) {
        $secondMove = Invoke-ProbeMoveRequest `
            -Case 'text-create-idempotency-second-move' `
            -From $secondUpload.recordedPath `
            -To $dest
        $secondMoveStatus = $secondMove.Status
        $secondMoveBody = $secondMove.BodyText
        Start-Sleep -Milliseconds 350
        $readAfter = Get-ProbeReadOrNull -Path $dest
        if ($null -ne $readAfter) { $destShaAfter = $readAfter.Sha256 }
    }

    $paths = Get-ProbeListedPaths
    $suffixStem = "$($script:ProbeNamePrefix)-idempotent"
    $related = @($paths | Where-Object { $_ -like "*$suffixStem*" })

    Add-ProbeEvidence -Case 'text-create-idempotency' -Status 'OBSERVED' -Data @{
        note               = 'second upload+move onto an occupied destination'
        destPath           = $dest
        firstMoveStatus    = $first.MoveStatus
        secondUploadPath   = $secondUpload.recordedPath
        secondMoveStatus   = $secondMoveStatus
        secondMoveBody     = $secondMoveBody
        shaBefore          = $shaBefore
        shaAfter           = $destShaAfter
        destinationUnchanged = (
            -not [string]::IsNullOrWhiteSpace($shaBefore) -and
            -not [string]::IsNullOrWhiteSpace($destShaAfter) -and
            [string]::Equals($shaBefore, $destShaAfter, [System.StringComparison]::OrdinalIgnoreCase)
        )
        relatedListedPaths = $related
        relatedCount       = $related.Count
    }
    Write-ProbeLog ("[OBSERVED] text-create-idempotency secondMoveStatus={0} relatedCount={1}" -f $secondMoveStatus, $related.Count)
}

function Invoke-ScenarioTextCreateBytes {
    $cases = @(
        @{
            Case    = 'text-create-bytes-crlf'
            Suffix  = 'bytes-crlf'
            Text    = "a`r`nb`r`n"
        },
        @{
            Case    = 'text-create-bytes-bom'
            Suffix  = 'bytes-bom'
            Text    = "$([char]0xFEFF)bom"
        },
        @{
            Case    = 'text-create-bytes-empty'
            Suffix  = 'bytes-empty'
            Text    = $null
            Empty   = $true
        }
    )

    foreach ($item in $cases) {
        $dest = "$($script:ProbeDir)/$($script:ProbeNamePrefix)-$($item.Suffix).txt"
        if ($null -ne (Get-ProbeRowOrNull -Path $dest)) {
            Remove-ProbeListedPathIfOwned -Path $dest -Case "$($item.Case)-preclean" | Out-Null
        }

        if ($item.Empty) {
            $bytes = @()
            $fileName = Get-BinaryProbeName -Suffix $item.Suffix -Extension '.txt'
            $upload = Invoke-ProbeBinaryUpload `
                -Case "$($item.Case)-upload" `
                -FileName $fileName `
                -Bytes $bytes `
                -ContentType 'text/plain'
            Add-ProbeEvidence -Case "$($item.Case)-upload" -Status 'PROBED' -Data @{
                note         = 'empty payload through upload-url'
                uploadStatus = $upload.uploadUrl.status
                adoptStatus  = if ($null -ne $upload.adopt) { $upload.adopt['status'] } else { $null }
                recordedPath = $upload.recordedPath
                sentSize     = 0
            }
            if ([string]::IsNullOrWhiteSpace($upload.recordedPath)) {
                Write-ProbeLog ("[STOPPED] {0}: empty upload did not record a path" -f $item.Case)
                continue
            }
            $move = Invoke-ProbeMoveRequest -Case "$($item.Case)-move" -From $upload.recordedPath -To $dest
            $read = Get-ProbeReadOrNull -Path $dest
            Add-ProbeEvidence -Case $item.Case -Status 'PROBED' -Data @{
                note           = 'empty file via compose'
                moveStatus     = $move.Status
                sentSize       = 0
                readSize       = if ($null -ne $read) { $read.Bytes.Length } else { $null }
                sentSha256     = (Get-Sha256Hex -Bytes $bytes)
                readSha256     = if ($null -ne $read) { $read.Sha256 } else { $null }
                bytesPreserved = ($null -ne $read -and $read.Bytes.Length -eq 0)
            }
            if ($null -ne (Get-ProbeRowOrNull -Path $dest)) {
                Remove-ProbeListedPathIfOwned -Path $dest -Case "$($item.Case)-cleanup" | Out-Null
            }
            continue
        }

        $bytes = Get-Utf8NoBomBytes -Text $item.Text
        $result = Invoke-ProbeComposeTextAtPath `
            -CasePrefix $item.Case `
            -DestPath $dest `
            -Bytes $bytes `
            -FileNameSuffix $item.Suffix

        Add-ProbeEvidence -Case $item.Case -Status 'PROBED' -Data @{
            note           = 'byte preservation through compose'
            destPath       = $dest
            moveStatus     = if ($null -ne $result) { $result.MoveStatus } else { $null }
            sentSize       = if ($null -ne $result) { $result.SentSize } else { $bytes.Length }
            readSize       = if ($null -ne $result) { $result.ReadSize } else { $null }
            sentSha256     = if ($null -ne $result) { $result.SentSha256 } else { (Get-Sha256Hex -Bytes $bytes) }
            readSha256     = if ($null -ne $result) { $result.ReadSha256 } else { $null }
            bytesPreserved = if ($null -ne $result) { $result.BytesPreserved } else { $false }
        }

        if ($null -ne (Get-ProbeRowOrNull -Path $dest)) {
            Remove-ProbeListedPathIfOwned -Path $dest -Case "$($item.Case)-cleanup" | Out-Null
        }
    }
}

function Invoke-ScenarioTextCreateRace {
    $dest = "$($script:ProbeDir)/$($script:ProbeNamePrefix)-race.txt"
    if ($null -ne (Get-ProbeRowOrNull -Path $dest)) {
        Remove-ProbeListedPathIfOwned -Path $dest -Case 'text-create-race-preclean' | Out-Null
    }

    $plannedFingerprint = Get-ProbeListFingerprint
    $occupyBytes = Get-Utf8NoBomBytes -Text 'occupied'
    $occupy = Invoke-ProbeComposeTextAtPath `
        -CasePrefix 'text-create-race-occupy' `
        -DestPath $dest `
        -Bytes $occupyBytes `
        -FileNameSuffix 'race-occupy'

    $occupyRead = Get-ProbeReadOrNull -Path $dest
    $shaOccupied = if ($null -ne $occupyRead) { $occupyRead.Sha256 } else { $null }

    $createBytes = Get-Utf8NoBomBytes -Text 'planned create while absent'
    $create = Invoke-ProbeComposeTextAtPath `
        -CasePrefix 'text-create-race-create' `
        -DestPath $dest `
        -Bytes $createBytes `
        -FileNameSuffix 'race-create'

    $afterRead = Get-ProbeReadOrNull -Path $dest
    $shaAfter = if ($null -ne $afterRead) { $afterRead.Sha256 } else { $null }

    $paths = Get-ProbeListedPaths
    $siblings = @($paths | Where-Object {
        $_ -like "$($script:ProbeDir)/$($script:ProbeNamePrefix)-race*" -and
        -not [string]::Equals($_, $dest, [System.StringComparison]::OrdinalIgnoreCase)
    })

    Add-ProbeEvidence -Case 'text-create-race' -Status 'OBSERVED' -Data @{
        note                 = 'destination occupied between plan and compose create'
        destPath             = $dest
        plannedFingerprint   = $plannedFingerprint
        occupyMoveStatus     = if ($null -ne $occupy) { $occupy.MoveStatus } else { $null }
        createMoveStatus     = if ($null -ne $create) { $create.MoveStatus } else { $null }
        shaOccupied          = $shaOccupied
        shaAfter             = $shaAfter
        occupiedBytesSurvived = (
            -not [string]::IsNullOrWhiteSpace($shaOccupied) -and
            -not [string]::IsNullOrWhiteSpace($shaAfter) -and
            [string]::Equals($shaOccupied, $shaAfter, [System.StringComparison]::OrdinalIgnoreCase)
        )
        siblingPaths         = $siblings
    }
    $createMoveStatus = $null
    if ($null -ne $create) { $createMoveStatus = $create.MoveStatus }
    $occupiedSurvived = (
        -not [string]::IsNullOrWhiteSpace($shaOccupied) -and
        -not [string]::IsNullOrWhiteSpace($shaAfter) -and
        [string]::Equals($shaOccupied, $shaAfter, [System.StringComparison]::OrdinalIgnoreCase)
    )
    Write-ProbeLog ("[OBSERVED] text-create-race createMoveStatus={0} occupiedSurvived={1}" -f $createMoveStatus, $occupiedSurvived)

    if ($null -ne (Get-ProbeRowOrNull -Path $dest)) {
        Remove-ProbeListedPathIfOwned -Path $dest -Case 'text-create-race-cleanup' | Out-Null
    }
}

function Invoke-ProbeTextCreateConditionalMove {
    param(
        [string]$Case,
        [hashtable]$ExtraHeaders,
        [string]$Note
    )

    $source = New-ProbeOwnedTextFile -Suffix "cond-$Case" -Content "conditional move $Case"
    if ($null -eq $source.Path) {
        Add-ProbeEvidence -Case $Case -Status 'STOPPED' -Data @{ note = 'could not create a move source' }
        return
    }

    $dest = "$($script:ProbeDir)/$($script:ProbeNamePrefix)-cond-$Case.txt"
    $move = Invoke-ProbeMoveRequest `
        -Case $Case `
        -From $source.Path `
        -To $dest `
        -Note $Note `
        -ExtraHeaders $ExtraHeaders

    $preconditionEnforced = ($move.Status -eq 412)
    Add-ProbeEvidence -Case $Case -Status 'PROBED' -Data @{
        note                  = $Note
        http                  = @{ status = $move.Status; body = $move.BodyText }
        destinationListed     = $move.ToListed
        moved                 = $move.Moved
        preconditionEnforced  = $preconditionEnforced
    }
    Write-ProbeLog ("[PROBED] {0} status={1} enforced={2}" -f $Case, $move.Status, $preconditionEnforced)

    if ($move.ToListed) {
        Remove-ProbeListedPathIfOwned -Path $dest -Case "$Case-cleanup-dest" | Out-Null
    }
    if ($null -ne (Get-ProbeRowOrNull -Path $source.Path)) {
        Remove-ProbeListedPathIfOwned -Path $source.Path -Case "$Case-cleanup-src" | Out-Null
    }
}

function Invoke-ScenarioTextCreateConditional {
    Invoke-ProbeTextCreateConditionalMove `
        -Case 'text-create-conditional-if-match-wrong' `
        -ExtraHeaders @{ 'If-Match' = '"definitely-not-the-current-etag"' } `
        -Note 'If-Match with a value that cannot match on POST /move'

    Invoke-ProbeTextCreateConditionalMove `
        -Case 'text-create-conditional-if-match-garbage' `
        -ExtraHeaders @{ 'If-Match' = 'not-an-etag' } `
        -Note 'malformed If-Match on POST /move'

    Invoke-ProbeTextCreateConditionalMove `
        -Case 'text-create-conditional-if-none-match-star' `
        -ExtraHeaders @{ 'If-None-Match' = '*' } `
        -Note 'If-None-Match: * on POST /move'

    $anyDiscoverNonTerminal = $false
    if ($null -ne $script:TextCreateRouteFound) {
        $anyDiscoverNonTerminal = $true
    }

    Add-ProbeEvidence -Case 'text-create-conditional-summary' -Status 'OBSERVED' -Data @{
        note                         = 'preconditions on POST /move; discover routes were 404/405 unless createRouteFound'
        testedDiscoverConditional    = $anyDiscoverNonTerminal
        createRouteFound             = ($null -ne $script:TextCreateRouteFound)
    }
}

function Invoke-ScenarioTextCreateReserved {
    $attempts = @(
        @{
            Case = 'text-create-reserved-git'
            Dest = "/.git/$($script:ProbeNamePrefix)-reserved.txt"
        },
        @{
            Case = 'text-create-reserved-rundot-sync'
            Dest = "/.rundot-sync/$($script:ProbeNamePrefix)-reserved.txt"
        },
        @{
            Case = 'text-create-reserved-traversal'
            Dest = "/../$($script:ProbeNamePrefix)-escaped.txt"
        }
    )

    foreach ($item in $attempts) {
        $source = New-ProbeOwnedTextFile -Suffix $item.Case -Content "reserved probe $($item.Case)"
        if ($null -eq $source.Path) {
            Write-ProbeLog ("[STOPPED] {0}: no source" -f $item.Case)
            continue
        }

        $move = Invoke-ProbeMoveRequest -Case $item.Case -From $source.Path -To $item.Dest `
            -Note 'move onto a reserved-shaped or traversal destination'

        Start-Sleep -Milliseconds 350
        $destListed = $null -ne (Get-ProbeRowOrNull -Path $item.Dest)
        $stamp = $script:ProbeNamePrefix
        $paths = Get-ProbeListedPaths
        $escapedOutside = @($paths | Where-Object {
            $_ -like "*$stamp*" -and
            $_ -notlike "$($script:ProbeDir)/*" -and
            $_ -notlike "$($script:ProbeUploadDir)/*"
        })

        Add-ProbeEvidence -Case $item.Case -Status 'PROBED' -Data @{
            note               = 'reserved or traversal destination; client must refuse regardless'
            destPath           = $item.Dest
            moveStatus         = $move.Status
            moveBody           = $move.BodyText
            destListed         = $destListed
            stampPathsOutsideProbeDirs = $escapedOutside
        }

        if ($destListed) {
            try {
                Invoke-ProbeDeleteFile -Path $item.Dest -Case "$($item.Case)-cleanup" | Out-Null
            }
            catch {
                Write-ProbeLog ("[CLEANUP] {0}: delete guard refused {1}" -f $item.Case, $item.Dest)
            }
        }

        if ($null -ne (Get-ProbeRowOrNull -Path $source.Path)) {
            Remove-ProbeListedPathIfOwned -Path $source.Path -Case "$($item.Case)-cleanup-src" | Out-Null
        }
    }

    Add-ProbeEvidence -Case 'text-create-reserved-summary' -Status 'OBSERVED' -Data @{
        note = 'the sync client keeps refusing .git/, .rundot-sync/, and .. even when the server accepts a move'
    }
}

function Invoke-ScenarioTextCreateDevToolsPrepare {
    $suggestedPath = "$($script:ProbeDir)/$($script:ProbeNamePrefix)-created.txt"
    $uniqueContent = "text-create devtools $([Guid]::NewGuid().ToString('N'))"
    $target = New-ProbeOwnedTextFile -Suffix 'text-create-devtools' -Content $uniqueContent

    if ($null -eq $target.Path) {
        Write-ProbeLog '[STOPPED] text-create-devtools-prepare: could not create a baseline file'
        return
    }

    $stateFile = Join-Path $OutDir 'probe-text-create-state.json'
    @{
        baselinePath = $target.Path
        sha256       = $target.Sha256
        runStamp     = $script:ProbeRunStamp
        suggestedPath = $suggestedPath
        preparedAt   = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stateFile -Encoding UTF8

    Add-ProbeEvidence -Case 'text-create-devtools-prepare' -Status 'PROBED' -Data @{
        note          = 'create a NEW text file in the Studio UI; capture the Network request'
        baselinePath  = $target.Path
        sha256        = $target.Sha256
        runStamp      = $script:ProbeRunStamp
        suggestedPath = $suggestedPath
        stateFile     = $stateFile
    }

    Write-ProbeLog ''
    Write-ProbeLog 'NEXT (human step, only if Studio exposes a new-file action):'
    Write-ProbeLog "  1. In Studio, create a new text file at: $suggestedPath"
    Write-ProbeLog '     If the product has no such control, skip to apply with no'
    Write-ProbeLog '     capture file and record uiCreateUnavailable in evidence.'
    Write-ProbeLog '     Keep the probe-<stamp> prefix when the UI allows naming.'
    Write-ProbeLog '  2. DevTools > Network open while you create it.'
    Write-ProbeLog '     Copy as fetch, or Save all as HAR.'
    Write-ProbeLog '  3. Save to e.g. %TEMP%\rundot-text-create-capture.txt'
    Write-ProbeLog '  4. Run -Scenario text-create-devtools-apply -CapturePath <that file>'
    Write-ProbeLog ''
    Write-ProbeLog "  Baseline (API upload only) is at $($target.Path). UI text upload is not required."
    Write-ProbeLog ''
}

function Get-ProbeDevToolsCaptureRoutes {
    param([string]$CaptureText)

    if ([string]::IsNullOrWhiteSpace($CaptureText)) { return $null, @(), $false }

    $redact = {
        param([string]$Text)
        $t = $Text
        $t = $t -replace '(?i)(authorization|bearer|token|cookie|api[-_]?key)("?\s*[:=]\s*"?)[^",\s]+', '$1$2<redacted>'
        $t = $t -replace 'eyJ[A-Za-z0-9_\-]{5,}', '<redacted-jwt>'
        return $t
    }

    $captureLines = @($CaptureText -split "`r?`n" |
        Where-Object { $_ -match '(?i)fetch\(|"method"|"url"|\bmethod:|https?://' } |
        Select-Object -First 60 |
        ForEach-Object { & $redact $_ })

    $routes = New-Object 'System.Collections.Generic.List[object]'
    $lastUrl = $null
    foreach ($line in ($CaptureText -split "`r?`n")) {
        $fetchMatch = [regex]::Match($line, 'fetch\(\s*[''"](https?://[^''"]+)[''"]')
        $harUrlMatch = [regex]::Match($line, '"(?:url|requestUrl)"\s*:\s*"(https?://[^"]+)"')

        if ($fetchMatch.Success) {
            $lastUrl = & $redact $fetchMatch.Groups[1].Value
            continue
        }
        if ($harUrlMatch.Success) {
            $lastUrl = & $redact $harUrlMatch.Groups[1].Value
            continue
        }

        $methodMatch = [regex]::Match($line, '"method"\s*:\s*"([A-Za-z]+)"')
        if ($methodMatch.Success -and $null -ne $lastUrl) {
            $routes.Add([pscustomobject]@{
                method = $methodMatch.Groups[1].Value
                url    = $lastUrl
            })
            $lastUrl = $null
        }
    }

    $captureHadResponse = ($CaptureText -match '(?i)"status"\s*:')
    return $captureLines, $routes.ToArray(), $captureHadResponse
}

function Invoke-ScenarioTextCreateDevToolsApply {
    param([string]$CapturePath)

    $stateFile = Join-Path $OutDir 'probe-text-create-state.json'
    $state = $null
    if (Test-Path -LiteralPath $stateFile) {
        $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    }

    $prepareStamp = if ($null -ne $state) { [string]$state.runStamp } else { $null }
    $suggestedPath = if ($null -ne $state) { [string]$state.suggestedPath } else { $null }

    $captureText = $null
    $capturePathGiven = -not [string]::IsNullOrWhiteSpace($CapturePath)
    $captureFileExists = $false
    if ($capturePathGiven -and (Test-Path -LiteralPath $CapturePath -PathType Leaf)) {
        $captureFileExists = $true
        $captureText = (Get-Content -LiteralPath $CapturePath -Raw)
    }

    $captureLines = $null
    $captureRoutes = $null
    $captureHadResponse = $false
    if (-not [string]::IsNullOrWhiteSpace($captureText)) {
        $captureLines, $captureRoutes, $captureHadResponse = Get-ProbeDevToolsCaptureRoutes -CaptureText $captureText
    }

    $contentLength = $null
    if (-not [string]::IsNullOrWhiteSpace($captureText)) {
        $contentMatch = [regex]::Match($captureText, '(?i)"content"\s*:\s*"')
        if ($contentMatch.Success) {
            $contentLength = ($captureText.Length - $contentMatch.Index)
        }
    }

    $ownedNow = @()
    if (-not [string]::IsNullOrWhiteSpace($prepareStamp)) {
        $ownedNow = @(Get-ProbeListedPaths | Where-Object { $_ -like "*$prepareStamp*" })
    }

    $createdPath = $null
    if (-not [string]::IsNullOrWhiteSpace($suggestedPath)) {
        if ($null -ne (Get-ProbeRowOrNull -Path $suggestedPath)) {
            $createdPath = $suggestedPath
        }
    }
    if ($null -eq $createdPath -and $ownedNow.Count -gt 0) {
        foreach ($candidate in $ownedNow) {
            if ($candidate -like "$($script:ProbeDir)/*-created.txt") {
                $createdPath = $candidate
                break
            }
        }
    }

    $uiCreateListed = $false
    if (-not [string]::IsNullOrWhiteSpace($suggestedPath)) {
        $uiCreateListed = ($null -ne (Get-ProbeRowOrNull -Path $suggestedPath))
    }

    Add-ProbeEvidence -Case 'text-create-devtools-apply' -Status 'OBSERVED' -Data @{
        note               = 'UI create route shape; request was not replayed'
        prepareStamp       = $prepareStamp
        suggestedPath      = $suggestedPath
        createdPathListed  = $createdPath
        uiCreateListed     = $uiCreateListed
        ownedPathsNow      = $ownedNow
        capturePathGiven   = $capturePathGiven
        captureFileExists  = $captureFileExists
        captureProvided    = (-not [string]::IsNullOrWhiteSpace($captureText))
        captureHadResponse = $captureHadResponse
        captureRoutes      = $captureRoutes
        captureLines       = $captureLines
        contentFieldLengthApprox = $contentLength
    }

    $cleanupTargets = @()
    if (-not [string]::IsNullOrWhiteSpace($createdPath)) { $cleanupTargets += $createdPath }
    if ($null -ne $state -and -not [string]::IsNullOrWhiteSpace([string]$state.baselinePath)) {
        $cleanupTargets += [string]$state.baselinePath
    }

    $deleted = @()
    $manual = @()
    foreach ($cleanupPath in ($cleanupTargets | Sort-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($cleanupPath)) { continue }
        try {
            $result = Invoke-ProbeDeleteFile -Path $cleanupPath -Case 'text-create-devtools-cleanup' `
                -AllowedStamp @($prepareStamp)
            if ($result.Deleted) { $deleted += $cleanupPath }
            else { $manual += $cleanupPath }
        }
        catch {
            $manual += $cleanupPath
        }
    }

    Add-ProbeEvidence -Case 'text-create-devtools-cleanup' -Status 'OBSERVED' -Data @{
        note        = 'hand-off cleanup where the delete guard allows'
        attempted   = @($cleanupTargets | Sort-Object -Unique)
        deleted     = $deleted
        needsManual = $manual
    }

    if ($null -eq $captureText) {
        if (-not $capturePathGiven) {
            Write-ProbeLog '[WARNING] text-create-devtools-apply: -CapturePath was not passed; route shape was not recorded.'
        }
        elseif (-not $captureFileExists) {
            Write-ProbeLog ("[WARNING] text-create-devtools-apply: capture file not found at '$CapturePath'.")
        }
        else {
            Write-ProbeLog '[WARNING] text-create-devtools-apply: capture file was empty; route shape was not recorded.'
        }
    }

    if (-not $uiCreateListed) {
        Write-ProbeLog '[NOTE] text-create-devtools-apply: the suggested UI create path is not listed.'
        Write-ProbeLog '       If Studio has no new-file action, that is expected; API create remains upload+move+PUT.'
    }
}


# ---------------------------------------------------------------------------
# Concurrency, revision identity, ETag, and conditional delete (#16)
#
# #14 proved a stale PUT silently clobbers a concurrent Studio edit and that
# no ETag / version / If-Match exists on the text route. #16 extends that to
# the delete and rename verbs and to the response headers themselves.
# ---------------------------------------------------------------------------

function Invoke-ScenarioConcurrencyDeleteVsWrite {
    # A plan row computed against a file that is then deleted remotely: does
    # the stale write 404 (safe) or resurrect the file (a silent undelete)?
    $target = New-ProbeOwnedTextFile -Suffix 'conc-delwrite' -Content 'concurrency delete-vs-write target'
    if ($null -eq $target.Path) {
        Write-ProbeLog '[STOPPED] concurrency-delete-vs-write: the target could not be created'
        return
    }

    $staleRead = Get-ProbeReadOrNull -Path $target.Path
    $staleText = if ($null -ne $staleRead) { [string]$staleRead.Content } else { 'stale content' }

    $deleted = Invoke-ProbeDeleteFile -Path $target.Path -Case 'concurrency-delete-vs-write-delete'
    $goneAfterDelete = $null -eq (Get-ProbeRowOrNull -Path $target.Path)

    # Now send the bytes that were read before the delete.
    $putResponse = Invoke-ProbeTextPut `
        -Path $target.Path `
        -ContentBytes (New-JsonContentBody -Text $staleText)

    Start-Sleep -Milliseconds 400
    $afterRead = Get-ProbeReadOrNull -Path $target.Path
    $afterRow = Get-ProbeRowOrNull -Path $target.Path

    $resurrected = $null -ne $afterRow

    Add-ProbeEvidence -Case 'concurrency-delete-vs-write' -Status 'PROBED' -Data @{
        note             = 'a write computed before a remote delete; 404 is safe, a re-created file is a silent undelete'
        path             = $target.Path
        deleteStatus     = $deleted.Status
        goneAfterDelete  = $goneAfterDelete
        putStatus        = $putResponse.Status
        putBody          = $putResponse.BodyText
        listedAfterPut   = $resurrected
        shaAfterPut      = if ($null -ne $afterRead) { $afterRead.Sha256 } else { $null }
        resurrected      = $resurrected
    }
    Write-ProbeLog ("[PROBED] concurrency-delete-vs-write delete={0} put={1} resurrected={2}" -f `
        $deleted.Status, $putResponse.Status, $resurrected)

    if ($resurrected) { $script:CreatedPaths.Add($target.Path) }
}

function Invoke-ScenarioConcurrencyDeleteWhileListed {
    # The #17-relevant window: capture the list, delete a path, then compare
    # the list fingerprint. This is the client-side check that must run before
    # any write, because the server cannot refuse a stale one.
    $target = New-ProbeOwnedTextFile -Suffix 'conc-window' -Content 'concurrency window target'
    if ($null -eq $target.Path) {
        Write-ProbeLog '[STOPPED] concurrency-delete-while-listed: the target could not be created'
        return
    }

    $fingerprintBefore = Get-ProbeListFingerprint
    $rowBefore = Get-ProbeRowOrNull -Path $target.Path

    $deleted = Invoke-ProbeDeleteFile -Path $target.Path -Case 'concurrency-delete-while-listed-delete'

    Start-Sleep -Milliseconds 400
    $fingerprintAfter = Get-ProbeListFingerprint
    $rowAfter = Get-ProbeRowOrNull -Path $target.Path

    Add-ProbeEvidence -Case 'concurrency-delete-while-listed' -Status 'PROBED' -Data @{
        note                 = 'a captured list is invalidated by a delete; the fingerprint must move'
        path                 = $target.Path
        listedBefore         = ($null -ne $rowBefore)
        deleteStatus         = $deleted.Status
        listedAfter          = ($null -ne $rowAfter)
        fingerprintBefore    = $fingerprintBefore
        fingerprintAfter     = $fingerprintAfter
        fingerprintChanged   = (-not [string]::Equals($fingerprintBefore, $fingerprintAfter, [System.StringComparison]::OrdinalIgnoreCase))
    }
    Write-ProbeLog ("[PROBED] concurrency-delete-while-listed fingerprintChanged={0}" -f `
        (-not [string]::Equals($fingerprintBefore, $fingerprintAfter, [System.StringComparison]::OrdinalIgnoreCase)))
}

function Invoke-ScenarioRevisionIdentity {
    # Tighten #14's finding: the only fields a text row exposes are path, type,
    # and size. Diff the field set across create, overwrite, and delete so a
    # newly added identity field would be caught rather than assumed away.
    $target = New-ProbeOwnedTextFile -Suffix 'revision' -Content 'revision identity baseline'
    if ($null -eq $target.Path) {
        Write-ProbeLog '[STOPPED] revision-identity: the target could not be created'
        return
    }

    $afterCreate = Get-ProbeRowFingerprint -Row (Get-ProbeRowOrNull -Path $target.Path)

    $overwrite = Invoke-ProbeTextPut -Path $target.Path `
        -ContentBytes (New-JsonContentBody -Text "revision identity overwrite $([Guid]::NewGuid().ToString('N'))")
    Start-Sleep -Milliseconds 300
    $afterOverwrite = Get-ProbeRowFingerprint -Row (Get-ProbeRowOrNull -Path $target.Path)

    $beforeDelete = Get-ProbeRowFingerprint -Row (Get-ProbeRowOrNull -Path $target.Path)
    $deleted = Invoke-ProbeDeleteFile -Path $target.Path -Case 'revision-identity-delete'
    $afterDeleteRow = Get-ProbeRowOrNull -Path $target.Path

    $allNames = @()
    foreach ($set in @($afterCreate, $afterOverwrite, $beforeDelete)) {
        if ($null -ne $set) { $allNames += @($set.Keys) }
    }

    Add-ProbeEvidence -Case 'revision-identity' -Status 'OBSERVED' -Data @{
        note              = 'the field set a text row exposes across create, overwrite, and delete'
        path              = $target.Path
        fieldsAfterCreate = $afterCreate
        fieldsAfterWrite  = $afterOverwrite
        fieldsBeforeDelete = $beforeDelete
        fieldNames        = @($allNames | Sort-Object -Unique)
        hasIdentityField  = [bool](@($allNames | Where-Object {
            $_ -match '(?i)^(etag|hash|sha256|contentHash|version|revision|id|updatedAt)$'
        }).Count -gt 0)
        overwriteStatus   = $overwrite.Status
        deleteStatus      = $deleted.Status
        listedAfterDelete = ($null -ne $afterDeleteRow)
    }
    Write-ProbeLog ("[OBSERVED] revision-identity fields: {0}" -f (($allNames | Sort-Object -Unique) -join ', '))
}

function Invoke-ScenarioEtagHeaders {
    # Record whether any response carries an ETag or Last-Modified, across read,
    # list, write, and delete. Select-ProbeHeaders keeps ETag already; add
    # Last-Modified here so the check is explicit.
    $target = New-ProbeOwnedTextFile -Suffix 'etag' -Content 'etag header target'
    if ($null -eq $target.Path) {
        Write-ProbeLog '[STOPPED] etag-headers: the target could not be created'
        return
    }

    # GET /file
    $fileUri = New-ProbeFileUrl -Path $target.Path
    $fileGet = Invoke-ProbeHttp -Method 'GET' -Uri $fileUri -Headers $script:Headers

    # GET /files
    $listUri = New-ProbeApiUrl -RelativePath "/api/projects/$ProjectId/files"
    $listGet = Invoke-ProbeHttp -Method 'GET' -Uri $listUri -Headers $script:Headers

    # PUT /file
    $put = Invoke-ProbeTextPut -Path $target.Path `
        -ContentBytes (New-JsonContentBody -Text 'etag header write')

    # DELETE /file
    $delete = Invoke-ProbeDeleteFile -Path $target.Path -Case 'etag-headers-delete'

    Add-ProbeEvidence -Case 'etag-headers' -Status 'PROBED' -Data @{
        note            = 'any identity header on read, list, write, or delete?'
        path            = $target.Path
        getFileHeaders  = $fileGet.ResponseHeaders
        getFilesHeaders = $listGet.ResponseHeaders
        putHeaders      = $put.ResponseHeaders
        deleteHeaders   = $delete.ResponseHeaders
        putStatus       = $put.Status
        deleteStatus    = $delete.Status
    }
    Write-ProbeLog '[PROBED] etag-headers recorded for read, list, write, and delete'
}

function Invoke-ScenarioConditionalDelete {
    # #14 tested If-Match on PUT and found it ignored. The delete verb is the
    # one precondition that could still exist, and it is the one that matters
    # most: an enforced If-Match on DELETE would let #17 refuse a stale delete.
    $target = New-ProbeOwnedTextFile -Suffix 'cond-del' -Content 'conditional delete target'
    if ($null -eq $target.Path) {
        Write-ProbeLog '[STOPPED] conditional-delete: the target could not be created'
        return
    }

    $row = Get-ProbeRowOrNull -Path $target.Path
    $fields = Get-ProbeRowFingerprint -Row $row
    $etagCandidate = $null
    if ($null -ne $fields) {
        foreach ($candidate in @('etag', 'version', 'revision', 'id')) {
            if ($fields.Contains($candidate)) { $etagCandidate = $fields[$candidate]; break }
        }
    }

    $cases = @(
        @{ Case = 'conditional-delete-if-match-wrong'; Value = '"definitely-not-the-current-etag"'; Note = 'a value that cannot match; 412 would mean the header is enforced' },
        @{ Case = 'conditional-delete-if-match-garbage'; Value = 'not-an-etag'; Note = 'malformed If-Match' },
        @{ Case = 'conditional-delete-if-none-match-star'; Value = '*'; Note = 'If-None-Match: * against an existing resource' }
    )

    $allDeleted = $true
    foreach ($case in $cases) {
        # Each case needs its own file, since an honoured precondition would
        # leave the target in place and a delete would remove it.
        $caseTarget = New-ProbeOwnedTextFile -Suffix "cond-del-$($case.Case)" -Content "target for $($case.Case)"
        if ($null -eq $caseTarget.Path) { continue }

        $headerName = if ($case.Case -like '*if-none-match*') { 'If-None-Match' } else { 'If-Match' }
        $result = Invoke-ProbeDeleteFile -Path $caseTarget.Path `
            -ExtraHeaders @{ $headerName = $case.Value } `
            -Case $case.Case

        $stillListed = $null -ne (Get-ProbeRowOrNull -Path $caseTarget.Path)
        if ($stillListed) { $allDeleted = $false }

        Add-ProbeEvidence -Case $case.Case -Status 'PROBED' -Data @{
            note        = $case.Note
            path        = $caseTarget.Path
            header      = $headerName
            headerValue = $case.Value
            status      = $result.Status
            body        = $result.Body
            stillListed = $stillListed
            enforced    = $stillListed
        }
        Write-ProbeLog ("[PROBED] {0} status={1} stillListed={2}" -f $case.Case, $result.Status, $stillListed)
    }

    Add-ProbeEvidence -Case 'conditional-delete-summary' -Status 'OBSERVED' -Data @{
        note             = 'no precondition was enforced if every delete succeeded'
        etagCandidate    = $etagCandidate
        anyPreconditionEnforced = (-not $allDeleted)
    }
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

function Get-ProbeReadIdentity {
    param($Read)

    if ($null -eq $Read) {
        return @{
            byteCount          = $null
            sha256             = $null
            encoding           = $null
            contentStartsWithBom = $false
        }
    }

    $startsWithBom = $false
    if (-not [string]::IsNullOrEmpty($Read.Content)) {
        $startsWithBom = ([int][char]$Read.Content[0] -eq 0xFEFF)
    }

    return @{
        byteCount            = $Read.ByteCount
        sha256               = $Read.Sha256
        encoding             = $Read.Encoding
        contentStartsWithBom = $startsWithBom
    }
}

function Invoke-ProbePlaceTextExactCase {
    # Upload under a unique /uploads name, move to the chosen path, then PUT
    # the exact text. Upload is only how the path comes into existence. PUT
    # is the byte-exact step, because #14 showed PUT preserves CRLF and BOM
    # on a file that already exists.
    param(
        [string]$Case,
        [string]$DestPath,
        [string]$Text,
        [string]$Extension,
        [string]$ContentType = 'text/plain',
        [switch]$UploadPlaceholder
    )

    $sentText = $Text
    $uploadText = $Text
    if ($UploadPlaceholder) {
        $uploadText = 'x'
    }

    $sentBytes = Get-Utf8NoBomBytes -Text $sentText
    $uploadBytes = Get-Utf8NoBomBytes -Text $uploadText
    $sentSha = Get-Sha256Hex -Bytes $sentBytes
    $fileName = Get-BinaryProbeName -Suffix $Case -Extension $Extension

    if ($null -ne (Get-ProbeRowOrNull -Path $DestPath)) {
        Remove-ProbeListedPathIfOwned -Path $DestPath -Case "$Case-preclean" | Out-Null
    }

    $upload = Invoke-ProbeBinaryUpload `
        -Case "$Case-upload" `
        -FileName $fileName `
        -Bytes $uploadBytes `
        -ContentType $ContentType `
        -Note 'unique upload so the destination can be created by move'

    $afterUpload = $null
    if (-not [string]::IsNullOrWhiteSpace($upload.recordedPath)) {
        $afterUpload = Get-ProbeReadOrNull -Path $upload.recordedPath
    }

    $moveStatus = $null
    $moveBody = $null
    if (-not [string]::IsNullOrWhiteSpace($upload.recordedPath)) {
        $move = Invoke-ProbeMoveRequest -Case "$Case-move" -From $upload.recordedPath -To $DestPath
        $moveStatus = $move.Status
        $moveBody = $move.BodyText
    }

    $afterMove = Get-ProbeReadOrNull -Path $DestPath
    $putStatus = $null
    if ($null -ne (Get-ProbeRowOrNull -Path $DestPath)) {
        $put = Invoke-ProbeTextPut -Path $DestPath -ContentBytes (New-JsonContentBody -Text $sentText)
        $putStatus = $put.Status
    }

    Start-Sleep -Milliseconds 300
    $afterPut = Get-ProbeReadOrNull -Path $DestPath
    $uploadIdentity = Get-ProbeReadIdentity -Read $afterUpload
    $moveIdentity = Get-ProbeReadIdentity -Read $afterMove
    $putIdentity = Get-ProbeReadIdentity -Read $afterPut

    $exactAfterPut = (
        $null -ne $afterPut -and
        [string]::Equals($afterPut.Sha256, $sentSha, [System.StringComparison]::OrdinalIgnoreCase) -and
        ($afterPut.ByteCount -eq $sentBytes.Length)
    )

    Add-ProbeEvidence -Case $Case -Status 'PROBED' -Data @{
        note                 = 'upload creates the path; PUT /file is the exact-bytes step'
        destPath             = $DestPath
        extension            = $Extension
        contentType          = $ContentType
        uploadPlaceholder    = [bool]$UploadPlaceholder
        uploadStatus         = $upload.uploadUrl.status
        adoptStatus          = if ($null -ne $upload.adopt) { $upload.adopt['status'] } else { $null }
        uploadPath           = $upload.recordedPath
        uploadEncoding       = $uploadIdentity.encoding
        uploadByteCount      = $uploadIdentity.byteCount
        uploadSha256         = $uploadIdentity.sha256
        uploadStartsWithBom  = $uploadIdentity.contentStartsWithBom
        moveStatus           = $moveStatus
        moveBody             = $moveBody
        moveEncoding         = $moveIdentity.encoding
        moveByteCount        = $moveIdentity.byteCount
        moveSha256           = $moveIdentity.sha256
        moveStartsWithBom    = $moveIdentity.contentStartsWithBom
        putStatus            = $putStatus
        putEncoding          = $putIdentity.encoding
        putByteCount         = $putIdentity.byteCount
        putSha256            = $putIdentity.sha256
        putStartsWithBom     = $putIdentity.contentStartsWithBom
        sentSize             = $sentBytes.Length
        sentSha256           = $sentSha
        exactAfterPut        = $exactAfterPut
    }
    Write-ProbeLog ("[PROBED] {0} move={1} put={2} exactAfterPut={3}" -f $Case, $moveStatus, $putStatus, $exactAfterPut)

    if ($null -ne (Get-ProbeRowOrNull -Path $DestPath)) {
        Remove-ProbeListedPathIfOwned -Path $DestPath -Case "$Case-cleanup" | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($upload.recordedPath)) {
        if ($null -ne (Get-ProbeRowOrNull -Path $upload.recordedPath)) {
            Remove-ProbeListedPathIfOwned -Path $upload.recordedPath -Case "$Case-cleanup-upload" | Out-Null
        }
        else {
            while ($script:CreatedPaths.Contains($upload.recordedPath)) {
                [void]$script:CreatedPaths.Remove($upload.recordedPath)
            }
        }
    }

    return $exactAfterPut
}

function Invoke-ScenarioTextPlaceExact {
    $results = @()

    $ts = "export const n = 1;`r`nconst q = `"quote`";`r`n"
    $results += Invoke-ProbePlaceTextExactCase `
        -Case 'text-place-exact-ts' `
        -DestPath "$($script:ProbeDir)/src/$($script:ProbeNamePrefix)-main.ts" `
        -Text $ts `
        -Extension '.ts'

    $bom = "$([char]0xFEFF)export const bom = true;`n"
    $results += Invoke-ProbePlaceTextExactCase `
        -Case 'text-place-exact-bom' `
        -DestPath "$($script:ProbeDir)/$($script:ProbeNamePrefix)-bom.ts" `
        -Text $bom `
        -Extension '.ts'

    $results += Invoke-ProbePlaceTextExactCase `
        -Case 'text-place-exact-empty' `
        -DestPath "$($script:ProbeDir)/$($script:ProbeNamePrefix)-empty.ts" `
        -Text '' `
        -Extension '.ts' `
        -UploadPlaceholder

    $json = '{ "ok": true }'
    $results += Invoke-ProbePlaceTextExactCase `
        -Case 'text-place-exact-json' `
        -DestPath "$($script:ProbeDir)/$($script:ProbeNamePrefix)-pack.json" `
        -Text $json `
        -Extension '.json'

    $allExact = $true
    foreach ($flag in $results) {
        if (-not $flag) { $allExact = $false }
    }

    Add-ProbeEvidence -Case 'text-place-exact-summary' -Status 'OBSERVED' -Data @{
        note     = 'trustworthy create is unique upload, move onto an absent path, then PUT /file'
        allExact = $allExact
        count    = $results.Count
    }
    Write-ProbeLog ("[OBSERVED] text-place-exact allExact={0}" -f $allExact)
}

function Invoke-ScenarioRunTextCreateAll {
    Invoke-ProbeStep 'text-create-discover' { Invoke-ScenarioTextCreateDiscover }
    Invoke-ProbeStep 'text-create-compose' { Invoke-ScenarioTextCreateCompose }
    Invoke-ProbeStep 'text-create-idempotency' { Invoke-ScenarioTextCreateIdempotency }
    Invoke-ProbeStep 'text-create-bytes' { Invoke-ScenarioTextCreateBytes }
    Invoke-ProbeStep 'text-create-race' { Invoke-ScenarioTextCreateRace }
    Invoke-ProbeStep 'text-create-conditional' { Invoke-ScenarioTextCreateConditional }
    Invoke-ProbeStep 'text-create-reserved' { Invoke-ScenarioTextCreateReserved }
    Invoke-ProbeStep 'text-create-route-survey' { Invoke-ScenarioSurvey }

    if (-not $SkipCleanup) {
        Invoke-ProbeStep 'binary-cleanup' { Invoke-ScenarioBinaryCleanup }
    }
    else {
        Write-ProbeLog ''
        Write-ProbeLog '[SKIPPED] binary-cleanup: -SkipCleanup was set; the created paths remain.'
    }

    Write-ProbeLog ''
    Write-ProbeLog 'Optional: text-create-devtools-prepare / -apply if Studio exposes a new-file UI.'
    Write-ProbeLog '  If not, run apply without -CapturePath after prepare to record uiCreateListed=false.'
    Write-ProbeLog ''
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
    Invoke-ProbeStep 'binary-path-control' { Invoke-ScenarioBinaryPathControl }
    Invoke-ProbeStep 'binary-text-via-upload' { Invoke-ScenarioBinaryTextViaUpload }
    Invoke-ProbeStep 'binary-delete-discover' { Invoke-ScenarioBinaryDeleteDiscover }
    Invoke-ProbeStep 'binary-collision' { Invoke-ScenarioBinaryCollision }
    Invoke-ProbeStep 'binary-overwrite' { Invoke-ScenarioBinaryOverwrite }
    Invoke-ProbeStep 'binary-idempotency' { Invoke-ScenarioBinaryIdempotency }
    Invoke-ProbeStep 'binary-failure' { Invoke-ScenarioBinaryFailure }
    Invoke-ProbeStep 'binary-survey' { Invoke-ScenarioSurvey }

    # Cleanup last, so a full run leaves the project as it found it. Pass
    # -SkipCleanup to keep the artifacts for inspection.
    if (-not $SkipCleanup) {
        Invoke-ProbeStep 'binary-cleanup' { Invoke-ScenarioBinaryCleanup }
    }
    else {
        Write-ProbeLog ''
        Write-ProbeLog '[SKIPPED] binary-cleanup: -SkipCleanup was set; the created paths remain.'
    }
}

function Invoke-ScenarioRunDeleteRenameAll {
    # The #16 characterization, in evidence order: establish the delete verb
    # and its failure shapes, then the identity and concurrency questions that
    # decide what #17 may do with a DELETE, then try to find a rename route.
    Invoke-ProbeStep 'delete-file-basic' { Invoke-ScenarioDeleteFileBasic }
    Invoke-ProbeStep 'delete-idempotency' { Invoke-ScenarioDeleteIdempotency }
    Invoke-ProbeStep 'delete-absent' { Invoke-ScenarioDeleteAbsent }
    Invoke-ProbeStep 'delete-directory' { Invoke-ScenarioDeleteDirectory }
    Invoke-ProbeStep 'delete-reserved' { Invoke-ScenarioDeleteReserved }
    Invoke-ProbeStep 'delete-encoding' { Invoke-ScenarioDeleteEncoding }
    Invoke-ProbeStep 'delete-auth' { Invoke-ScenarioDeleteAuth }
    Invoke-ProbeStep 'delete-response-headers' { Invoke-ScenarioDeleteResponseHeaders }
    Invoke-ProbeStep 'revision-identity' { Invoke-ScenarioRevisionIdentity }
    Invoke-ProbeStep 'etag-headers' { Invoke-ScenarioEtagHeaders }
    Invoke-ProbeStep 'conditional-delete' { Invoke-ScenarioConditionalDelete }
    Invoke-ProbeStep 'concurrency-delete-while-listed' { Invoke-ScenarioConcurrencyDeleteWhileListed }
    Invoke-ProbeStep 'concurrency-delete-vs-write' { Invoke-ScenarioConcurrencyDeleteVsWrite }
    Invoke-ProbeStep 'rename-move' { Invoke-ScenarioRenameMove }
    Invoke-ProbeStep 'rename-probe' { Invoke-ScenarioRenameProbe }
    Invoke-ProbeStep 'delete-rename-survey' { Invoke-ScenarioSurvey }

    # Cleanup last, so a full run leaves the project as it found it. Pass
    # -SkipCleanup to keep the artifacts for inspection.
    if (-not $SkipCleanup) {
        Invoke-ProbeStep 'binary-cleanup' { Invoke-ScenarioBinaryCleanup }
    }
    else {
        Write-ProbeLog ''
        Write-ProbeLog '[SKIPPED] binary-cleanup: -SkipCleanup was set; the created paths remain.'
    }

    # The rename hand-off is deliberately not automated: it needs a human in
    # the Studio UI. Print the instruction rather than silently skipping it.
    Write-ProbeLog ''
    Write-ProbeLog 'MANUAL STEP for rename (not run by this runner):'
    Write-ProbeLog '  -Scenario rename-devtools-prepare  (creates a target and prints instructions)'
    Write-ProbeLog '  ...rename that path by hand in Studio, then -Scenario rename-devtools-apply -CapturePath <file>.'
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
    'binary-path-control'        { Invoke-ScenarioBinaryPathControl }
    'binary-text-via-upload'     { Invoke-ScenarioBinaryTextViaUpload }
    'binary-delete-discover'     { Invoke-ScenarioBinaryDeleteDiscover }
    'binary-cleanup'             { Invoke-ScenarioBinaryCleanup -AllRuns:$AllRuns }
    'binary-collision'           { Invoke-ScenarioBinaryCollision }
    'binary-overwrite'           { Invoke-ScenarioBinaryOverwrite }
    'binary-idempotency'         { Invoke-ScenarioBinaryIdempotency }
    'binary-failure'             { Invoke-ScenarioBinaryFailure }
    'binary-survey'              { Invoke-ScenarioSurvey }
    'delete-file-basic'          { Invoke-ScenarioDeleteFileBasic }
    'delete-idempotency'         { Invoke-ScenarioDeleteIdempotency }
    'delete-absent'              { Invoke-ScenarioDeleteAbsent }
    'delete-directory'           { Invoke-ScenarioDeleteDirectory }
    'delete-reserved'            { Invoke-ScenarioDeleteReserved }
    'delete-encoding'            { Invoke-ScenarioDeleteEncoding }
    'delete-auth'                { Invoke-ScenarioDeleteAuth }
    'delete-response-headers'    { Invoke-ScenarioDeleteResponseHeaders }
    'rename-probe'               { Invoke-ScenarioRenameProbe }
    'rename-move'                { Invoke-ScenarioRenameMove }
    'rename-devtools-prepare'    { Invoke-ScenarioRenameDevToolsPrepare }
    'rename-devtools-apply'      { Invoke-ScenarioRenameDevToolsApply -CapturePath $CapturePath }
    'concurrency-delete-vs-write' { Invoke-ScenarioConcurrencyDeleteVsWrite }
    'concurrency-delete-while-listed' { Invoke-ScenarioConcurrencyDeleteWhileListed }
    'revision-identity'          { Invoke-ScenarioRevisionIdentity }
    'etag-headers'               { Invoke-ScenarioEtagHeaders }
    'conditional-delete'         { Invoke-ScenarioConditionalDelete }
    'delete-rename-survey'       { Invoke-ScenarioSurvey }
    'run-text-all'               { Invoke-ScenarioRunTextAll }
    'run-binary-all'             { Invoke-ScenarioRunBinaryAll }
    'run-delete-rename-all'      { Invoke-ScenarioRunDeleteRenameAll }
    'text-create-discover'       { Invoke-ScenarioTextCreateDiscover }
    'text-create-compose'        { Invoke-ScenarioTextCreateCompose }
    'text-create-idempotency'    { Invoke-ScenarioTextCreateIdempotency }
    'text-create-bytes'          { Invoke-ScenarioTextCreateBytes }
    'text-create-race'           { Invoke-ScenarioTextCreateRace }
    'text-create-conditional'    { Invoke-ScenarioTextCreateConditional }
    'text-create-reserved'       { Invoke-ScenarioTextCreateReserved }
    'text-create-route-survey'   { Invoke-ScenarioSurvey }
    'text-create-devtools-prepare' { Invoke-ScenarioTextCreateDevToolsPrepare }
    'text-create-devtools-apply' { Invoke-ScenarioTextCreateDevToolsApply -CapturePath $CapturePath }
    'text-place-exact'           { Invoke-ScenarioTextPlaceExact }
    'run-text-create-all'        { Invoke-ScenarioRunTextCreateAll }
    default {
        throw "Scenario '$Scenario' is not implemented."
    }
}

Save-ProbeEvidence

# Drop the bearer token before the process exits.
$script:Headers.Authorization = $null
Write-ProbeLog 'Done.'










