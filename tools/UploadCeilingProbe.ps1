# Upload-ceiling / large-file publish probe. NOT part of the product.
#
# Follow-up to the read-limit work (#51, #54): a RUN Discord patch note claimed
# uploads "up to 200 MB", which needed checking against the API.
#
# Questions:
#   1. What is the real ceiling on `declaredSize` at POST /upload-url? The only
#      recorded data point is 104,857,600 -> 413, and a Discord patch note
#      claims "up to 200 MB". Is the ceiling 100 MB, 200 MB, or a byte count?
#   2. Does a large body actually survive the presigned PUT? The current doc
#      only proves the ETag is a plain MD5 up to 50 MB.
#   3. Does the ETag stay a plain content MD5 at the ceiling (no multipart
#      `-<count>` suffix)? If it goes multipart, ETag identity stops working.
#   4. Can a large payload be published as an EDITABLE text file? PUT /file
#      refuses over 2,000,000 characters, but upload with
#      Content-Type: text/plain + move may store large text without PUT.
#   5. Can a large file be REPLACED (delete-then-place)? A replace needs the
#      old bytes for a backup and an expectedRemoteHash gate; GET /file cannot
#      return them. This probe measures whether a delete+place is even
#      possible and what identity survives.
#
# Safety: writes only under /sync-probe/upload-ceiling-<runstamp>, creates its
# targets through the upload flow, and deletes exactly what it created. Never
# prints the token. Use a DISPOSABLE project.
#
#   .\tools\UploadCeilingProbe.ps1 -ProjectId <id>            # dry run
#   .\tools\UploadCeilingProbe.ps1 -ProjectId <id> -ConfirmRemoteWrite
#   .\tools\UploadCeilingProbe.ps1 -ProjectId <id> -ConfirmRemoteWrite -CeilingScan

param(
    [Parameter(Mandatory)][string]$ProjectId,
    [string]$StudioOrigin = 'https://venus-studio-prod.series-ai.workers.dev',
    [string]$RundotCliSessionPath = (Join-Path $env:APPDATA '.rundot\prod.session.json'),
    # A file holding a fresh bearer token. Preferred over the interactive
    # resolver, which BLOCKS on a Read-Host prompt when the CLI session is
    # expired (that is how two earlier scans hung).
    [string]$AccessTokenPath,
    # Walk declaredSize upward to pin the exact ceiling. Off by default because
    # each step can upload up to the ceiling.
    [switch]$CeilingScan,
    [switch]$ConfirmRemoteWrite
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib\Paths.ps1')
. (Join-Path $repoRoot 'lib\Hashing.ps1')
. (Join-Path $repoRoot 'lib\Auth.ps1')

$readLimit = Get-SyncStudioMaxReadableFileSize
$runStamp = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$probeDir = 'sync-probe/upload-ceiling-' + $runStamp
$created = New-Object 'System.Collections.Generic.List[string]'
$findings = New-Object 'System.Collections.Generic.List[string]'

# ---------------------------------------------------------------------------
# Byte + HTTP helpers (deliberately standalone; mirrors ReadLimitProbe.ps1)
# ---------------------------------------------------------------------------

function New-Bytes {
    # Deterministic, non-compressible-ish payload. Object storage may compress
    # or dedupe, so the bytes are varied rather than a single repeated value.
    param([int64]$Count)
    if ($Count -gt [int]::MaxValue) { throw 'New-Bytes only supports <= 2 GB.' }
    $bytes = New-Object byte[] ([int]$Count)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $bytes[$i] = [byte](($i * 31 + 7) % 251)
    }
    return $bytes
}

