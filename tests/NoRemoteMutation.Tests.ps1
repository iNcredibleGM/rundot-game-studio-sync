# Fail if product PowerShell grows undocumented Studio write helpers.
# Scan only game-studio-sync.ps1, game-studio-export.ps1, and lib/**/*.ps1 —
# never this file or markdown.
#
# PUT /file is allowed only in lib/RemoteWrite.ps1 (documented text overwrite).
# Presigned object PUT is allowed only in lib/RemoteUpload.ps1 (#40).
# upload-url and upload-adopt are allowed only in lib/RemoteUpload.ps1 (#40).
# POST move is allowed only in lib/RemoteMove.ps1 (#40).
# DELETE /file is allowed only in lib/RemoteDelete.ps1 (documented delete, #39).

$repoRoot = Split-Path $PSScriptRoot -Parent

$productFiles = @()

$exporterPath = Join-Path $repoRoot "game-studio-export.ps1"
Assert-True (Test-Path $exporterPath) "game-studio-export.ps1 must exist"

if (Test-Path $exporterPath) {
    $productFiles += Get-Item $exporterPath
}

$syncCliPath = Join-Path $repoRoot "game-studio-sync.ps1"
Assert-True (Test-Path $syncCliPath) "game-studio-sync.ps1 must exist"

if (Test-Path $syncCliPath) {
    $productFiles += Get-Item $syncCliPath
}

$libRoot = Join-Path $repoRoot "lib"
if (Test-Path $libRoot) {
    $productFiles += @(
        Get-ChildItem `
            -Path $libRoot `
            -Recurse `
            -Filter "*.ps1"
    )
}

$uploadPattern = '(?i)upload-url|upload-adopt'
$httpPutPattern = '(?i)(?:-Method\s+[''"]?PUT\b|(?:\.Method|\bMethod)\s*=\s*[''"]PUT[''"])'
$httpDeletePattern = '(?i)(?:-Method\s+[''"]?DELETE\b|(?:\.Method|\bMethod)\s*=\s*[''"]DELETE[''"])'
$httpMovePattern = '(?i)/move\b|projects/\{[^}]+\}/move'
$setFunctionPattern = '(?im)^\s*function\s+Set-'
$removeFunctionPattern = '(?im)^\s*function\s+Remove-'
# tools/StudioProbe.ps1 is the one opt-in, non-product probe allowed to perform
# a Studio write. Product code must never reach it: dot-sourcing it would defeat
# this ban without tripping any pattern above.
$probeReachabilityPattern = '(?i)StudioProbe|tools[\\/]StudioProbe'
$allowedUploadRelative = 'lib/RemoteUpload.ps1'
$allowedPutRelatives = @(
    'lib/RemoteWrite.ps1'
    'lib/RemoteUpload.ps1'
)
$allowedDeleteRelative = 'lib/RemoteDelete.ps1'
$allowedMoveRelative = 'lib/RemoteMove.ps1'

$violations = @()

foreach ($file in $productFiles) {
    $text = Get-Content -Path $file.FullName -Raw
    $relative = $file.FullName.Substring($repoRoot.Length).TrimStart("\", "/")
    $normalizedRelative = $relative -replace '\\', '/'

    if ($normalizedRelative -ne $allowedUploadRelative) {
        $lineMatches = [regex]::Matches($text, $uploadPattern)
        foreach ($match in $lineMatches) {
            $violations += "${relative}: Studio upload endpoint '$($match.Value)'"
        }
    }

    if ($allowedPutRelatives -notcontains $normalizedRelative) {
        $lineMatches = [regex]::Matches($text, $httpPutPattern)
        foreach ($match in $lineMatches) {
            $violations += "${relative}: HTTP PUT '$($match.Value)'"
        }
    }

    if ($normalizedRelative -ne $allowedDeleteRelative) {
        $lineMatches = [regex]::Matches($text, $httpDeletePattern)
        foreach ($match in $lineMatches) {
            $violations += "${relative}: HTTP DELETE '$($match.Value)'"
        }
    }

    if ($normalizedRelative -ne $allowedMoveRelative) {
        $lineMatches = [regex]::Matches($text, $httpMovePattern)
        foreach ($match in $lineMatches) {
            $violations += "${relative}: Studio move endpoint '$($match.Value)'"
        }
    }

    $lineMatches = [regex]::Matches($text, $probeReachabilityPattern)
    foreach ($match in $lineMatches) {
        $violations += "${relative}: reaches the non-product Studio probe '$($match.Value)'"
    }

    $isRemoteApi = $normalizedRelative -eq 'lib/RemoteApi.ps1'
    if ($isRemoteApi) {
        $lineMatches = [regex]::Matches($text, $setFunctionPattern)
        foreach ($match in $lineMatches) {
            $violations += "${relative}: remote Set-* function '$($match.Value.Trim())'"
        }

        $lineMatches = [regex]::Matches($text, $removeFunctionPattern)
        foreach ($match in $lineMatches) {
            $violations += "${relative}: remote Remove-* function '$($match.Value.Trim())'"
        }
    }
}

if ($violations.Count -gt 0) {
    Write-Host "Undocumented Studio mutation helpers are not allowed in product PowerShell:"
    foreach ($violation in $violations) {
        Write-Host "  $violation"
    }
}

Assert-Equal 0 $violations.Count "product PowerShell must expose only the documented Studio mutation surface"

# The delete library must stay narrow: no upload, no move, no probe reachability.
$deleteLibPath = Join-Path $repoRoot $allowedDeleteRelative
Assert-True (Test-Path $deleteLibPath) "lib/RemoteDelete.ps1 must exist"

$binaryPlaceLibPath = Join-Path $repoRoot 'lib/RemoteBinaryPlace.ps1'
Assert-True (Test-Path $binaryPlaceLibPath) 'lib/RemoteBinaryPlace.ps1 must exist'

if (Test-Path $binaryPlaceLibPath) {
    $binaryPlaceLibText = [System.IO.File]::ReadAllText($binaryPlaceLibPath)

    Assert-True `
        ($binaryPlaceLibText -notmatch $uploadPattern) `
        'lib/RemoteBinaryPlace.ps1 must not reference a Studio upload endpoint'
    Assert-True `
        ($binaryPlaceLibText -notmatch $httpPutPattern) `
        'lib/RemoteBinaryPlace.ps1 must not issue HTTP PUT'
    Assert-True `
        ($binaryPlaceLibText -notmatch $httpDeletePattern) `
        'lib/RemoteBinaryPlace.ps1 must not issue HTTP DELETE directly'
    Assert-True `
        ($binaryPlaceLibText -notmatch $httpMovePattern) `
        'lib/RemoteBinaryPlace.ps1 must not reference the Studio move endpoint'
}

if (Test-Path $deleteLibPath) {
    $deleteLibText = [System.IO.File]::ReadAllText($deleteLibPath)

    Assert-True `
        ($deleteLibText -notmatch $uploadPattern) `
        "lib/RemoteDelete.ps1 must not reference a Studio upload endpoint"
    Assert-True `
        ($deleteLibText -notmatch $httpMovePattern) `
        "lib/RemoteDelete.ps1 must not reference the Studio move endpoint"
    Assert-True `
        ($deleteLibText -notmatch $probeReachabilityPattern) `
        "lib/RemoteDelete.ps1 must not reach the non-product Studio probe"
}
