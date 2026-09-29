# Read-limit / Range probe (#51 follow-up). NOT part of the product.
#
# Question: is Studio's 2,000,000-byte GET /file limit a property of the ROUTE,
# or only of a full-body read? Every prior "no alternate read route" test tried a
# different URL SHAPE (raw=1, download, asset, blob, signed-url) and got 404.
# Nobody tested a Range HEADER on the route that does work.
#
# If Range is honored, a >2 MB file can be read back in windows and hashed, and
# large-file verification stops being impossible.
#
# Safety: writes only under /sync-probe/read-limit-<runstamp>, creates its target
# through the upload flow, and deletes exactly what it created. Never prints the
# token. Use a DISPOSABLE project.
#
#   .\tools\ReadLimitProbe.ps1 -ProjectId <id>            # dry run, sends nothing
#   .\tools\ReadLimitProbe.ps1 -ProjectId <id> -ConfirmRemoteWrite

param(
    [Parameter(Mandatory)][string]$ProjectId,
    [string]$StudioOrigin = 'https://venus-studio-prod.series-ai.workers.dev',
    [string]$AuthPath = (Join-Path $env:APPDATA '.rundot\studio-export.auth.json'),
    [string]$RundotCliSessionPath = (Join-Path $env:APPDATA '.rundot\prod.session.json'),
    # A file holding a fresh bearer token. Preferred over the interactive
    # resolver, which BLOCKS on a Read-Host prompt when the CLI session is
    # expired (that is how two earlier scans hung).
    [string]$AccessTokenPath,
    [switch]$ConfirmRemoteWrite
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib\Paths.ps1')
. (Join-Path $repoRoot 'lib\Hashing.ps1')
. (Join-Path $repoRoot 'lib\Auth.ps1')

$limit = Get-SyncStudioMaxReadableFileSize
$runStamp = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$probeDir = 'sync-probe/read-limit-' + $runStamp
$target = $probeDir + '/oversize.bin'
$targetAbsolute = '/' + $target
$oversizeSize = 2200000   # comfortably over the 2 MB read limit
$created = New-Object 'System.Collections.Generic.List[string]'

function New-Bytes {
    param([int]$Count)
    $bytes = New-Object byte[] $Count
    for ($i = 0; $i -lt $Count; $i++) { $bytes[$i] = [byte](($i * 31 + 7) % 251) }
    return $bytes
}

function Get-BodyBytes {
    param($Response)
    if ($null -eq $Response) { return $null }
    if ($Response.TransportError) { return $null }
    $text = [string]$Response.BodyText
    if ([string]::IsNullOrEmpty($text)) { return [byte[]]@() }
    try {
        $obj = $text | ConvertFrom-Json
        if ($null -ne $obj.content) {
            if ([string]$obj.encoding -eq 'base64') { return [Convert]::FromBase64String([string]$obj.content) }
            return (New-Object System.Text.UTF8Encoding $false).GetBytes([string]$obj.content)
        }
    }
    catch { }
    return (New-Object System.Text.UTF8Encoding $false).GetBytes($text)
}

function Invoke-Http {
    # Never throws on a status; returns status + raw body bytes + selected headers.
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers,
        [byte[]]$BodyBytes,
        [string]$ContentType,
        [int64]$RangeFrom = -1,
        [int64]$RangeTo = -1,
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
    if (-not [string]::IsNullOrEmpty($ContentType)) { $request.ContentType = $ContentType }

    # HttpWebRequest refuses Range through the generic header collection
    # ("must be modified using the appropriate property"), so it is set on its
    # own typed property. A suffix range has no 'to'.
    if ($RangeFrom -ge 0) {
        if ($RangeTo -ge 0) {
            $request.AddRange([int64]$RangeFrom, [int64]$RangeTo)
        }
        else {
            $request.AddRange([int64]$RangeFrom)
        }
    }

    # Range is a TYPED property on HttpWebRequest: assigning it through the
    # generic Headers collection throws ArgumentException ("The 'Range' header
    # must be modified using the appropriate property or method").
    if ($RangeFrom -ge 0) {
        if ($RangeTo -ge 0) { $request.AddRange([int64]$RangeFrom, [int64]$RangeTo) }
        else { $request.AddRange([int64]$RangeFrom) }
    }

    # Range is a restricted header on HttpWebRequest: assigning it through the
    # generic Headers collection throws. It must go through AddRange().
    if ($RangeFrom -ge 0) {
        if ($RangeTo -ge 0) { $request.AddRange($RangeFrom, $RangeTo) }
        else { $request.AddRange($RangeFrom) }
    }

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
    foreach ($name in @('Content-Range', 'Accept-Ranges', 'Content-Length', 'ETag', 'Content-Type')) {
        if ($respHeaders.ContainsKey($name)) { $keep[$name] = $respHeaders[$name] }
    }

    return [pscustomobject]@{
        Status = $status; Bytes = $bytes; Headers = $keep; TransportError = $err
    }
}

function Get-ListedPaths {
    $list = Invoke-Http -Method 'GET' -Uri "$StudioOrigin/api/projects/$ProjectId/files" -Headers $script:Headers
    if ($null -eq $list.Bytes -or $list.Bytes.Length -eq 0) { return @() }
    $paths = @()
    $obj = [System.Text.Encoding]::UTF8.GetString($list.Bytes) | ConvertFrom-Json
    foreach ($entry in @($obj.files)) {
        if ($null -eq $entry) { continue }
        if ([string]$entry.type -ne 'file') { continue }
        $p = [string]$entry.path
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $paths += $p
    }
    return $paths
}

function ConvertTo-ProbeCanonical {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $trimmed = $Path -replace '^/+', ''
    if ([string]::IsNullOrWhiteSpace($trimmed)) { return '' }
    return ConvertTo-CanonicalSyncPath -Path $trimmed
}

function Invoke-ApiJson {
    param([string]$Method, [string]$RelativePath, [string]$JsonBody)
    $bytes = $null
    if (-not [string]::IsNullOrEmpty($JsonBody)) {
        $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($JsonBody)
    }
    $r = Invoke-Http -Method $Method -Uri "$StudioOrigin$RelativePath" -Headers $script:Headers -BodyBytes $bytes -ContentType 'application/json'
    if ($null -ne $r.Bytes -and $r.Bytes.Length -gt 0) {
        return ([System.Text.Encoding]::UTF8.GetString($r.Bytes) | ConvertFrom-Json)
    }
    return $null
}

# ---------------------------------------------------------------------------

Write-Host ''
Write-Host "Read-limit probe: $StudioOrigin"
Write-Host "  project : $ProjectId"
Write-Host "  target  : $target ($oversizeSize bytes)"
Write-Host "  limit   : $limit bytes"
Write-Host ''

if (-not $ConfirmRemoteWrite) {
    Write-Host 'DRY RUN. Would create the target through upload-url + presigned PUT +'
    Write-Host 'upload-adopt + POST /move, then run these reads:'
    Write-Host '  1. GET  /file?path=...                     (expect 413)'
    Write-Host '  2. GET  Range bytes=0-1023                 (does 206 come back?)'
    Write-Host '  3. GET  Range bytes=1999990-2000000        (straddles the limit)'
    Write-Host '  4. GET  Range bytes=2100000-2101023        (entirely ABOVE the limit)'
    Write-Host '  5. GET  Range bytes=1000000-               (suffix range)'
    Write-Host '  6. HEAD /file?path=...'
    Write-Host '  7. GET /files  (does it report the target size?)'
    Write-Host ''
    Write-Host 'Re-run with -ConfirmRemoteWrite to send it.'
    exit 0
}

$token = $null
if (-not [string]::IsNullOrWhiteSpace($AccessTokenPath)) {
    if (-not (Test-Path -LiteralPath $AccessTokenPath -PathType Leaf)) {
        throw ("Token file not found: {0}" -f $AccessTokenPath)
    }
    $token = ([System.IO.File]::ReadAllText($AccessTokenPath)).Trim()
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'Token file is empty.' }
}
else {
    $auth = Get-RundotAccessToken `
        -StudioOrigin $StudioOrigin -ProjectId $ProjectId `
        -AuthPath $AuthPath -RundotCliSessionPath $RundotCliSessionPath
    $token = [string]$auth.AccessToken
}

