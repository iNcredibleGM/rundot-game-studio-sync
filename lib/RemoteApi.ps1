# GET-only RUN Game Studio HTTP helpers.
#
# Do not add Set-* or Remove-* remote functions. Do not add Studio write
# methods or upload helpers.

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

    $httpResponse = $request.GetResponse()

    try {
        $stream = $httpResponse.GetResponseStream()
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

    return $jsonText | ConvertFrom-Json
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
