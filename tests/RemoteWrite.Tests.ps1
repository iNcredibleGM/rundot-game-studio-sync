# Documented text PUT helper contracts.
# Network is stubbed. Do not print tokens.

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "lib\Paths.ps1")
. (Join-Path $repoRoot "lib\Hashing.ps1")
. (Join-Path $repoRoot "lib\Workspace.ps1")
. (Join-Path $repoRoot "lib\Snapshot.ps1")
. (Join-Path $repoRoot "lib\RemoteApi.ps1")
. (Join-Path $repoRoot "lib\RemoteWrite.ps1")


function Get-RemoteWriteTestDecodedContent {
    param([byte[]]$BodyBytes)

    $json = (New-Object System.Text.UTF8Encoding $false).GetString($BodyBytes)
    $parsed = $json | ConvertFrom-Json
    return [string]$parsed.content
}


function Get-RemoteWriteTestContentBytes {
    param([string]$Text)

    $utf8 = New-Object System.Text.UTF8Encoding $false
    return $utf8.GetBytes($Text)
}


# --------------------------------------------------------------------------
# Absolute path conversion
# --------------------------------------------------------------------------

Assert-Equal '/src/a.ts' `
    (ConvertTo-StudioAbsoluteApiPath -CanonicalPath 'src/a.ts') `
    "a canonical path must gain one leading slash"

Assert-Equal '/src/a.ts' `
    (ConvertTo-StudioAbsoluteApiPath -CanonicalPath '/src/a.ts') `
    "an already-absolute spelling must not become a double slash"

Assert-Throws {
    ConvertTo-StudioAbsoluteApiPath -CanonicalPath '../escaped.txt'
} "traversal must be refused before PUT"


# --------------------------------------------------------------------------
# JSON body: exact bytes through escape and decode
# --------------------------------------------------------------------------

$emptyBody = ConvertTo-RemoteTextPutJsonBody -Text ''
Assert-Equal '' (Get-RemoteWriteTestDecodedContent -BodyBytes $emptyBody) "empty content must round-trip"

$crlfText = "line one`r`nline two`r`n"
$crlfBody = ConvertTo-RemoteTextPutJsonBody -Text $crlfText
Assert-Equal $crlfText (Get-RemoteWriteTestDecodedContent -BodyBytes $crlfBody) "CRLF must be preserved in the JSON body"

$bomText = "$([char]0xFEFF)bom prefixed"
$bomBody = ConvertTo-RemoteTextPutJsonBody -Text $bomText
Assert-Equal $bomText (Get-RemoteWriteTestDecodedContent -BodyBytes $bomBody) "a UTF-8 BOM character must be preserved"

$emojiText = "emoji $([char]0xD83D)$([char]0xDE00) end"
$emojiBody = ConvertTo-RemoteTextPutJsonBody -Text $emojiText
Assert-Equal $emojiText (Get-RemoteWriteTestDecodedContent -BodyBytes $emojiBody) "emoji must round-trip"

$quoteText = 'say "hello" and \ backslash'
$quoteBody = ConvertTo-RemoteTextPutJsonBody -Text $quoteText
Assert-Equal $quoteText (Get-RemoteWriteTestDecodedContent -BodyBytes $quoteBody) "quotes and backslashes must escape correctly"

$noNewlineText = 'no trailing newline'
$noNewlineBody = ConvertTo-RemoteTextPutJsonBody -Text $noNewlineText
Assert-Equal $noNewlineText (Get-RemoteWriteTestDecodedContent -BodyBytes $noNewlineBody) "content without a trailing newline must round-trip"

$decodedCrlfBytes = Get-RemoteWriteTestContentBytes -Text (Get-RemoteWriteTestDecodedContent -BodyBytes $crlfBody)
$originalCrlfBytes = Get-RemoteWriteTestContentBytes -Text $crlfText
Assert-Equal $originalCrlfBytes $decodedCrlfBytes "decoded CRLF content must match the original bytes"


# --------------------------------------------------------------------------
# Character limit
# --------------------------------------------------------------------------

Assert-Throws {
    ConvertTo-RemoteTextPutJsonBody -Text ('x' * 2000001)
} "content longer than 2,000,000 characters must be refused before HTTP"