$script:Headers = @{ Authorization = "Bearer $token"; Accept = '*/*' }

$findings = New-Object 'System.Collections.Generic.List[string]'

try {
    # 1. Create the target through the documented flow.
    $bytes = New-Bytes -Count $oversizeSize
    $localSha = Convert-HashBytesToHex -Hash ([System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes))

    $minted = Invoke-ApiJson -Method 'POST' -RelativePath "/api/projects/$ProjectId/upload-url" -JsonBody ('{"declaredSize":' + $oversizeSize + '}')
    if ($null -eq $minted.uploadUrl) { throw 'upload-url returned no uploadUrl.' }

    $put = Invoke-Http -Method 'PUT' -Uri ([string]$minted.uploadUrl) -BodyBytes $bytes -ContentType 'application/octet-stream'
    if ($put.Status -notin @(200, 201)) { throw ("presigned PUT returned {0}." -f $put.Status) }

    $stagingName = 'read-limit-' + $runStamp + '.bin'
    $adopt = Invoke-ApiJson -Method 'POST' -RelativePath "/api/projects/$ProjectId/upload-adopt" -JsonBody ('{"uploadId":"' + [string]$minted.uploadId + '","name":"' + $stagingName + '"}')
    $stagingAbsolute = [string]$adopt.path
    if ([string]::IsNullOrEmpty($stagingAbsolute)) { throw 'upload-adopt returned no path.' }
    [void]$created.Add($stagingAbsolute.TrimStart('/'))

    $move = Invoke-ApiJson -Method 'POST' -RelativePath "/api/projects/$ProjectId/move" -JsonBody ('{"from":"' + $stagingAbsolute + '","to":"' + $targetAbsolute + '"}')
    $movedTo = [string]$move.data.to
    if ([string]::IsNullOrEmpty($movedTo)) { $movedTo = [string]$move.to }
    [void]$created.Add($target)
    Write-Host ("Created target ({0} bytes). Move reported: {1}" -f $oversizeSize, $movedTo)
    Write-Host ''

    $encoded = [System.Uri]::EscapeDataString($targetAbsolute)
    $fileUri = "$StudioOrigin/api/projects/$ProjectId/file?path=$encoded"

    # 2. Plain full read.
    $full = Invoke-Http -Method 'GET' -Uri $fileUri -Headers $script:Headers
    Write-Host ("[1] full GET                    -> {0}  ({1} bytes, Accept-Ranges={2})" -f $full.Status, ($full.Bytes | Measure-Object).Count, $full.Headers['Accept-Ranges'])
    [void]$findings.Add("full GET -> $($full.Status)")

    # 3. Range probes. The last one is entirely ABOVE the 2 MB mark: if it
    # succeeds, the limit is a full-body limit, not a route limit.
    $ranges = @(
        @{ Label = 'bytes=0-1023';            From = 0;       To = 1023 },
        @{ Label = 'bytes=1999990-2000000';   From = 1999990; To = 2000000 },
        @{ Label = 'bytes=2100000-2101023';   From = 2100000; To = 2101023 },
        @{ Label = 'bytes=1000000-';          From = 1000000; To = -1 }
    )
    $rangeWorked = $false
    foreach ($probe in $ranges) {
        $r = Invoke-Http -Method 'GET' -Uri $fileUri -Headers $script:Headers -RangeFrom $probe.From -RangeTo $probe.To
        $len = 0
        if ($null -ne $r.Bytes) { $len = $r.Bytes.Length }
        $cr = $r.Headers['Content-Range']
        Write-Host ("[2] Range {0,-22} -> {1}  ({2} bytes, Content-Range={3})" -f $probe.Label, $r.Status, $len, $cr)
        [void]$findings.Add("Range $($probe.Label) -> $($r.Status)")
        if ($r.Status -eq 206) { $rangeWorked = $true }
    }

    # 4. HEAD.
    $head = Invoke-Http -Method 'HEAD' -Uri $fileUri -Headers $script:Headers
    Write-Host ("[3] HEAD                        -> {0}" -f $head.Status)
    [void]$findings.Add("HEAD -> $($head.Status)")

    # 5. Does /files report the size? (normalize both sides; Studio prefixes '/')
    $listed = @(Get-ListedPaths | ForEach-Object { ConvertTo-ProbeCanonical -Path ([string]$_) })
    $found = $listed -contains (ConvertTo-ProbeCanonical -Path $target)
    Write-Host ("[4] GET /files lists target     -> {0}" -f $found)
    [void]$findings.Add("listed=$found")

    # 6. Read-boundary sweep. Pins the exact threshold, and discriminates a
    # RAW-byte limit from a BASE64 limit: 1,500,000 raw bytes encode to exactly
    # 2,000,000 base64 characters. If the limit counts encoded length, that
    # size is the last readable one; if it counts raw bytes, it reads fine.
    $boundaries = @(1500000, 1999999, 2000000, 2000001)
    $sweepPaths = New-Object 'System.Collections.Generic.List[string]'
    Write-Host ''
    Write-Host 'Read-boundary sweep:'
    foreach ($size in $boundaries) {
        $path = $probeDir + '/b-' + $size + '.bin'
        $abs = '/' + $path
        $b = New-Bytes -Count $size
        $m = Invoke-ApiJson -Method 'POST' -RelativePath "/api/projects/$ProjectId/upload-url" -JsonBody ('{"declaredSize":' + $size + '}')
        $null = Invoke-Http -Method 'PUT' -Uri ([string]$m.uploadUrl) -BodyBytes $b -ContentType 'application/octet-stream'
        $nm = 'read-limit-b' + $size + '-' + $runStamp + '.bin'
        $ad = Invoke-ApiJson -Method 'POST' -RelativePath "/api/projects/$ProjectId/upload-adopt" -JsonBody ('{"uploadId":"' + [string]$m.uploadId + '","name":"' + $nm + '"}')
        $st = [string]$ad.path
        [void]$created.Add($st.TrimStart('/'))
        $null = Invoke-ApiJson -Method 'POST' -RelativePath "/api/projects/$ProjectId/move" -JsonBody ('{"from":"' + $st + '","to":"' + $abs + '"}')
        [void]$created.Add($path)
        [void]$sweepPaths.Add($path)

        $enc = [System.Uri]::EscapeDataString($abs)
        $r = Invoke-Http -Method 'GET' -Uri "$StudioOrigin/api/projects/$ProjectId/file?path=$enc" -Headers $script:Headers
        $b64len = [int64]([math]::Ceiling($size / 3.0) * 4)
        Write-Host ("  {0,9} bytes (base64 {1,9}) -> GET {2}" -f $size, $b64len, $r.Status)
        [void]$findings.Add("read $size -> $($r.Status)")
    }

    # Does GET /files hide an oversize file? The listing is what every snapshot
    # and delete proof depends on, so a size-dependent blind spot would matter.
    $listedNow = @(Get-ListedPaths | ForEach-Object { ConvertTo-ProbeCanonical -Path $_ })
    Write-Host ''
    Write-Host 'Listed by GET /files?'
    foreach ($p in $sweepPaths) {
        $c = ConvertTo-ProbeCanonical -Path $p
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        $sz = ($c -replace '^.*b-', '') -replace '\.bin$', ''
        Write-Host ("  {0,9} bytes -> {1}" -f $sz, ($listedNow -contains $c))
        [void]$findings.Add("listed $c -> $($listedNow -contains $c)")
    }

    # 7. Identity signals for an oversize file. Removing the read-back wall
    # needs SOMETHING that binds the landed bytes to the local bytes without
    # GET /file. The presigned PUT's ETag is the only candidate seen so far, so
    # test whether it is a digest of the exact bytes, and enumerate what the
    # adopt, move, and /files responses actually expose.
    Write-Host ''
    Write-Host 'Identity signals (2,000,001 bytes):'
    $idPath = $probeDir + '/identity.bin'
    $idAbs = '/' + $idPath
    $idSize = 2000001
    $idBytes = New-Bytes -Count $idSize
    $idMd5 = Convert-HashBytesToHex -Hash ([System.Security.Cryptography.MD5]::Create().ComputeHash($idBytes))
    $idSha = Convert-HashBytesToHex -Hash ([System.Security.Cryptography.SHA256]::Create().ComputeHash($idBytes))

    $iu = Invoke-ApiJson -Method 'POST' -RelativePath "/api/projects/$ProjectId/upload-url" -JsonBody ('{"declaredSize":' + $idSize + '}')
    $iput = Invoke-Http -Method 'PUT' -Uri ([string]$iu.uploadUrl) -BodyBytes $idBytes -ContentType 'application/octet-stream'
    $iEtag = ([string]$iput.Headers['ETag']).Trim([char]'"')
    $etagEqMd5 = ($iEtag -eq $idMd5)
    Write-Host ("  local md5    : {0}" -f $idMd5)
    Write-Host ("  local sha256 : {0}" -f $idSha)
    Write-Host ("  PUT etag     : {0}   (== md5: {1})" -f $iEtag, $etagEqMd5)
    [void]$findings.Add("etag=$iEtag md5=$idMd5 etagEqMd5=$etagEqMd5")

    $inm = 'read-limit-id-' + $runStamp + '.bin'
    $adoptBody = (New-Object System.Text.UTF8Encoding $false).GetBytes('{"uploadId":"' + [string]$iu.uploadId + '","name":"' + $inm + '"}')
    $iAdopt = Invoke-Http -Method 'POST' -Uri "$StudioOrigin/api/projects/$ProjectId/upload-adopt" -Headers $script:Headers -BodyBytes $adoptBody -ContentType 'application/json'
    $iAdoptText = [System.Text.Encoding]::UTF8.GetString($iAdopt.Bytes)
    $iStaging = [string]($iAdoptText | ConvertFrom-Json).path
    [void]$created.Add($iStaging.TrimStart('/'))
    Write-Host ("  adopt body   : {0}" -f $iAdoptText)
    [void]$findings.Add("adopt=$iAdoptText")

    $moveBody = (New-Object System.Text.UTF8Encoding $false).GetBytes('{"from":"' + $iStaging + '","to":"' + $idAbs + '"}')
    $iMove = Invoke-Http -Method 'POST' -Uri "$StudioOrigin/api/projects/$ProjectId/move" -Headers $script:Headers -BodyBytes $moveBody -ContentType 'application/json'
    $iMoveText = [System.Text.Encoding]::UTF8.GetString($iMove.Bytes)
    [void]$created.Add($idPath)
    Write-Host ("  move body    : {0}" -f $iMoveText)
    [void]$findings.Add("move=$iMoveText")

    $iList = Invoke-Http -Method 'GET' -Uri "$StudioOrigin/api/projects/$ProjectId/files" -Headers $script:Headers
    $iListObj = [System.Text.Encoding]::UTF8.GetString($iList.Bytes) | ConvertFrom-Json
    foreach ($e in @($iListObj.files)) {
        $rawPath = [string]$e.path
        if ([string]::IsNullOrWhiteSpace($rawPath)) { continue }
        $eCanon = ConvertTo-ProbeCanonical -Path $rawPath
        if ($eCanon -eq (ConvertTo-ProbeCanonical -Path $idPath)) {
            $rowJson = ($e | ConvertTo-Json -Compress -Depth 5)
            Write-Host ("  /files row   : {0}" -f $rowJson)
            [void]$findings.Add("filesRow=$rowJson")
        }
    }

    # 8. Can the ETag carry identity at LARGE sizes? Multipart uploads change an
    # S3/R2 ETag to '<md5-of-parts>-<count>', which is NOT a content digest, so
    # the scheme is only sound while the ETag stays a plain 32-hex MD5.
    Write-Host ''
    Write-Host 'ETag shape by size (is it still a plain content MD5?):'
    foreach ($size in @(10485760, 52428800)) {
        $b = New-Bytes -Count $size
        $md5 = Convert-HashBytesToHex -Hash ([System.Security.Cryptography.MD5]::Create().ComputeHash($b))
        $m = Invoke-ApiJson -Method 'POST' -RelativePath "/api/projects/$ProjectId/upload-url" -JsonBody ('{"declaredSize":' + $size + '}')
        $p = Invoke-Http -Method 'PUT' -Uri ([string]$m.uploadUrl) -BodyBytes $b -ContentType 'application/octet-stream'
        $et = ([string]$p.Headers['ETag']).Trim([char]'"')
        $plain = [bool]([regex]::IsMatch($et, '^[0-9a-f]{32}$'))
        $eq = ($et -eq $md5)
        $nm = 'read-limit-sz' + $size + '-' + $runStamp + '.bin'
        $ad = Invoke-ApiJson -Method 'POST' -RelativePath "/api/projects/$ProjectId/upload-adopt" -JsonBody ('{"uploadId":"' + [string]$m.uploadId + '","name":"' + $nm + '"}')
        [void]$created.Add(([string]$ad.path).TrimStart('/'))
        Write-Host ("  {0,10} bytes -> PUT {1}, etag={2}, plain-md5-shape={3}, == local md5: {4}" -f $size, $p.Status, $et, $plain, $eq)
        [void]$findings.Add("etagShape $size -> $et plain=$plain eq=$eq")
    }

    # 9. Does the ETag survive POST /move? Use a SMALL file so it can still be
    # read back, and compare the read-back MD5 to the PRE-move ETag. If they
    # match, the move relocates the same bytes and the ETag is a trustworthy
    # post-move digest.
    Write-Host ''
    Write-Host 'Does the ETag survive POST /move?'
    $smPath = $probeDir + '/small.bin'
    $smAbs = '/' + $smPath
    $smBytes = New-Bytes -Count 1000
    $smMd5 = Convert-HashBytesToHex -Hash ([System.Security.Cryptography.MD5]::Create().ComputeHash($smBytes))
    $smU = Invoke-ApiJson -Method 'POST' -RelativePath "/api/projects/$ProjectId/upload-url" -JsonBody '{"declaredSize":1000}'
    $smPut = Invoke-Http -Method 'PUT' -Uri ([string]$smU.uploadUrl) -BodyBytes $smBytes -ContentType 'application/octet-stream'
    $smEtag = ([string]$smPut.Headers['ETag']).Trim([char]'"')
    $smNm = 'read-limit-sm-' + $runStamp + '.bin'
    $smAdopt = Invoke-ApiJson -Method 'POST' -RelativePath "/api/projects/$ProjectId/upload-adopt" -JsonBody ('{"uploadId":"' + [string]$smU.uploadId + '","name":"' + $smNm + '"}')
    $smStaging = [string]$smAdopt.path
    [void]$created.Add($smStaging.TrimStart('/'))
    $null = Invoke-ApiJson -Method 'POST' -RelativePath "/api/projects/$ProjectId/move" -JsonBody ('{"from":"' + $smStaging + '","to":"' + $smAbs + '"}')
    [void]$created.Add($smPath)
    $smRead = Invoke-Http -Method 'GET' -Uri "$StudioOrigin/api/projects/$ProjectId/file?path=$([System.Uri]::EscapeDataString($smAbs))" -Headers $script:Headers
    $smReadMd5 = '<unreadable>'
    if ($smRead.Status -eq 200 -and $null -ne $smRead.Bytes -and $smRead.Bytes.Length -gt 0) {
        $obj = [System.Text.Encoding]::UTF8.GetString($smRead.Bytes) | ConvertFrom-Json
        $decoded = [Convert]::FromBase64String([string]$obj.content)
        $smReadMd5 = Convert-HashBytesToHex -Hash ([System.Security.Cryptography.MD5]::Create().ComputeHash($decoded))
    }
    Write-Host ("  pre-move PUT etag : {0}" -f $smEtag)
    Write-Host ("  post-move read md5: {0}" -f $smReadMd5)
    Write-Host ("  local md5         : {0}" -f $smMd5)
    Write-Host ("  etag survives move: {0}" -f ($smEtag -eq $smReadMd5))
    [void]$findings.Add("moveEtag etag=$smEtag read=$smReadMd5 survives=$($smEtag -eq $smReadMd5)")

    Write-Host ''
    if ($rangeWorked) {
        Write-Host 'FINDING: Range IS honored. Windowed read + hash verification is possible.'
    }
    else {
        Write-Host 'FINDING: no Range support observed; the read limit stands as documented.'
    }
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
        $remaining = @(Get-ListedPaths) | Where-Object { $_ -like "$probeDir/*" -or $_ -like "uploads/read-limit-*" }
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