function Get-Md5Hex {
    param($Bytes)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        return ([System.BitConverter]::ToString($md5.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally { $md5.Dispose() }
}

function Get-Sha256HexLocal {
    param($Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Invoke-Http {
    # Never throws on a status; returns status + raw body bytes + selected
    # headers. Mirrors ReadLimitProbe.ps1 so both probes behave identically.
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers,
        [byte[]]$BodyBytes,
        [string]$ContentType,
        [int]$TimeoutMs = 600000
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
    if (-not [string]::IsNullOrEmpty($ContentType)) { $request.ContentType = $ContentType }

    $status = $null; $bytes = $null; $respHeaders = @{}; $err = $null
    try {
        if ($BodyBytes.Length -gt 0 -or $Method -in @('POST', 'PUT', 'PATCH')) {
            $request.ContentLength = $BodyBytes.Length
            $stream = $request.GetRequestStream()
            if ($BodyBytes.Length -gt 0) { $stream.Write($BodyBytes, 0, $BodyBytes.Length) }
            $stream.Dispose()
        }
        $response = $request.GetResponse()
        try {
            $status = [int]$response.StatusCode
            $stream = $response.GetResponseStream()
            $ms = New-Object System.IO.MemoryStream
            $stream.CopyTo($ms)
            $bytes = $ms.ToArray()
            foreach ($key in $response.Headers.AllKeys) { $respHeaders[$key] = [string]$response.Headers[$key] }
        }
        finally { $response.Dispose() }
    }
    catch [System.Net.WebException] {
        $err = $_.Exception
        $webResponse = $_.Exception.Response
        if ($null -ne $webResponse) {
            try {
                $httpResponse = [System.Net.HttpWebResponse]$webResponse
                $status = [int]$httpResponse.StatusCode
                try {
                    $stream = $httpResponse.GetResponseStream()
                    $ms = New-Object System.IO.MemoryStream
                    $stream.CopyTo($ms)
                    $bytes = $ms.ToArray()
                }
                catch { }
                try { foreach ($key in $httpResponse.Headers.AllKeys) { $respHeaders[$key] = [string]$httpResponse.Headers[$key] } } catch { }
            }
            finally { $webResponse.Dispose() }
        }
    }

    $keep = @{}
    foreach ($name in @('Content-Length', 'ETag', 'Content-Type')) {
        if ($respHeaders.ContainsKey($name)) { $keep[$name] = $respHeaders[$name] }
    }

    return [pscustomobject]@{ Status = $status; Bytes = $bytes; Headers = $keep; TransportError = $err }
}

function Get-ResponseText {
    param($Response)
    if ($null -eq $Response -or $null -eq $Response.Bytes -or $Response.Bytes.Length -eq 0) { return '' }
    return [System.Text.Encoding]::UTF8.GetString($Response.Bytes)
}

function Invoke-ApiJson {
    param([string]$Method, [string]$RelativePath, [string]$JsonBody)
    $bytes = $null
    if (-not [string]::IsNullOrEmpty($JsonBody)) {
        $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($JsonBody)
    }
    $r = Invoke-Http -Method $Method -Uri "$StudioOrigin$RelativePath" -Headers $script:Headers -BodyBytes $bytes -ContentType 'application/json'
    return $r
}

function Get-ListedPaths {
    $list = Invoke-Http -Method 'GET' -Uri "$StudioOrigin/api/projects/$ProjectId/files" -Headers $script:Headers
    $paths = @()
    if ($null -eq $list.Bytes -or $list.Bytes.Length -eq 0) { return $paths }
    $obj = (Get-ResponseText $list) | ConvertFrom-Json
    foreach ($entry in @($obj.files)) {
        if ($null -eq $entry) { continue }
        if ([string]$entry.type -ne 'file') { continue }
        $p = [string]$entry.path
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $paths += $p
    }
    return $paths
}

function Get-ListedRow {
    param([string]$AbsolutePath)
    $list = Invoke-Http -Method 'GET' -Uri "$StudioOrigin/api/projects/$ProjectId/files" -Headers $script:Headers
    if ($null -eq $list.Bytes -or $list.Bytes.Length -eq 0) { return $null }
    $obj = (Get-ResponseText $list) | ConvertFrom-Json
    foreach ($entry in @($obj.files)) {
        if ([string]::Equals([string]$entry.path, $AbsolutePath, [System.StringComparison]::Ordinal)) {
            return $entry
        }
    }
    return $null
}

function Get-FileBytes {
    # GET /file and decode. Returns $null on any non-200, so a caller can tell
    # "unreadable" from "read and empty".
    param([string]$AbsolutePath)
    $enc = [System.Uri]::EscapeDataString($AbsolutePath)
    $r = Invoke-Http -Method 'GET' -Uri "$StudioOrigin/api/projects/$ProjectId/file?path=$enc" -Headers $script:Headers
    if ($r.Status -ne 200 -or $null -eq $r.Bytes -or $r.Bytes.Length -eq 0) { return $null }
    try {
        $obj = (Get-ResponseText $r) | ConvertFrom-Json
        if ($null -ne $obj.content) {
            if ([string]$obj.encoding -eq 'base64') { return [Convert]::FromBase64String([string]$obj.content) }
            return (New-Object System.Text.UTF8Encoding $false).GetBytes([string]$obj.content)
        }
    }
    catch { }
    return $null
}

# ---------------------------------------------------------------------------
# The upload flow, one step at a time so each step's status is observable.
# ---------------------------------------------------------------------------

function Invoke-UploadUrl {
    param([int64]$DeclaredSize)
    return (Invoke-ApiJson -Method 'POST' -RelativePath "/api/projects/$ProjectId/upload-url" -JsonBody ('{"declaredSize":' + $DeclaredSize + '}'))
}

function Invoke-PresignedPut {
    param([string]$UploadUrl, [byte[]]$Bytes, [string]$ContentType)
    return (Invoke-Http -Method 'PUT' -Uri $UploadUrl -BodyBytes $Bytes -ContentType $ContentType)
}

function Invoke-Adopt {
    param([string]$UploadId, [string]$Name)
    $body = '{"uploadId":"' + $UploadId + '","name":"' + $Name + '"}'
    return (Invoke-ApiJson -Method 'POST' -RelativePath "/api/projects/$ProjectId/upload-adopt" -JsonBody $body)
}

function Invoke-Move {
    param([string]$From, [string]$To)
    $body = '{"from":"' + $From + '","to":"' + $To + '"}'
    return (Invoke-ApiJson -Method 'POST' -RelativePath "/api/projects/$ProjectId/move" -JsonBody $body)
}

function Publish-Bytes {
    # Upload + adopt + move in one call. Returns a record describing every step
    # so a failure names the step rather than just "publish failed".
    param(
        [byte[]]$Bytes,
        [string]$StagingName,
        [string]$DestinationAbsolute,
        [string]$ContentType = 'application/octet-stream'
    )

    $result = [ordered]@{
        declaredSize = $Bytes.Length
        stagingName  = $StagingName
        destination  = $DestinationAbsolute
        uploadUrl    = $null
        putStatus    = $null
        etag         = $null
        adoptStatus  = $null
        recordedPath = $null
        recordedSize = $null
        recordedMime = $null
        moveStatus   = $null
        moveTo       = $null
    }

    $u = Invoke-UploadUrl -DeclaredSize $Bytes.Length
    $result.uploadUrl = $u.Status
    if ($u.Status -ne 200) {
        $result.error = 'upload-url'
        $result.errorBody = Get-ResponseText $u
        return [pscustomobject]$result
    }
    $uObj = (Get-ResponseText $u) | ConvertFrom-Json
    if ([string]::IsNullOrEmpty([string]$uObj.uploadUrl)) {
        $result.error = 'upload-url-no-url'
        return [pscustomobject]$result
    }

    $p = Invoke-PresignedPut -UploadUrl ([string]$uObj.uploadUrl) -Bytes $Bytes -ContentType $ContentType
    $result.putStatus = $p.Status
    $result.etag = ([string]$p.Headers['ETag']).Trim([char]'"')
    if ($p.Status -notin @(200, 201)) {
        $result.error = 'presigned-put'
        return [pscustomobject]$result
    }

    $a = Invoke-Adopt -UploadId ([string]$uObj.uploadId) -Name $StagingName
    $result.adoptStatus = $a.Status
    if ($a.Status -ne 200) {
        $result.error = 'upload-adopt'
        $result.errorBody = Get-ResponseText $a
        return [pscustomobject]$result
    }
    $aObj = (Get-ResponseText $a) | ConvertFrom-Json
    $result.recordedPath = [string]$aObj.path
    $result.recordedSize = [string]$aObj.size
    $result.recordedMime = [string]$aObj.mimeType
    if ([string]::IsNullOrEmpty($result.recordedPath)) {
        $result.error = 'adopt-no-path'
        return [pscustomobject]$result
    }
    [void]$created.Add(([string]$result.recordedPath).TrimStart('/'))

    $m = Invoke-Move -From ([string]$result.recordedPath) -To $DestinationAbsolute
    $result.moveStatus = $m.Status
    if ($m.Status -ne 200) {
        $result.error = 'move'
        $result.errorBody = Get-ResponseText $m
        return [pscustomobject]$result
    }
    $mObj = (Get-ResponseText $m) | ConvertFrom-Json
    $movedTo = [string]$mObj.data.to
    if ([string]::IsNullOrEmpty($movedTo)) { $movedTo = [string]$mObj.to }
    $result.moveTo = $movedTo
    [void]$created.Add($DestinationAbsolute.TrimStart('/'))

    return [pscustomobject]$result
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host "Upload-ceiling probe: $StudioOrigin"
Write-Host "  project    : $ProjectId"
Write-Host "  probe dir  : /$probeDir"
Write-Host "  read limit : $readLimit bytes"
Write-Host ''

if (-not $ConfirmRemoteWrite) {
    Write-Host 'DRY RUN. Would run these probes:'
    Write-Host '  A. declaredSize sweep at /upload-url:'
    Write-Host '       0, 1, 104857600 (100 MB), 157286400 (150 MB), 209715200 (200 MB),'
    Write-Host '       209715201 (200 MB + 1)'
    Write-Host '     With -CeilingScan, binary-search the exact accepted ceiling between'
    Write-Host '     52,428,800 (known accepted) and 104,857,600 (known refused).'
    Write-Host '  B. body survival: upload a real 50 MiB body, report PUT status + ETag,'
    Write-Host '     and whether the ETag is a plain 32-hex MD5 of the local bytes.'
    Write-Host '  C. ETag shape by size: 50 MiB, and the ceiling if it differs.'
    Write-Host '  D. large TEXT publish: upload Content-Type text/plain at 2.85 MB,'
    Write-Host '     move to a .md path, then GET /file and a tiny PUT to find whether'
    Write-Host '     the 2,000,000 limit is on the stored file or the incoming body.'
    Write-Host '  E. large REPLACE: place a 3 MB binary, then delete-then-place a'
    Write-Host '     different 3 MB binary at the same path, and report what identity'
    Write-Host '     survives (ETag only; no read-back is possible).'
    Write-Host '  F. cleanup: delete every created path and verify it is gone.'
    Write-Host ''
    Write-Host 'Re-run with -ConfirmRemoteWrite to send it.'
    exit 0
}

# This probe deliberately does not prompt for a token. The shared resolver
# falls back to an interactive paste when the CLI session is stale, which hangs
# a non-interactive run instead of failing it. Take a token from
# -AccessTokenPath, or from a still-fresh rundot CLI session, and otherwise stop.
$token = $null
if (-not [string]::IsNullOrWhiteSpace($AccessTokenPath)) {
    if (-not (Test-Path -LiteralPath $AccessTokenPath -PathType Leaf)) {
        throw ("Token file not found: {0}" -f $AccessTokenPath)
    }
    $token = ([System.IO.File]::ReadAllText($AccessTokenPath)).Trim()
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'Token file is empty.' }
    Write-Host 'Read a token from -AccessTokenPath (value not shown).'
}
else {
    $session = $null
    try { $session = Get-RundotCliSession -RundotCliSessionPath $RundotCliSessionPath } catch { $session = $null }
    if ($null -eq $session) {
        throw ("No -AccessTokenPath given and no rundot CLI session at {0}. Run 'rundot login', or pass -AccessTokenPath with a fresh token." -f $RundotCliSessionPath)
    }
    if (-not (Test-RundotCliTokenFresh -AccessToken $session.AccessToken -ExpiresAtUnixTimeMs $session.ExpiresAtUnixTimeMs)) {
        throw 'The rundot CLI session token is expired or near expiry. Run ''rundot login'' to refresh it, or pass -AccessTokenPath with a fresh token.'
    }
    $token = [string]$session.AccessToken
    Write-Host 'Using the fresh rundot CLI session token (value not shown).'
}

$script:Headers = @{ Authorization = "Bearer $token"; Accept = '*/*' }

try {
    # -----------------------------------------------------------------
    # A. declaredSize sweep — what does upload-url accept?
    # -----------------------------------------------------------------
    Write-Host '=== A. declaredSize sweep (upload-url) ==='
    $sizes = @(0, 1, 104857600, 157286400, 209715200, 209715201)
    foreach ($size in $sizes) {
        $u = Invoke-UploadUrl -DeclaredSize $size
        $body = (Get-ResponseText $u)
        if ($body.Length -gt 200) { $body = $body.Substring(0, 200) + '...' }
        Write-Host ("  declaredSize {0,12} -> {1}  {2}" -f $size, $u.Status, $body)
        [void]$findings.Add("uploadUrl declared=$size status=$($u.Status) body=$body")
    }

    if ($CeilingScan) {
        # Pin the exact ceiling. 52,428,800 (50 MiB) is known-good and
        # 104,857,600 (100 MiB) is known-413, so binary-search the boundary.
        # Only upload-url is called, so no large body is ever transferred.
        Write-Host ''
        Write-Host '=== A2. ceiling binary search (upload-url only, no body) ==='
        $low = [int64]52428800     # known accepted
        $high = [int64]104857600   # known refused
        while (($high - $low) -gt 1) {
            $mid = [int64](($low + $high) / 2)
            $u = Invoke-UploadUrl -DeclaredSize $mid
            if ($u.Status -eq 200) { $low = $mid } else { $high = $mid }
            Write-Host ("  {0,12} -> {1}" -f $mid, $u.Status)
            [void]$findings.Add("ceilingProbe declared=$mid status=$($u.Status)")
        }
        Write-Host ("  largest accepted declaredSize: {0}" -f $low)
        Write-Host ("  smallest refused  declaredSize: {0}" -f $high)
        Write-Host ("  == 52,428,800 (50 MiB)? {0}" -f ($low -eq 52428800))
        [void]$findings.Add("ceiling accepted=$low refused=$high is50MiB=$($low -eq 52428800)")
    }

    # -----------------------------------------------------------------
    # B. body survival at the ceiling (50 MiB)
    # -----------------------------------------------------------------
    Write-Host ''
    Write-Host '=== B. body survival (50 MiB real upload) ==='
    # 52,428,800 = 50 MiB, the largest declaredSize upload-url accepts. Upload
    # the FULL body so this is a real transfer, not just a declaration.
    $bigSize = 52428800
    $bigBytes = New-Bytes -Count $bigSize
    $bigMd5 = Get-Md5Hex -Bytes $bigBytes
    $bigPath = $probeDir + '/big-50mib.bin'
    $big = Publish-Bytes -Bytes $bigBytes -StagingName ('ceiling-big-' + $runStamp + '.bin') -DestinationAbsolute ('/' + $bigPath)
    $bigPlain = [bool]([regex]::IsMatch([string]$big.etag, '^[0-9a-f]{32}$'))
    $bigEq = ([string]$big.etag -eq $bigMd5)
    Write-Host ("  upload-url   : {0}" -f $big.uploadUrl)
    Write-Host ("  presigned PUT: {0}   etag={1}" -f $big.putStatus, $big.etag)
    Write-Host ("  adopt        : {0}   recordedPath={1} size={2} mime={3}" -f $big.adoptStatus, $big.recordedPath, $big.recordedSize, $big.recordedMime)
    Write-Host ("  move         : {0}   to={1}" -f $big.moveStatus, $big.moveTo)
    Write-Host ("  local md5    : {0}" -f $bigMd5)
    Write-Host ("  etag plain 32-hex md5: {0}   etag == local md5: {1}" -f $bigPlain, $bigEq)
    if ($null -ne $big.PSObject.Properties['error']) { Write-Host ("  ERROR at step: {0}" -f $big.error) }
    [void]$findings.Add("50mib put=$($big.putStatus) etag=$($big.etag) plain=$bigPlain eq=$bigEq recordedSize=$($big.recordedSize)")

    # Does /files report the size, and can GET /file read it?
    $bigRow = Get-ListedRow -AbsolutePath ('/' + $bigPath)
    $bigRead = Get-FileBytes -AbsolutePath ('/' + $bigPath)
    Write-Host ("  /files row   : {0}" -f (($bigRow | ConvertTo-Json -Compress -Depth 4)))
    Write-Host ("  GET /file    : {0}" -f $(if ($null -eq $bigRead) { 'unreadable (413 or error)' } else { "$($bigRead.Length) bytes" }))
    [void]$findings.Add("100mb listedRow=$($bigRow | ConvertTo-Json -Compress -Depth 4) readable=$($null -ne $bigRead)")

    # -----------------------------------------------------------------
    # C. ETag shape by size — does it stay a plain MD5?
    # -----------------------------------------------------------------
    Write-Host ''
    Write-Host '=== C. ETag shape by size ==='
    foreach ($size in @(52428800, 104857600)) {
        $b = New-Bytes -Count $size
        $md5 = Get-Md5Hex -Bytes $b
        $nm = 'ceiling-sz' + $size + '-' + $runStamp + '.bin'
        $u = Invoke-UploadUrl -DeclaredSize $size
        if ($u.Status -ne 200) {
            Write-Host ("  {0,12} bytes -> upload-url {1} (skipped)" -f $size, $u.Status)
            [void]$findings.Add("etagShape $size -> upload-url $($u.Status)")
            continue
        }
        $uObj = (Get-ResponseText $u) | ConvertFrom-Json
        $p = Invoke-PresignedPut -UploadUrl ([string]$uObj.uploadUrl) -Bytes $b -ContentType 'application/octet-stream'
        $et = ([string]$p.Headers['ETag']).Trim([char]'"')
        $plain = [bool]([regex]::IsMatch($et, '^[0-9a-f]{32}$'))
        $eq = ($et -eq $md5)
        $a = Invoke-Adopt -UploadId ([string]$uObj.uploadId) -Name $nm
        if ($a.Status -eq 200) { [void]$created.Add((([string]((Get-ResponseText $a) | ConvertFrom-Json).path)).TrimStart('/')) }
        Write-Host ("  {0,12} bytes -> PUT {1}, etag={2}, plain-md5={3}, == local md5: {4}" -f $size, $p.Status, $et, $plain, $eq)
        [void]$findings.Add("etagShape $size -> $et plain=$plain eq=$eq")
    }

    # -----------------------------------------------------------------
    # D. Large TEXT publish — can a >2 MB file be stored as editable text?
    # -----------------------------------------------------------------
    Write-Host ''
    Write-Host '=== D. large text publish (upload as text/plain, no PUT /file) ==='
    # ~2.85 MB of ASCII text, matching docs/plaque-attack/STATUS.md's scale.
    $textTarget = 2850000
    $sb = New-Object System.Text.StringBuilder
    $line = 0
    while ($sb.Length -lt $textTarget) {
        [void]$sb.AppendLine(("line {0} : the quick brown fox jumps over the lazy dog" -f $line))
        $line++
    }
    $textValue = $sb.ToString()
    $textBytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($textValue)
    $textSha = Get-Sha256HexLocal -Bytes $textBytes
    $textPath = $probeDir + '/large-text.md'
    $textPublish = Publish-Bytes -Bytes $textBytes -StagingName ('ceiling-txt-' + $runStamp + '.txt') -DestinationAbsolute ('/' + $textPath) -ContentType 'text/plain'
    Write-Host ("  local text   : {0} bytes, sha256 {1}" -f $textBytes.Length, $textSha)
    Write-Host ("  upload-url   : {0}" -f $textPublish.uploadUrl)
    Write-Host ("  presigned PUT: {0}" -f $textPublish.putStatus)
    Write-Host ("  adopt        : {0}   recordedPath={1} size={2} mime={3}" -f $textPublish.adoptStatus, $textPublish.recordedPath, $textPublish.recordedSize, $textPublish.recordedMime)
    Write-Host ("  move         : {0}   to={1}" -f $textPublish.moveStatus, $textPublish.moveTo)
    $textRead = Get-FileBytes -AbsolutePath ('/' + $textPath)
    if ($null -eq $textRead) {
        Write-Host '  GET /file    : unreadable (413 or error)'
        [void]$findings.Add('largeText unreadable')
    }
    else {
        $readSha = Get-Sha256HexLocal -Bytes $textRead
        Write-Host ("  GET /file    : {0} bytes, sha256 {1}, exact={2}" -f $textRead.Length, $readSha, ($readSha -eq $textSha))
        [void]$findings.Add("largeText read=$($textRead.Length) exact=$($readSha -eq $textSha)")
    }
    $textRow = Get-ListedRow -AbsolutePath ('/' + $textPath)
    Write-Host ("  /files row   : {0}" -f (($textRow | ConvertTo-Json -Compress -Depth 4)))
    [void]$findings.Add("largeText row=$($textRow | ConvertTo-Json -Compress -Depth 4)")

    # And: does PUT /file still refuse it, as documented?
    $putBody = '{"content":"x"}'
    $putR = Invoke-ApiJson -Method 'PUT' -RelativePath "/api/projects/$ProjectId/file?path=$([System.Uri]::EscapeDataString('/' + $textPath))" -JsonBody $putBody
    Write-Host ("  PUT /file    : {0}  (tiny body against the large path; 413 means the refusal keys off the STORED size, not the new content)" -f $putR.Status)
    [void]$findings.Add("largeText smallPut=$($putR.Status)")

    # Walk text size against a tiny PUT. If the threshold is 2,000,000
    # characters of the STORED file, a small PUT is refused on a >2 MB path and
    # accepted below it. If the threshold is the incoming body, a tiny PUT is
    # always accepted. This decides whether a large text file is editable.
    Write-Host ''
    Write-Host '  text-size vs tiny PUT (which side is the 2,000,000 limit on?):'
    foreach ($size in @(1990000, 2000000, 2000001, 2500000)) {
        $sb2 = New-Object System.Text.StringBuilder
        $ln = 0
        while ($sb2.Length -lt $size) {
            [void]$sb2.AppendLine(("t{0} : the quick brown fox jumps over the lazy dog" -f $ln))
            $ln++
        }
        $tb = (New-Object System.Text.UTF8Encoding $false).GetBytes($sb2.ToString())
        $tp = $probeDir + '/text-' + $size + '.md'
        $pub = Publish-Bytes -Bytes $tb -StagingName ('ceiling-tx' + $size + '-' + $runStamp + '.txt') -DestinationAbsolute ('/' + $tp) -ContentType 'text/plain'
        $tiny = Invoke-ApiJson -Method 'PUT' -RelativePath "/api/projects/$ProjectId/file?path=$([System.Uri]::EscapeDataString('/' + $tp))" -JsonBody '{"content":"y"}'
        Write-Host ("    {0,9} bytes -> placed={1}  tiny PUT -> {2}" -f $tb.Length, ($pub.moveStatus -eq 200), $tiny.Status)
        [void]$findings.Add("textThreshold size=$($tb.Length) placed=$($pub.moveStatus -eq 200) tinyPut=$($tiny.Status)")
    }

    # -----------------------------------------------------------------
    # E. Large REPLACE — delete-then-place at 3 MB
    # -----------------------------------------------------------------
    Write-Host ''
    Write-Host '=== E. large binary replace (delete-then-place, 3 MB) ==='
    $replacePath = $probeDir + '/replace-target.bin'
    $firstBytes = New-Bytes -Count 3145728
    $first = Publish-Bytes -Bytes $firstBytes -StagingName ('ceiling-r1-' + $runStamp + '.bin') -DestinationAbsolute ('/' + $replacePath)
    $firstMd5 = Get-Md5Hex -Bytes $firstBytes
    Write-Host ("  place #1     : upload-url={0} put={1} adopt={2} move={3}" -f $first.uploadUrl, $first.putStatus, $first.adoptStatus, $first.moveStatus)
    Write-Host ("  place #1 etag: {0}  (local md5 {1}, eq={2})" -f $first.etag, $firstMd5, ($first.etag -eq $firstMd5))

    # Second bytes differ, so the replace is observable.
    $secondBytes = New-Bytes -Count 3145728
    for ($i = 0; $i -lt $secondBytes.Length; $i++) { $secondBytes[$i] = [byte](($secondBytes[$i] + 1) % 256) }
    $secondMd5 = Get-Md5Hex -Bytes $secondBytes

    $del = Invoke-Http -Method 'DELETE' -Uri "$StudioOrigin/api/projects/$ProjectId/file?path=$([System.Uri]::EscapeDataString('/' + $replacePath))" -Headers $script:Headers
    Write-Host ("  DELETE old   : {0}  body={1}" -f $del.Status, (Get-ResponseText $del))
    $listedAfterDelete = @(Get-ListedPaths | ForEach-Object { $_.TrimStart('/') })
    $absentAfterDelete = -not ($listedAfterDelete -contains $replacePath)
    Write-Host ("  absent after DELETE: {0}" -f $absentAfterDelete)

    $second = Publish-Bytes -Bytes $secondBytes -StagingName ('ceiling-r2-' + $runStamp + '.bin') -DestinationAbsolute ('/' + $replacePath)
    Write-Host ("  place #2     : upload-url={0} put={1} adopt={2} move={3}" -f $second.uploadUrl, $second.putStatus, $second.adoptStatus, $second.moveStatus)
    Write-Host ("  place #2 etag: {0}  (local md5 {1}, eq={2})" -f $second.etag, $secondMd5, ($second.etag -eq $secondMd5))
    $replaceRead = Get-FileBytes -AbsolutePath ('/' + $replacePath)
    Write-Host ("  GET /file    : {0}" -f $(if ($null -eq $replaceRead) { 'unreadable (413) — expected over the read limit' } else { "$($replaceRead.Length) bytes" }))
    [void]$findings.Add("replace del=$($del.Status) absent=$absentAfterDelete place2=$($second.moveStatus) etagEq=$($second.etag -eq $secondMd5) readable=$($null -ne $replaceRead)")

    Write-Host ''
    Write-Host 'FINDINGS:'
    foreach ($line in $findings) { Write-Host ("  " + $line) }
}
finally {
    foreach ($path in $created) {
        try {
            Invoke-Http -Method 'DELETE' -Uri "$StudioOrigin/api/projects/$ProjectId/file?path=$([System.Uri]::EscapeDataString('/' + $path))" -Headers $script:Headers | Out-Null
        }
        catch { }
    }
    $remaining = @()
    try {
        $remaining = @(Get-ListedPaths) | Where-Object { $_ -like "$probeDir/*" -or $_ -like "uploads/ceiling-*" }
    }
    catch { }
    if (@($remaining).Count -gt 0) {
        Write-Host ''
        Write-Host 'CLEANUP: remove these by hand in Studio:'
        $remaining | ForEach-Object { Write-Host ("  " + $_) }
    }
    else {
        Write-Host ''
        Write-Host 'Cleanup: nothing left behind.'
    }
    Write-Host ''
    Write-Host 'This report contains no tokens, auth paths, or file contents.'
}