$limitBody = ConvertTo-RemoteTextPutJsonBody -Text ('x' * 2000000)
Assert-Equal 2000000 (Get-RemoteWriteTestDecodedContent -BodyBytes $limitBody).Length `
    "exactly 2,000,000 characters must be accepted"


# --------------------------------------------------------------------------
# PUT URI construction
# --------------------------------------------------------------------------

$origin = 'https://venus-studio-prod.series-ai.workers.dev'
$projectId = 'proj-test-1'
$absolutePath = '/foo bar/' + [char]0x00E9 + [char]0x6587 + [char]0x4EF6 + '.txt'
$encodedPath = [System.Uri]::EscapeDataString($absolutePath)

$uri = New-RemoteTextPutUri `
    -StudioOrigin $origin `
    -ProjectId $projectId `
    -AbsolutePath $absolutePath

Assert-Equal "$origin/api/projects/$projectId/file?path=$encodedPath" $uri `
    "the PUT URI must percent-encode the absolute path query value"

Assert-Throws {
    New-RemoteTextPutUri -StudioOrigin $origin -ProjectId $projectId -AbsolutePath 'src/a.ts'
} "New-RemoteTextPutUri must require a leading slash"


# --------------------------------------------------------------------------
# Echo verification
# --------------------------------------------------------------------------

$echoText = "verified echo $([Guid]::NewGuid().ToString('N'))"
$echoBytes = Get-RemoteWriteTestContentBytes -Text $echoText
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $expectedSha = [System.BitConverter]::ToString($sha.ComputeHash($echoBytes)).Replace('-', '').ToLowerInvariant()
}
finally {
    $sha.Dispose()
}

$response = [pscustomobject]@{
    path     = '/src/a.ts'
    encoding = 'utf8'
    content  = $echoText
    mimeType = 'text/plain'
    size     = $echoBytes.Length
}

Assert-RemoteTextPutEcho -Response $response -ExpectedSha256 $expectedSha

Assert-Throws {
    Assert-RemoteTextPutEcho -Response ([pscustomobject]@{
        encoding = 'base64'
        content  = 'abc'
    }) -ExpectedSha256 $expectedSha
} "a non-utf8 echo must be rejected"

Assert-Throws {
    Assert-RemoteTextPutEcho -Response ([pscustomobject]@{
        encoding = 'utf8'
        content  = 'different bytes'
    }) -ExpectedSha256 $expectedSha
} "a mismatched echo hash must be rejected"


# --------------------------------------------------------------------------
# Invoke-RemoteTextPut wiring (stubbed HTTP)
# --------------------------------------------------------------------------

$script:RemoteWriteCapturedUri = $null
$script:RemoteWriteCapturedMethod = $null
$script:RemoteWriteCapturedContentType = $null
$script:RemoteWriteCapturedBody = $null
$script:RemoteWriteCapturedHeaders = $null

function Invoke-RemoteTextPut {
    param(
        [string]$StudioOrigin,
        [string]$ProjectId,
        [string]$CanonicalPath,
        [string]$Text,
        [hashtable]$Headers
    )

    $absolutePath = ConvertTo-StudioAbsoluteApiPath -CanonicalPath $CanonicalPath
    $script:RemoteWriteCapturedUri = New-RemoteTextPutUri `
        -StudioOrigin $StudioOrigin `
        -ProjectId $ProjectId `
        -AbsolutePath $absolutePath
    $script:RemoteWriteCapturedMethod = 'PUT'
    $script:RemoteWriteCapturedContentType = 'application/json'
    $script:RemoteWriteCapturedBody = ConvertTo-RemoteTextPutJsonBody -Text $Text
    $script:RemoteWriteCapturedHeaders = $Headers

    return [pscustomobject]@{
        path     = $absolutePath
        encoding = 'utf8'
        content  = $Text
        mimeType = 'text/plain'
        size     = ([string]$Text).Length
    }
}

$putText = "put wiring $([Guid]::NewGuid().ToString('N'))"
$putHeaders = @{
    Authorization = 'Bearer test-token'
    Accept        = '*/*'
}

$putResponse = Invoke-RemoteTextPut `
    -StudioOrigin $origin `
    -ProjectId $projectId `
    -CanonicalPath 'src/a.ts' `
    -Text $putText `
    -Headers $putHeaders

Assert-Equal "$origin/api/projects/$projectId/file?path=%2Fsrc%2Fa.ts" $script:RemoteWriteCapturedUri `
    "Invoke-RemoteTextPut must target the encoded absolute /file route"
