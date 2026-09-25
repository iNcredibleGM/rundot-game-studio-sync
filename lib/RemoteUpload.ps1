# Documented Studio binary upload flow used only for utf8 text create staging.
#
# POST upload-url, presigned PUT (no Studio auth), POST upload-adopt.
# Do not add move or PUT /file here.
#
# Callers must load Paths.ps1, Hashing.ps1, RemoteApi.ps1, and RemoteWrite.ps1
# first (Escape-RemoteJsonStringContent).

function New-RemoteUploadUrlUri {
    param(
        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [string]$ProjectId
    )

    return "$StudioOrigin/api/projects/$ProjectId/upload-url"
}

function ConvertTo-RemoteUploadUrlJsonBody {
    param(
        [Parameter(Mandatory)]
        [int64]$DeclaredSize
    )

    if ($DeclaredSize -le 0) {
        throw [System.InvalidOperationException]::new(
            'declaredSize must be a positive integer for upload-url.'
        )
    }

    $json = '{"declaredSize":' + [string]$DeclaredSize + '}'
    return (New-Object System.Text.UTF8Encoding $false).GetBytes($json)
}

function Invoke-RemoteUploadUrl {
    param(
        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [int64]$DeclaredSize,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    $uri = New-RemoteUploadUrlUri -StudioOrigin $StudioOrigin -ProjectId $ProjectId
    $bodyBytes = ConvertTo-RemoteUploadUrlJsonBody -DeclaredSize $DeclaredSize

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

function Invoke-RemotePresignedObjectPut {
    param(
        [Parameter(Mandatory)]
        [string]$UploadUrl,

        [Parameter(Mandatory)]
        [byte[]]$Bytes,

        [string]$ContentType = 'text/plain'
    )

    $request = [System.Net.HttpWebRequest]::Create($UploadUrl)
    $request.Method = 'PUT'
    $request.ContentType = $ContentType
    $request.ContentLength = $Bytes.Length

    $requestStream = $request.GetRequestStream()
    try {
        $requestStream.Write($Bytes, 0, $Bytes.Length)
    }
    finally {
        $requestStream.Dispose()
    }

    $httpResponse = $null
    try {
        $httpResponse = $request.GetResponse()
    }
    catch [System.Net.WebException] {
        throw (Convert-WebExceptionToRemoteHttpException -Exception $_.Exception)
    }
    finally {
        if ($null -ne $httpResponse) {
            $httpResponse.Dispose()
        }
    }
}

function New-RemoteUploadAdoptUri {
    param(
        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [string]$ProjectId
    )

    return "$StudioOrigin/api/projects/$ProjectId/upload-adopt"
}

function ConvertTo-RemoteUploadAdoptJsonBody {
    param(
        [Parameter(Mandatory)]
        [string]$UploadId,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $escapedId = Escape-RemoteJsonStringContent -Text $UploadId
    $escapedName = Escape-RemoteJsonStringContent -Text $Name
    $json = '{"uploadId":"' + $escapedId + '","name":"' + $escapedName + '"}'
    return (New-Object System.Text.UTF8Encoding $false).GetBytes($json)
}

function Invoke-RemoteUploadAdopt {
    param(
        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [string]$UploadId,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    $uri = New-RemoteUploadAdoptUri -StudioOrigin $StudioOrigin -ProjectId $ProjectId
    $bodyBytes = ConvertTo-RemoteUploadAdoptJsonBody -UploadId $UploadId -Name $Name

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

function Get-RemoteUploadUrlResponseFields {
    param(
        [Parameter(Mandatory)]
        $Response
    )

    $uploadUrl = $null
    $uploadId = $null

    $urlProperty = $Response.PSObject.Properties['uploadUrl']
    if ($null -ne $urlProperty) {
        $uploadUrl = [string]$urlProperty.Value
    }

    $idProperty = $Response.PSObject.Properties['uploadId']
    if ($null -ne $idProperty) {
        $uploadId = [string]$idProperty.Value
    }

    if ([string]::IsNullOrWhiteSpace($uploadUrl)) {
        throw [System.InvalidOperationException]::new(
            'upload-url response did not include uploadUrl.'
        )
    }

    if ([string]::IsNullOrWhiteSpace($uploadId)) {
        throw [System.InvalidOperationException]::new(
            'upload-url response did not include uploadId.'
        )
    }

    return [pscustomobject]@{
        UploadUrl = $uploadUrl
        UploadId  = $uploadId
    }
}

function Get-RemoteUploadAdoptRecordedPath {
    param(
        [Parameter(Mandatory)]
        $Response
    )

    $pathProperty = $Response.PSObject.Properties['path']
    if ($null -eq $pathProperty -or [string]::IsNullOrWhiteSpace([string]$pathProperty.Value)) {
        throw [System.InvalidOperationException]::new(
            'upload-adopt response did not include path.'
        )
    }

    return [string]$pathProperty.Value
}
