# Documented Studio text overwrite: PUT /api/projects/{id}/file
#
# Overwrite-only. A missing path returns 404; this helper does not create files.
# Do not add delete, binary upload, or remote move routes here.
#
# Callers must load Paths.ps1, Hashing.ps1, RemoteApi.ps1, and Snapshot.ps1 first.

$script:RemoteTextPutMaxContentCharacters = 2000000


function ConvertTo-StudioAbsoluteApiPath {
    # Studio write routes require a leading /. Canonical sync paths do not.
    param(
        [Parameter(Mandatory)]
        [string]$CanonicalPath
    )

    $canonical = ConvertTo-CanonicalSyncPath -Path $CanonicalPath
    return '/' + $canonical
}


function Escape-RemoteJsonStringContent {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }

    $builder = New-Object System.Text.StringBuilder

    foreach ($ch in $Text.ToCharArray()) {
        $code = [int][char]$ch

        switch ($code) {
            0x22 { [void]$builder.Append('\"') }
            0x5C { [void]$builder.Append('\\') }
            0x08 { [void]$builder.Append('\b') }
            0x0C { [void]$builder.Append('\f') }
            0x0A { [void]$builder.Append('\n') }
            0x0D { [void]$builder.Append('\r') }
            0x09 { [void]$builder.Append('\t') }
            default {
                if ($code -lt 0x20) {
                    [void]$builder.Append(('\u{0:x4}' -f $code))
                }
                else {
                    [void]$builder.Append($ch)
                }
            }
        }
    }

    return $builder.ToString()
}


function ConvertTo-RemoteTextPutJsonBody {
    # Build {"content":"..."} without ConvertTo-Json so large bodies and PS 5.1
    # JavaScriptSerializer limits do not truncate the payload.
    param(
        [AllowNull()]
        [string]$Text
    )

    if ($null -eq $Text) {
        $Text = ''
    }

    if ($Text.Length -gt $script:RemoteTextPutMaxContentCharacters) {
        throw [System.InvalidOperationException]::new(
            'Text content exceeds the Studio editor limit of 2,000,000 characters.'
        )
    }

    $escaped = Escape-RemoteJsonStringContent -Text $Text
    $json = '{"content":"' + $escaped + '"}'
    return (New-Object System.Text.UTF8Encoding $false).GetBytes($json)
}


function New-RemoteTextPutUri {
    param(
        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [string]$AbsolutePath
    )

    if (-not $AbsolutePath.StartsWith('/')) {
        throw [System.InvalidOperationException]::new(
            "Remote text PUT path must be absolute and start with '/'."
        )
    }

    $encodedPath = [System.Uri]::EscapeDataString($AbsolutePath)
    return "$StudioOrigin/api/projects/$ProjectId/file?path=$encodedPath"
}


function Invoke-RemoteTextPut {
    param(
        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [string]$CanonicalPath,

        [AllowNull()]
        [string]$Text,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    $absolutePath = ConvertTo-StudioAbsoluteApiPath -CanonicalPath $CanonicalPath
    $uri = New-RemoteTextPutUri `
        -StudioOrigin $StudioOrigin `
        -ProjectId $ProjectId `
        -AbsolutePath $absolutePath
    $bodyBytes = ConvertTo-RemoteTextPutJsonBody -Text $Text

    $request = [System.Net.HttpWebRequest]::Create($uri)
    $request.Method = 'PUT'
    $request.ContentType = 'application/json'
    $request.ContentLength = $bodyBytes.Length

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

    $requestStream = $request.GetRequestStream()
    try {
        $requestStream.Write($bodyBytes, 0, $bodyBytes.Length)
    }
    finally {
        $requestStream.Dispose()
    }

    try {
        $httpResponse = $request.GetResponse()
    }
    catch [System.Net.WebException] {
        throw (Convert-WebExceptionToRemoteHttpException -Exception $_.Exception)
    }

    try {
        $bodyText = Read-Utf8HttpResponseBody -HttpResponse $httpResponse
        return ConvertFrom-RemoteJson -Text $bodyText -What $uri
    }
    finally {
        $httpResponse.Dispose()
    }
}


function Get-RemoteTextPutResponseSha256 {
    param(
        [Parameter(Mandatory)]
        $Response
    )

    $bytes = ConvertFrom-RemoteFileContent -Response $Response
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }

    return [System.BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
}


function Assert-RemoteTextPutEcho {
    param(
        [Parameter(Mandatory)]
        $Response,

        [Parameter(Mandatory)]
        [string]$ExpectedSha256
    )

    $encoding = $Response.PSObject.Properties['encoding']
    if ($null -eq $encoding -or [string]$encoding.Value -ne 'utf8') {
        throw [System.InvalidOperationException]::new(
            'Remote text PUT response must echo utf8 content.'
        )
    }

    $actualSha = Get-RemoteTextPutResponseSha256 -Response $Response
    if (-not [string]::Equals($actualSha, $ExpectedSha256, [System.StringComparison]::Ordinal)) {
        throw [System.InvalidOperationException]::new(
            'Remote text PUT echo does not match the expected content hash.'
        )
    }
}