Assert-Equal 'PUT' $script:RemoteWriteCapturedMethod "Invoke-RemoteTextPut must use PUT"
Assert-Equal 'application/json' $script:RemoteWriteCapturedContentType `
    "Invoke-RemoteTextPut must send application/json"
Assert-Equal $putText (Get-RemoteWriteTestDecodedContent -BodyBytes $script:RemoteWriteCapturedBody) `
    "Invoke-RemoteTextPut must send the exact JSON body"
Assert-Equal 'Bearer test-token' $script:RemoteWriteCapturedHeaders.Authorization `
    "Invoke-RemoteTextPut must pass Authorization through"
Assert-Equal 'utf8' $putResponse.encoding "the stubbed PUT should return a utf8 echo payload"


# --------------------------------------------------------------------------
# One decode+hash implementation for every remote route
#
# The overwrite and delete paths must not each carry their own decoder: a
# 0-byte remote file aborted a real delete because one copy returned $null and
# the other returned a bare Byte. Both routes now share one implementation,
# and the shared one must be the only place that hashes decoded remote bytes.
# --------------------------------------------------------------------------

$snapshotSource = [System.IO.File]::ReadAllText((Join-Path $repoRoot "lib\Snapshot.ps1"))
$pushSource = [System.IO.File]::ReadAllText((Join-Path $repoRoot "lib\Push.ps1"))
$remoteWriteSource = [System.IO.File]::ReadAllText((Join-Path $repoRoot "lib\RemoteWrite.ps1"))

$decodeHashPattern = 'ComputeHash\s*\(\s*\$bytes\s*\)'

Assert-True `
    ($snapshotSource -match [regex]::Escape('function Get-RemoteFileContentSha256')) `
    "the shared decoded-payload hash must live in Snapshot.ps1 next to the decoder"
Assert-Equal `
    1 `
    ([regex]::Matches($snapshotSource, $decodeHashPattern)).Count `
    "the shared hash must be the one place that hashes decoded remote bytes"

Assert-True `
    ($pushSource -notmatch [regex]::Escape('function Get-RemoteFileContentSha256')) `
    "Push must not define its own decoded-payload hash"
Assert-True `
    ($pushSource -notmatch $decodeHashPattern) `
    "Push must delegate the decoded-payload hash rather than re-implement it"

Assert-True `
    ($remoteWriteSource -notmatch $decodeHashPattern) `
    "the PUT response hash must delegate the decoded-payload hash rather than re-implement it"

# The empty and single-byte payloads are the cases that broke. Both routes must
# agree on them, and agree with the canonical empty-string SHA-256.
foreach ($encoding in @('utf8', 'base64')) {
    $emptyPayload = ConvertFrom-RemoteFileContent -Response ([pscustomobject]@{
        encoding = $encoding
        content  = ''
    })
    Assert-True ($emptyPayload -is [byte[]]) "an empty $encoding payload must decode to byte[]"

    $emptyHash = Get-RemoteFileContentSha256 -Response ([pscustomobject]@{
        encoding = $encoding
        content  = ''
    })
    Assert-Equal `
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' `
        $emptyHash `
        "an empty $encoding payload must hash to the empty-string SHA-256"
}

# A one-byte payload is the other unrolling case: it must stay a byte[].
$oneByteHash = Get-RemoteFileContentSha256 -Response ([pscustomobject]@{
    encoding = 'utf8'
    content  = 'A'
})
Assert-Equal `
    '559aead08264d5795d3909718cdd05abd49572e84fe55590eef31a88a08fdffd' `
    $oneByteHash `
    "a one-byte payload must hash as bytes, not as a bare Byte"

# The PUT echo check and the delete pre-check must agree for the same bytes.
$agreeText = 'shared decoder agreement'
$putSha = Get-RemoteTextPutResponseSha256 -Response ([pscustomobject]@{
    encoding = 'utf8'
    content  = $agreeText
})
$sharedSha = Get-RemoteFileContentSha256 -Response ([pscustomobject]@{
    encoding = 'utf8'
    content  = $agreeText
})
Assert-Equal $sharedSha $putSha "the PUT echo hash and the shared hash must agree"
