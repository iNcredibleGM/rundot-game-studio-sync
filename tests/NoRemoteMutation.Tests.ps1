# Fail if product PowerShell grows Studio write helpers.
# Scan only game-studio-sync.ps1, game-studio-export.ps1, and lib/**/*.ps1 —
# never this file or markdown.

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
$setFunctionPattern = '(?im)^\s*function\s+Set-'
$removeFunctionPattern = '(?im)^\s*function\s+Remove-'

$violations = @()

foreach ($file in $productFiles) {
    $text = Get-Content -Path $file.FullName -Raw
    $relative = $file.FullName.Substring($repoRoot.Length).TrimStart("\", "/")

    $lineMatches = [regex]::Matches($text, $uploadPattern)
    foreach ($match in $lineMatches) {
        $violations += "${relative}: Studio upload endpoint '$($match.Value)'"
    }

    $lineMatches = [regex]::Matches($text, $httpPutPattern)
    foreach ($match in $lineMatches) {
        $violations += "${relative}: HTTP PUT '$($match.Value)'"
    }

    $lineMatches = [regex]::Matches($text, $httpDeletePattern)
    foreach ($match in $lineMatches) {
        $violations += "${relative}: HTTP DELETE '$($match.Value)'"
    }

    $isRemoteApi = $relative -replace "\\", "/" -eq "lib/RemoteApi.ps1"
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
    Write-Host "Studio mutation helpers are not allowed in product PowerShell:"
    foreach ($violation in $violations) {
        Write-Host "  $violation"
    }
}

Assert-Equal 0 $violations.Count "product PowerShell must not call Studio PUT/DELETE/upload APIs"
