# Host-visible auth status and manual bearer paste.
# Auth.ps1 must be dot-sourced first for Get-TokenFromText.

function Write-RundotAuthStatusLine {
    param(
        [AllowEmptyString()]
        [string]$Text,

        [ValidateSet('Host', 'Warning')]
        [string]$Kind = 'Host'
    )

    if ($Kind -eq 'Warning') {
        Write-Warning $Text
        return
    }

    Write-Host $Text
}

function Read-RundotManualBearerToken {
    Write-Host ""
    Write-Host "No usable automatic Studio authentication was found."
    Write-Host ""
    Write-Host "You can paste a fresh Studio bearer token."
    Write-Host "The token will not be displayed."
    Write-Host ""

    $secureToken = Read-Host "Bearer token" -AsSecureString
    if ($null -eq $secureToken) {
        return $null
    }

    $plainText = [System.Net.NetworkCredential]::new("", $secureToken).Password
    if ([string]::IsNullOrWhiteSpace($plainText)) {
        return $null
    }

    $parsedToken = Get-TokenFromText $plainText
    if ($parsedToken) {
        return $parsedToken
    }

    return $plainText.Trim()
}
