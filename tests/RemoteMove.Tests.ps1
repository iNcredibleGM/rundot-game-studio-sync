# Remote move route contracts: URI shape and JSON bodies only.
#
# Do not require Pester. No network.

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "lib\Paths.ps1")
. (Join-Path $repoRoot "lib\Ignore.ps1")
. (Join-Path $repoRoot "lib\Hashing.ps1")
. (Join-Path $repoRoot "lib\Workspace.ps1")
. (Join-Path $repoRoot "lib\RemoteApi.ps1")
. (Join-Path $repoRoot "lib\Snapshot.ps1")
. (Join-Path $repoRoot "lib\RemoteWrite.ps1")
. (Join-Path $repoRoot "lib\RemoteMove.ps1")

$remoteMoveTestOrigin = 'https://example.test'
$remoteMoveTestProjectId = 'proj-move-test'

function Assert-RemoteMoveTestThrowsLike {
    param(
        [scriptblock]$Script,
        [string]$Pattern,
        [string]$Message
    )

    $threw = $false
    $text = $null

    try {
        & $Script | Out-Null
    }
    catch {
        $threw = $true
        $text = $_.Exception.Message
    }

    Assert-True $threw $Message
    if ($threw) {
        Assert-True ($text -match $Pattern) ("$Message (pattern '$Pattern', got '$text')")
    }
}

$moveUri = New-RemoteMoveUri `
    -StudioOrigin $remoteMoveTestOrigin `
    -ProjectId $remoteMoveTestProjectId
Assert-Equal `
    "$remoteMoveTestOrigin/api/projects/$remoteMoveTestProjectId/move" `
    $moveUri `
    "move URI must target the project move route"

$moveBody = ConvertTo-RemoteMoveJsonBody `
    -FromAbsolute '/uploads/a.txt' `
    -ToAbsolute '/src/a.txt'
$moveBodyText = (New-Object System.Text.UTF8Encoding $false).GetString($moveBody)
Assert-Equal '{"from":"/uploads/a.txt","to":"/src/a.txt"}' $moveBodyText `
    "move body must contain only from and to"

Assert-RemoteMoveTestThrowsLike {
    ConvertTo-RemoteMoveJsonBody -FromAbsolute 'relative' -ToAbsolute '/src/a.txt' | Out-Null
} "must be absolute" 'a relative from path must refuse'

Assert-RemoteMoveTestThrowsLike {
    ConvertTo-RemoteMoveJsonBody -FromAbsolute '/uploads/a.txt' -ToAbsolute 'relative' | Out-Null
} "must be absolute" 'a relative to path must refuse'
