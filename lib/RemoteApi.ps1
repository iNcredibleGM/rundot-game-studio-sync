# GET-only RUN Game Studio HTTP helpers.
#
# Do not add Set-* or Remove-* remote functions. Do not add Studio write
# methods or upload helpers.

function ConvertFrom-RemoteJson {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,

        [string]$What = "remote API"
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        throw [System.InvalidOperationException]::new(
            "Unexpected non-JSON from ${What}."
        )
    }

    $trimmed = $Text.TrimStart()

    if ($trimmed -match '(?i)^<!DOCTYPE\s+html|^<html\b') {
        throw [System.InvalidOperationException]::new(
            "Unexpected HTML from ${What} (login page?)."
        )
    }

    $first = $trimmed[0]
    if ($first -ne '{' -and $first -ne '[') {
        throw [System.InvalidOperationException]::new(
            "Unexpected non-JSON from ${What}."
        )
    }

    try {
        $parsed = $Text | ConvertFrom-Json
    }
    catch {
        throw [System.InvalidOperationException]::new(
            "Unexpected non-JSON from ${What}.",
            $_.Exception
        )
    }

    # Keep JSON arrays as one object. A bare `return $array` unrolls and
    # callers would see two pipeline items instead of a files payload.
    if ($parsed -is [System.Array]) {
        return ,$parsed
    }

    return $parsed
}


function New-RemoteHttpException {
    param(
        [Parameter(Mandatory)]
        [int]$StatusCode,

        [string]$Message,

        $InnerException = $null
    )

    if ([string]::IsNullOrEmpty($Message)) {
        $Message = "Remote GET failed with HTTP $StatusCode"
    }

    if ($null -ne $InnerException) {
        $exception = [System.InvalidOperationException]::new($Message, $InnerException)
    }
    else {
        $exception = [System.InvalidOperationException]::new($Message)
    }

    $exception.Data['HttpStatusCode'] = $StatusCode
    return $exception
}


function Get-RemoteHttpStatusCode {
    param($Exception)

    $current = $Exception
    while ($null -ne $current) {
        if ($null -ne $current.Data -and $current.Data.Contains('HttpStatusCode')) {
            return [int]$current.Data['HttpStatusCode']
        }

        if (
            $current -is [System.Net.WebException] -and
            $null -ne $current.Response
        ) {
            $httpResponse = [System.Net.HttpWebResponse]$current.Response
            return [int]$httpResponse.StatusCode
        }

        $current = $current.InnerException
    }

    return $null
}


function Test-RemoteNotFoundException {
    param($Exception)

    return (Get-RemoteHttpStatusCode -Exception $Exception) -eq 404
}


function Read-Utf8HttpResponseBody {
    param($HttpResponse)

    $stream = $HttpResponse.GetResponseStream()
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


function Convert-WebExceptionToRemoteHttpException {
    param(
        [Parameter(Mandatory)]
        [System.Net.WebException]$Exception
    )

    $statusCode = $null
    $response = $Exception.Response

    if ($null -ne $response) {
        try {
            $httpResponse = [System.Net.HttpWebResponse]$response
            $statusCode = [int]$httpResponse.StatusCode
            # Drain the error body so the connection can close. Do not parse
            # it as JSON — an HTML error page is not a file payload.
            try {
                [void](Read-Utf8HttpResponseBody -HttpResponse $httpResponse)
            }
            catch {
                # Classification uses status only.
            }
        }
        finally {
            $response.Dispose()
        }
    }

    if ($null -ne $statusCode) {
        return New-RemoteHttpException `
            -StatusCode $statusCode `
            -InnerException $Exception
    }

    return [System.InvalidOperationException]::new(
        "Remote GET failed.",
        $Exception
    )
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

    try {
        $httpResponse = $request.GetResponse()
    }
    catch [System.Net.WebException] {
        throw (Convert-WebExceptionToRemoteHttpException -Exception $_.Exception)
    }

    try {
        return Read-Utf8HttpResponseBody -HttpResponse $httpResponse
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

    return ConvertFrom-RemoteJson `
        -Text $jsonText `
        -What $Uri
}


function Get-RemoteProjectFileList {
    param(
        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    Invoke-Utf8JsonGet `
        -Uri "$StudioOrigin/api/projects/$ProjectId/files" `
        -Headers $Headers
}


function Get-RemoteProjectFile {
    param(
        [Parameter(Mandatory)]
        [string]$StudioOrigin,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    $encodedPath = [System.Uri]::EscapeDataString($Path)

    Invoke-Utf8JsonGet `
        -Uri "$StudioOrigin/api/projects/$ProjectId/file?path=$encodedPath" `
        -Headers $Headers
}
