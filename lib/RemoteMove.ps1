# Documented Studio move: POST /api/projects/{id}/move
#
# Used for utf8 text create (#40) and binary place (#41). Rename publish stays out of
# scope. Do not add DELETE or upload routes here.
#
# Callers must load Paths.ps1, Hashing.ps1, RemoteApi.ps1, and RemoteWrite.ps1
# first (Escape-RemoteJsonStringContent).

function New-RemoteMoveUri {
    param(
        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [string]$ProjectId
    )

    return "$StudioOrigin/api/projects/$ProjectId/move"
}

function ConvertTo-RemoteMoveJsonBody {
    param(
        [Parameter(Mandatory)]
        [string]$FromAbsolute,

        [Parameter(Mandatory)]
        [string]$ToAbsolute
    )

    if (-not $FromAbsolute.StartsWith('/')) {
        throw [System.InvalidOperationException]::new(
            "Remote move 'from' path must be absolute and start with '/'."
        )
    }

    if (-not $ToAbsolute.StartsWith('/')) {
        throw [System.InvalidOperationException]::new(
            "Remote move 'to' path must be absolute and start with '/'."
        )
    }

    $escapedFrom = Escape-RemoteJsonStringContent -Text $FromAbsolute
    $escapedTo = Escape-RemoteJsonStringContent -Text $ToAbsolute
    $json = '{"from":"' + $escapedFrom + '","to":"' + $escapedTo + '"}'
    return (New-Object System.Text.UTF8Encoding $false).GetBytes($json)
}

function Invoke-RemoteMove {
    param(
        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [string]$FromAbsolute,

        [Parameter(Mandatory)]
        [string]$ToAbsolute,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    $uri = New-RemoteMoveUri -StudioOrigin $StudioOrigin -ProjectId $ProjectId
    $bodyBytes = ConvertTo-RemoteMoveJsonBody `
        -FromAbsolute $FromAbsolute `
        -ToAbsolute $ToAbsolute

    $request = [System.Net.HttpWebRequest]::Create($uri)
    $request.Method = 'POST'
    $request.ContentType = 'application/json'
    $request.ContentLength = $bodyBytes.Length

    Add-RemoteRequestHeaders -Request $request -Headers $Headers

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
