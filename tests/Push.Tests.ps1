# Push selection, plan gates, apply, and BASE update contracts.
#
# Do not require Pester. No network.
#
# SCOPE NOTE: tests/Run-Tests.ps1 dot-sources every *.Tests.ps1 into one
# scope, in filename order. Helpers here are prefixed New-PushTest* /
# Get-PushTest* / Assert-PushTest* so they never shadow a library function
# another test file needs.

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "lib\Paths.ps1")
. (Join-Path $repoRoot "lib\Ignore.ps1")
. (Join-Path $repoRoot "lib\Hashing.ps1")
. (Join-Path $repoRoot "lib\Workspace.ps1")
. (Join-Path $repoRoot "lib\Manifest.ps1")
. (Join-Path $repoRoot "lib\Snapshot.ps1")
. (Join-Path $repoRoot "lib\Classifier.ps1")
. (Join-Path $repoRoot "lib\Plan.ps1")
. (Join-Path $repoRoot "lib\Backup.ps1")
. (Join-Path $repoRoot "lib\Journal.ps1")
. (Join-Path $repoRoot "lib\RemoteApi.ps1")
. (Join-Path $repoRoot "lib\RemoteWrite.ps1")
. (Join-Path $repoRoot "lib\RemoteDelete.ps1")
. (Join-Path $repoRoot "lib\RemoteUpload.ps1")
. (Join-Path $repoRoot "lib\RemoteMove.ps1")
. (Join-Path $repoRoot "lib\RemoteTextCreate.ps1")
. (Join-Path $repoRoot "lib\Push.ps1")

$pushTestShaA = 'a' * 64
$pushTestShaB = 'b' * 64
$pushTestShaC = 'c' * 64
$pushTestShaD = 'd' * 64
$pushTestUtf8 = New-Object System.Text.UTF8Encoding $false
$pushTestProjectId = 'proj-push-test'
$pushTestOrigin = 'https://example.test'
$pushTestRemoteHashBefore = '1111111111111111111111111111111111111111111111111111111111111111'
$pushTestRemoteHashAfter = '2222222222222222222222222222222222222222222222222222222222222222'
$pushTestBaseCapturedAt = '2026-09-14T12:00:00.0000000Z'


function New-PushTestWorkspace {
    param([string]$Root)

    $workspace = Join-Path $Root ("push-ws-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $workspace | Out-Null
    Initialize-RundotSyncLayout -WorkspaceRoot $workspace
    return $workspace
}

function Write-PushTestBytes {
    param(
        [string]$LiteralPath,
        [byte[]]$Bytes
    )

    $parent = Split-Path -Parent $LiteralPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    [System.IO.File]::WriteAllBytes($LiteralPath, $Bytes)
}

function New-PushTestBaseEntry {
    param(
        [string]$Sha256,
        [int64]$Size = 0,
        [string]$Kind = 'utf8'
    )

    return [pscustomobject]@{
        sha256 = $Sha256
        size   = $Size
        kind   = $Kind
        lineEnding = 'lf'
        hasBom = $false
    }
}

function New-PushTestLocalEntry {
    param(
        [string]$Sha256,
        [int64]$Size = 0,
        [string]$Kind = 'utf8'
    )

    return [pscustomobject]@{
        Sha256            = $Sha256
        Size              = $Size
        LocalDetectedKind = $Kind
        LineEnding        = 'lf'
        HasBom            = $false
    }
}

function New-PushTestLocalEntryFromFile {
    param([string]$LiteralPath)

    $identity = Get-LocalFileIdentity -LiteralPath $LiteralPath
    return [pscustomobject]@{
        Sha256            = $identity.Sha256
        Size              = $identity.Size
        LocalDetectedKind = $identity.LocalDetectedKind
        LineEnding        = $identity.LineEnding
        HasBom            = $identity.HasBom
    }
}

function New-PushTestRemoteEntry {
    param(
        [string]$Sha256,
        [int64]$Size = 0,
        [string]$Kind = 'utf8',
        [string]$Encoding = 'utf8'
    )

    return [pscustomobject]@{
        Sha256            = $Sha256
        Size              = $Size
        LocalDetectedKind = $Kind
        RemoteKind        = $Kind
        Encoding          = $Encoding
    }
}

function New-PushTestResolution {
    param(
        $Files,
        [string]$CapturedAt = $pushTestBaseCapturedAt
    )

    return [pscustomobject]@{
        Base        = [pscustomobject]@{
            capturedAt = $CapturedAt
            files      = $Files
        }
        BasePresent = $true
        Untrusted   = $false
    }
}

function New-PushTestSnapshot {
    param(
        [string]$HashBefore = $pushTestRemoteHashBefore,
        [string]$HashAfter = $pushTestRemoteHashAfter
    )

    return [pscustomobject]@{
        RemoteManifestHashBefore = $HashBefore
        RemoteManifestHashAfter  = $HashAfter
    }
}

function New-PushTestPlanOperation {
    param(
        [string]$Path,
        [string]$Status = 'upload',
        [bool]$Applicable = $true,
        [string]$LocalSha256,
        [string]$RemoteSha256,
        [string]$ExpectedRemoteHash,
        [string]$Reason = $null,
        [string]$Kind = 'utf8',
        [bool]$KindChange = $false
    )

    return [pscustomobject]@{
        path               = $Path
        status             = $Status
        kind               = $Kind
        kinds              = [pscustomobject]@{
            base   = $Kind
            local  = $Kind
            remote = $Kind
        }
        applicable         = $Applicable
        remoteMutating     = ($Status -eq 'upload' -or $Status -eq 'deleteRemoteCandidate')
        reason             = $Reason
        warning            = $null
        ignored            = $false
        kindChange         = $KindChange
        baseSha256         = $ExpectedRemoteHash
        localSha256        = $LocalSha256
        remoteSha256       = $RemoteSha256
        expectedRemoteHash = $ExpectedRemoteHash
    }
}

function New-PushTestArtifact {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,

        [object[]]$Operations,

        [string]$ProjectId = $pushTestProjectId,

        [string]$LocalManifestHash,

        [string]$ExpiresAt,

        [string]$BaseCapturedAt = $pushTestBaseCapturedAt,

        [string]$RemoteHashBefore = $pushTestRemoteHashBefore,

        [string]$RemoteHashAfter = $pushTestRemoteHashAfter,

        [bool]$Untrusted = $false
    )

    if ([string]::IsNullOrEmpty($ExpiresAt)) {
        $ExpiresAt = [DateTime]::UtcNow.AddMinutes(20).ToString('o')
    }

    return [pscustomobject]@{
        schemaVersion            = 1
        toolVersion              = '0.2.0'
        planId                   = [string][Guid]::NewGuid()
        projectId                = $ProjectId
        localRootFingerprint     = Get-LocalRootFingerprint -WorkspaceRoot $WorkspaceRoot
        createdAt                = [DateTime]::UtcNow.ToString('o')
        expiresAt                = $ExpiresAt
        basePresent              = $true
        untrusted                = [bool]$Untrusted
        baseCapturedAt           = $BaseCapturedAt
        remoteManifestHashBefore = $RemoteHashBefore
        remoteManifestHashAfter  = $RemoteHashAfter
        localManifestHash        = $LocalManifestHash
        operations               = @($Operations)
    }
}

function Get-PushTestBytes {
    param([string]$LiteralPath)

    return [System.IO.File]::ReadAllBytes($LiteralPath)
}

function Assert-PushTestThrowsLike {
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

function New-PushTestTextOverwriteScenario {
    param(
        [string]$Root,
        [string]$Path = 'src/a.ts',
        [string]$Workspace = $null
    )

    if ([string]::IsNullOrEmpty($Workspace)) {
        $Workspace = New-PushTestWorkspace -Root $Root
    }

    $localFull = Join-Path $Workspace ($Path.Replace('/', '\'))
    $localBytes = $pushTestUtf8.GetBytes("local push content $Path`n")
    Write-PushTestBytes -LiteralPath $localFull -Bytes $localBytes

    $localEntry = New-PushTestLocalEntryFromFile -LiteralPath $localFull

    $remoteBytes = $pushTestUtf8.GetBytes("remote baseline $Path`n")
    $staging = Join-Path $Root ("remote-" + [Guid]::NewGuid().ToString('N') + '.txt')
    Write-PushTestBytes -LiteralPath $staging -Bytes $remoteBytes
    $remoteSha = (Get-LocalFileIdentity -LiteralPath $staging).Sha256

    $baseMap = @{ $Path = (New-PushTestBaseEntry -Sha256 $remoteSha) }
    $localMap = @{ $Path = $localEntry }
    $remoteMap = @{ $Path = (New-PushTestRemoteEntry -Sha256 $remoteSha) }

    $resolution = New-PushTestResolution -Files $baseMap
    $localHash = Get-SyncLocalManifestFingerprint -Local $localMap
    $snapshot = New-PushTestSnapshot

    $operation = New-PushTestPlanOperation `
        -Path $Path `
        -LocalSha256 $localEntry.Sha256 `
        -RemoteSha256 $remoteSha `
        -ExpectedRemoteHash $remoteSha

    $artifact = New-PushTestArtifact `
        -WorkspaceRoot $Workspace `
        -Operations @($operation) `
        -LocalManifestHash $localHash

    return [pscustomobject]@{
        Workspace  = $Workspace
        Path       = $Path
        LocalFull  = $localFull
        LocalEntry = $localEntry
        RemoteSha  = $remoteSha
        LocalMap   = $localMap
        RemoteMap  = $remoteMap
        Resolution = $resolution
        Snapshot   = $snapshot
        Artifact   = $artifact
        RemoteText = $pushTestUtf8.GetString($remoteBytes)
        LocalText  = $pushTestUtf8.GetString($localBytes)
    }
}

function Get-PushTestBaseEntrySha {
    param(
        $Base,
        [string]$Path
    )

    if ($Base.files -is [System.Collections.IDictionary]) {
        return [string]$Base.files[$Path].sha256
    }

    return [string]$Base.files.($Path).sha256
}

function New-PushTestDeleteScenario {
    # A BASE=A LOCAL=- REMOTE=A row: the remote file still matches the last
    # verified shared state, and LOCAL has no copy. This is the only shape a
    # delete may be applied to.
    param(
        [string]$Root,
        [string]$Path = 'src/gone.ts',
        [string]$Workspace = $null
    )

    if ([string]::IsNullOrEmpty($Workspace)) {
        $Workspace = New-PushTestWorkspace -Root $Root
    }

    $remoteBytes = $pushTestUtf8.GetBytes("remote delete baseline $Path`n")
    $staging = Join-Path $Root ("remote-del-" + [Guid]::NewGuid().ToString('N') + '.txt')
    Write-PushTestBytes -LiteralPath $staging -Bytes $remoteBytes
    $remoteSha = (Get-LocalFileIdentity -LiteralPath $staging).Sha256
    $remoteText = $pushTestUtf8.GetString($remoteBytes)

    $baseMap = @{ $Path = (New-PushTestBaseEntry -Sha256 $remoteSha) }
    $localMap = @{}
    $remoteMap = @{ $Path = (New-PushTestRemoteEntry -Sha256 $remoteSha) }

    Save-BaseManifest `
        -WorkspaceRoot $Workspace `
        -ProjectId $pushTestProjectId `
        -Files $baseMap

    $resolution = New-PushTestResolution -Files $baseMap
    $localHash = Get-SyncLocalManifestFingerprint -Local $localMap
    $snapshot = New-PushTestSnapshot

    $operation = New-PushTestPlanOperation `
        -Path $Path `
        -Status 'deleteRemoteCandidate' `
        -Applicable $true `
        -LocalSha256 $null `
        -RemoteSha256 $remoteSha `
        -ExpectedRemoteHash $remoteSha

    $artifact = New-PushTestArtifact `
        -WorkspaceRoot $Workspace `
        -Operations @($operation) `
        -LocalManifestHash $localHash

    # The remote file is still present until the DELETE is sent, so the list
    # call reports it. The callbacks read a shared state object rather than a
    # bare local: a scriptblock invoked from another scope would not resolve
    # the function's locals.
    $script:PushTestDeleteState = [pscustomobject]@{
        Deleted    = $false
        RemoteText = $remoteText
        Path       = $Path
        Size       = $remoteBytes.Length
    }

    $getRemote = {
        param($Origin, $Id, $ApiPath, $Hdr)
        return [pscustomobject]@{
            encoding = 'utf8'
            content  = [string]$script:PushTestDeleteState.RemoteText
        }
    }

    $deleteRemote = {
        param($Origin, $Id, $Canonical, $Hdr)
        $script:PushTestDeleteCalls++
        $script:PushTestDeleteState.Deleted = $true
        return [pscustomobject]@{ success = $true; data = [pscustomobject]@{ deleted = ('/' + $Canonical) } }
    }

    $listRemote = {
        param($Origin, $Id, $Hdr)
        if ($script:PushTestDeleteState.Deleted) {
            return [pscustomobject]@{ files = @() }
        }

        return [pscustomobject]@{
            files = @(
                [pscustomobject]@{
                    path = ('/' + [string]$script:PushTestDeleteState.Path)
                    type = 'file'
                    size = $script:PushTestDeleteState.Size
                }
            )
        }
    }

    # A reserved-path variant: the plan row exists and is applicable, but the
    # engine must refuse it against the route rules. '.rundot' is reserved but
    # is not in the default ignore set, so the classifier still calls it a
    # delete candidate rather than an ignored path.
    $reservedPath = '.rundot/config'
    $reservedBaseMap = @{ $reservedPath = (New-PushTestBaseEntry -Sha256 $remoteSha) }
    $reservedRemoteMap = @{ $reservedPath = (New-PushTestRemoteEntry -Sha256 $remoteSha) }
    $reservedArtifact = New-PushTestArtifact `
        -WorkspaceRoot $Workspace `
        -Operations @(
            (New-PushTestPlanOperation `
                -Path $reservedPath `
                -Status 'deleteRemoteCandidate' `
                -Applicable $true `
                -LocalSha256 $null `
                -RemoteSha256 $remoteSha `
                -ExpectedRemoteHash $remoteSha)
        ) `
        -LocalManifestHash (Get-SyncLocalManifestFingerprint -Local @{})

    return [pscustomobject]@{
        Workspace           = $Workspace
        Path                = $Path
        RemoteSha           = $remoteSha
        RemoteText          = $remoteText
        BaseMap             = $baseMap
        LocalMap            = $localMap
        RemoteMap           = $remoteMap
        ReappearedLocalMap  = @{ $Path = (New-PushTestLocalEntry -Sha256 $pushTestShaB) }
        Resolution          = $resolution
        Snapshot            = $snapshot
        Artifact            = $artifact
        GetRemoteFile       = $getRemote
        DeleteRemoteFile    = $deleteRemote
        GetRemoteFileList   = $listRemote
        ReservedBaseMap     = $reservedBaseMap
        ReservedLocalMap    = @{}
        ReservedRemoteMap   = $reservedRemoteMap
        ReservedArtifact    = $reservedArtifact
    }
}


$pushTestRoot = Join-Path $env:TEMP ("rundot-push-tests-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $pushTestRoot | Out-Null

try {
    # --------------------------------------------------------------------------
    # Plan artifact gates (whole-run refuse)
    # --------------------------------------------------------------------------

    $gateWorkspace = New-PushTestWorkspace -Root $pushTestRoot
    $gateLocalMap = @{ 'src/a.ts' = (New-PushTestLocalEntry -Sha256 $pushTestShaB) }
    $gateRemoteMap = @{ 'src/a.ts' = (New-PushTestRemoteEntry -Sha256 $pushTestShaA) }
    $gateBaseMap = @{ 'src/a.ts' = (New-PushTestBaseEntry -Sha256 $pushTestShaA) }
    $gateResolution = New-PushTestResolution -Files $gateBaseMap
    $gateSnapshot = New-PushTestSnapshot
    $gateLocalHash = Get-SyncLocalManifestFingerprint -Local $gateLocalMap
    $gateOperation = New-PushTestPlanOperation `
        -Path 'src/a.ts' `
        -LocalSha256 $pushTestShaB `
        -RemoteSha256 $pushTestShaA `
        -ExpectedRemoteHash $pushTestShaA
    $gateArtifact = New-PushTestArtifact `
        -WorkspaceRoot $gateWorkspace `
        -Operations @($gateOperation) `
        -LocalManifestHash $gateLocalHash

    $gateParams = @{
        Artifact      = $gateArtifact
        ProjectId     = $pushTestProjectId
        WorkspaceRoot = $gateWorkspace
        Resolution    = $gateResolution
        Local         = $gateLocalMap
        Snapshot      = $gateSnapshot
    }

    Assert-PushTestThrowsLike {
        $missing = $gateParams.Clone()
        $missing.Artifact = $null
        Assert-RundotSyncPushPlanArtifact @missing
    } 'No plan artifact found' 'a missing artifact must refuse'

    $gateParams.Artifact = $gateArtifact
    $gateParams.ProjectId = 'other-project'
    Assert-PushTestThrowsLike {
        Assert-RundotSyncPushPlanArtifact @gateParams
    } 'plan projectId does not match' 'a projectId mismatch must refuse'
    $gateParams.ProjectId = $pushTestProjectId

    $gateParams.Artifact.expiresAt = [DateTime]::UtcNow.AddMinutes(-5).ToString('o')
    Assert-PushTestThrowsLike {
        Assert-RundotSyncPushPlanArtifact @gateParams
    } 'plan has expired' 'an expired plan must refuse'
    $gateParams.Artifact.expiresAt = [DateTime]::UtcNow.AddMinutes(20).ToString('o')

    $gateParams.Artifact.baseCapturedAt = '2020-01-01T00:00:00.0000000Z'
    Assert-PushTestThrowsLike {
        Assert-RundotSyncPushPlanArtifact @gateParams
    } 'BASE changed since this plan was created' 'a BASE capturedAt mismatch must refuse'
    $gateParams.Artifact.baseCapturedAt = $pushTestBaseCapturedAt

    $gateParams.Artifact.localManifestHash = ('d' * 64)
    Assert-PushTestThrowsLike {
        Assert-RundotSyncPushPlanArtifact @gateParams
    } 'LOCAL changed since this plan was created' 'a localManifestHash mismatch must refuse'
    $gateParams.Artifact.localManifestHash = $gateLocalHash

    $gateParams.Artifact.remoteManifestHashBefore = ('e' * 64)
    Assert-PushTestThrowsLike {
        Assert-RundotSyncPushPlanArtifact @gateParams
    } 'REMOTE changed since this plan was created' 'a remote hash mismatch must refuse'
    $gateParams.Artifact.remoteManifestHashBefore = $pushTestRemoteHashBefore

    $gateParams.Artifact.untrusted = $true
    Assert-PushTestThrowsLike {
        Assert-RundotSyncPushPlanArtifact @gateParams
    } 'built without a verified BASE' 'an untrusted plan must refuse'
    $gateParams.Artifact.untrusted = $false


    # --------------------------------------------------------------------------
    # Selection: row refusals and one publishable overwrite
    # --------------------------------------------------------------------------

    $selectBase = @{
        'src/text.ts'     = (New-PushTestBaseEntry -Sha256 $pushTestShaA)
        'public/x.png'    = (New-PushTestBaseEntry -Sha256 $pushTestShaA -Kind 'binary')
        'src/conflict.ts' = (New-PushTestBaseEntry -Sha256 $pushTestShaA)
        'src/kind.ts'     = (New-PushTestBaseEntry -Sha256 $pushTestShaA)
    }
    $selectLocal = @{
        'src/text.ts'     = (New-PushTestLocalEntry -Sha256 $pushTestShaB)
        'public/x.png'    = (New-PushTestLocalEntry -Sha256 $pushTestShaB -Kind 'binary')
        'src/new.ts'      = (New-PushTestLocalEntry -Sha256 $pushTestShaC)
        'src/conflict.ts' = (New-PushTestLocalEntry -Sha256 $pushTestShaB)
        'src/kind.ts'     = (New-PushTestLocalEntry -Sha256 $pushTestShaB -Kind 'binary')
    }
    $selectRemote = @{
        'src/text.ts'     = (New-PushTestRemoteEntry -Sha256 $pushTestShaA)
        'public/x.png'    = (New-PushTestRemoteEntry -Sha256 $pushTestShaA -Kind 'binary' -Encoding 'base64')
        'src/conflict.ts' = (New-PushTestRemoteEntry -Sha256 $pushTestShaC)
        'src/kind.ts'     = (New-PushTestRemoteEntry -Sha256 $pushTestShaA)
    }
    $selectArtifact = New-PushTestArtifact `
        -WorkspaceRoot $gateWorkspace `
        -LocalManifestHash (Get-SyncLocalManifestFingerprint -Local $selectLocal) `
        -Operations @(
            (New-PushTestPlanOperation -Path 'src/text.ts' -LocalSha256 $pushTestShaB -RemoteSha256 $pushTestShaA -ExpectedRemoteHash $pushTestShaA),
            (New-PushTestPlanOperation -Path 'public/x.png' -LocalSha256 $pushTestShaB -RemoteSha256 $pushTestShaA -ExpectedRemoteHash $pushTestShaA -Kind 'binary' -Applicable $false -Reason 'binary blocked'),
            (New-PushTestPlanOperation -Path 'src/new.ts' -LocalSha256 $pushTestShaC -RemoteSha256 $null -ExpectedRemoteHash $null -Applicable $false -Reason $script:SyncPlanTextCreateReason),
            (New-PushTestPlanOperation -Path 'src/conflict.ts' -Status 'conflict' -Applicable $false -LocalSha256 $pushTestShaB -RemoteSha256 $pushTestShaC -ExpectedRemoteHash $pushTestShaA),
            (New-PushTestPlanOperation -Path 'src/kind.ts' -Status 'conflict' -Applicable $false -KindChange $true -LocalSha256 $pushTestShaB -RemoteSha256 $pushTestShaA -ExpectedRemoteHash $pushTestShaA -Kind 'binary')
        )

    $selection = Get-SyncPushSelection `
        -Artifact $selectArtifact `
        -Base $selectBase `
        -Local $selectLocal `
        -Remote $selectRemote

    Assert-Equal 1 $selection.Actions.Count 'only one text overwrite may be selected'
    Assert-Equal 'src/text.ts' $selection.Actions[0].Path 'the text overwrite path must be selected'
    Assert-Equal 4 $selection.Excluded.Count 'every non-applicable plan row must be excluded with a reason'

    $createOnlyLocal = @{
        'src/new.ts' = (New-PushTestLocalEntry -Sha256 $pushTestShaC)
    }
    $createOnlyBase = @{
        'src/text.ts' = (New-PushTestBaseEntry -Sha256 $pushTestShaA)
    }
    $createOnlyArtifact = New-PushTestArtifact `
        -WorkspaceRoot $gateWorkspace `
        -LocalManifestHash (Get-SyncLocalManifestFingerprint -Local $createOnlyLocal) `
        -Operations @(
            (New-PushTestPlanOperation `
                -Path 'src/new.ts' `
                -LocalSha256 $pushTestShaC `
                -RemoteSha256 $null `
                -ExpectedRemoteHash $null `
                -Applicable $true)
        )
    $createSelection = Get-SyncPushSelection `
        -Artifact $createOnlyArtifact `
        -Base $createOnlyBase `
        -Local $createOnlyLocal `
        -Remote @{}

    Assert-Equal 0 $createSelection.Actions.Count 'a text create must not land in overwrite actions'
    Assert-Equal 1 $createSelection.CreateActions.Count 'a text create must be selected for create'
    Assert-Equal 'src/new.ts' $createSelection.CreateActions[0].Path 'the create path must be selected'

    $conflictExcluded = @($selection.Excluded | Where-Object { [string]$_.Path -eq 'src/conflict.ts' })
    Assert-Equal 1 $conflictExcluded.Count 'a conflict row must appear in SKIPPED'
    Assert-Equal 'conflict' ([string]$conflictExcluded[0].Status) 'a conflict row must keep its status'
    Assert-Equal $script:SyncConflictReason ([string]$conflictExcluded[0].Reason) 'a conflict row must explain why Push skips it'

    $kindExcluded = @($selection.Excluded | Where-Object { [string]$_.Path -eq 'src/kind.ts' })
    Assert-Equal 1 $kindExcluded.Count 'a kind-change row must appear in SKIPPED'
    Assert-Equal $true $kindExcluded[0].KindChange 'a kind-change row must be flagged'
    Assert-Equal $script:SyncKindChangeReason ([string]$kindExcluded[0].Reason) 'a kind-change row must name the kind change'

    Assert-PushTestThrowsLike {
        $conflictLocal = @{
            'src/text.ts' = (New-PushTestLocalEntry -Sha256 $pushTestShaB)
        }
        $conflictRemote = @{
            'src/text.ts' = (New-PushTestRemoteEntry -Sha256 $pushTestShaC)
        }
        $conflictArtifact = New-PushTestArtifact `
            -WorkspaceRoot $gateWorkspace `
            -LocalManifestHash (Get-SyncLocalManifestFingerprint -Local $conflictLocal) `
            -Operations @(
                (New-PushTestPlanOperation -Path 'src/text.ts' -LocalSha256 $pushTestShaB -RemoteSha256 $pushTestShaA -ExpectedRemoteHash $pushTestShaA)
            )
        Get-SyncPushSelection `
            -Artifact $conflictArtifact `
            -Base $selectBase `
            -Local $conflictLocal `
            -Remote $conflictRemote | Out-Null
    } 'no longer an upload candidate' 'a live conflict on an applicable row must refuse the whole run'

    Assert-PushTestThrowsLike {
        $kindLocal = @{
            'src/text.ts' = (New-PushTestLocalEntry -Sha256 $pushTestShaB -Kind 'binary')
        }
        $kindRemote = @{
            'src/text.ts' = (New-PushTestRemoteEntry -Sha256 $pushTestShaA)
        }
        $kindArtifact = New-PushTestArtifact `
            -WorkspaceRoot $gateWorkspace `
            -LocalManifestHash (Get-SyncLocalManifestFingerprint -Local $kindLocal) `
            -Operations @(
                (New-PushTestPlanOperation -Path 'src/text.ts' -LocalSha256 $pushTestShaB -RemoteSha256 $pushTestShaA -ExpectedRemoteHash $pushTestShaA)
            )
        Get-SyncPushSelection `
            -Artifact $kindArtifact `
            -Base $selectBase `
            -Local $kindLocal `
            -Remote $kindRemote | Out-Null
    } 'no longer an upload candidate' 'a live kind change on an applicable row must refuse the whole run'


    # --------------------------------------------------------------------------
    # Confirmation orchestration
    # --------------------------------------------------------------------------

    $headers = @{
        Authorization = 'Bearer test-token-not-for-output'
        Accept        = '*/*'
    }

    $confirmScenario = New-PushTestTextOverwriteScenario -Root $pushTestRoot

    $getRemote = {
        param($Origin, $Id, $ApiPath, $Hdr)
        $script:PushTestGetCalls++
        return [pscustomobject]@{
            encoding = 'utf8'
            content  = $confirmScenario.RemoteText
        }
    }

    $putRemote = {
        param($Origin, $Id, $Canonical, $BodyText, $Hdr)
        $script:PushTestPutCalls++
        return [pscustomobject]@{
            encoding = 'utf8'
            content  = $BodyText
        }
    }

    Assert-PushTestThrowsLike {
        Invoke-RundotSyncPush `
            -WorkspaceRoot $confirmScenario.Workspace `
            -ProjectId $pushTestProjectId `
            -Resolution $confirmScenario.Resolution `
            -Artifact $confirmScenario.Artifact `
            -Local $confirmScenario.LocalMap `
            -Remote $confirmScenario.RemoteMap `
            -Snapshot $confirmScenario.Snapshot `
            -StudioOrigin $pushTestOrigin `
            -Headers $headers `
            -GetRemoteFile $getRemote `
            -PutRemoteFile $putRemote | Out-Null
    } 'Confirm the overwrite' 'Push must fail closed without -Force or a confirm callback'

    $script:PushTestPutCalls = 0
    $script:PushTestConfirmCalls = 0
    $declineResult = Invoke-RundotSyncPush `
        -WorkspaceRoot $confirmScenario.Workspace `
        -ProjectId $pushTestProjectId `
        -Resolution $confirmScenario.Resolution `
        -Artifact $confirmScenario.Artifact `
        -Local $confirmScenario.LocalMap `
        -Remote $confirmScenario.RemoteMap `
        -Snapshot $confirmScenario.Snapshot `
        -StudioOrigin $pushTestOrigin `
        -Headers $headers `
        -ConfirmOverwrite {
            param($Count, $Paths)
            $script:PushTestConfirmCalls++
            return $false
        } `
        -GetRemoteFile $getRemote `
        -PutRemoteFile $putRemote

    Assert-Equal 1 $script:PushTestConfirmCalls 'the overwrite confirmation must be invoked once'
    Assert-Equal $true $declineResult.Cancelled 'a declined confirmation must report as cancelled'
    Assert-Equal 0 $declineResult.Applied 'a declined confirmation must apply nothing'
    Assert-Equal 0 $script:PushTestPutCalls 'a declined confirmation must not PUT'
    Assert-Equal `
        0 `
        @(Get-RundotSyncBackupSets -WorkspaceRoot $confirmScenario.Workspace).Count `
        'a declined confirmation must not create a backup set'
    Assert-Equal `
        0 `
        @(Read-RundotSyncJournal -WorkspaceRoot $confirmScenario.Workspace).Count `
        'a declined confirmation must not write a journal record'

    $script:PushTestPutCalls = 0
    $script:PushTestGetCalls = 0
    $confirmResult = Invoke-RundotSyncPush `
        -WorkspaceRoot $confirmScenario.Workspace `
        -ProjectId $pushTestProjectId `
        -Resolution $confirmScenario.Resolution `
        -Artifact $confirmScenario.Artifact `
        -Local $confirmScenario.LocalMap `
        -Remote $confirmScenario.RemoteMap `
        -Snapshot $confirmScenario.Snapshot `
        -StudioOrigin $pushTestOrigin `
        -Headers $headers `
        -ConfirmOverwrite {
            param($Count, $Paths)
            return $true
        } `
        -GetRemoteFile $getRemote `
        -PutRemoteFile $putRemote

    Assert-Equal 1 $confirmResult.Applied 'a confirmed push must apply'

    $script:PushTestForceConfirmCalls = 0
    $forceResult = Invoke-RundotSyncPush `
        -WorkspaceRoot $confirmScenario.Workspace `
        -ProjectId $pushTestProjectId `
        -Resolution $confirmScenario.Resolution `
        -Artifact $confirmScenario.Artifact `
        -Local $confirmScenario.LocalMap `
        -Remote $confirmScenario.RemoteMap `
        -Snapshot $confirmScenario.Snapshot `
        -StudioOrigin $pushTestOrigin `
        -Headers $headers `
        -Force `
        -ConfirmOverwrite {
            param($Count, $Paths)
            $script:PushTestForceConfirmCalls++
            return $false
        } `
        -GetRemoteFile $getRemote `
        -PutRemoteFile $putRemote

    Assert-Equal 0 $script:PushTestForceConfirmCalls '-Force must not prompt for confirmation'
    Assert-Equal $false $forceResult.Cancelled '-Force must not report as cancelled'
    Assert-Equal 1 $forceResult.Applied '-Force must apply the action'

    Assert-PushTestThrowsLike {
        $forceConflictLocal = @{
            'src/text.ts' = (New-PushTestLocalEntry -Sha256 $pushTestShaB)
        }
        $forceConflictRemote = @{
            'src/text.ts' = (New-PushTestRemoteEntry -Sha256 $pushTestShaC)
        }
        $forceConflictArtifact = New-PushTestArtifact `
            -WorkspaceRoot $gateWorkspace `
            -LocalManifestHash (Get-SyncLocalManifestFingerprint -Local $forceConflictLocal) `
            -Operations @(
                (New-PushTestPlanOperation -Path 'src/text.ts' -LocalSha256 $pushTestShaB -RemoteSha256 $pushTestShaA -ExpectedRemoteHash $pushTestShaA)
            )
        Invoke-RundotSyncPush `
            -WorkspaceRoot $gateWorkspace `
            -ProjectId $pushTestProjectId `
            -Resolution (New-PushTestResolution -Files $selectBase) `
            -Artifact $forceConflictArtifact `
            -Local $forceConflictLocal `
            -Remote $forceConflictRemote `
            -Snapshot (New-PushTestSnapshot) `
            -StudioOrigin $pushTestOrigin `
            -Headers $headers `
            -Force `
            -GetRemoteFile $getRemote `
            -PutRemoteFile $putRemote | Out-Null
    } 'no longer an upload candidate' '-Force must not bypass conflict refusal'


    # --------------------------------------------------------------------------
    # Apply guards and one clean overwrite
    # --------------------------------------------------------------------------

    $scenario = New-PushTestTextOverwriteScenario -Root $pushTestRoot
    $script:PushTestGetCalls = 0
    $script:PushTestPutCalls = 0

    $getRemote = {
        param($Origin, $Id, $ApiPath, $Hdr)
        $script:PushTestGetCalls++
        return [pscustomobject]@{
            encoding = 'utf8'
            content  = $scenario.RemoteText
        }
    }

    $putRemote = {
        param($Origin, $Id, $Canonical, $BodyText, $Hdr)
        $script:PushTestPutCalls++
        return [pscustomobject]@{
            encoding = 'utf8'
            content  = $BodyText
        }
    }

    $pushResult = Invoke-RundotSyncPush `
        -WorkspaceRoot $scenario.Workspace `
        -ProjectId $pushTestProjectId `
        -Resolution $scenario.Resolution `
        -Artifact $scenario.Artifact `
        -Local $scenario.LocalMap `
        -Remote $scenario.RemoteMap `
        -Snapshot $scenario.Snapshot `
        -StudioOrigin $pushTestOrigin `
        -Headers $headers `
        -Force `
        -GetRemoteFile $getRemote `
        -PutRemoteFile $putRemote

    Assert-Equal 1 $pushResult.Applied 'one clean overwrite must apply'
    Assert-Equal $true $pushResult.BaseUpdated 'BASE must move after a successful push'
    Assert-Equal 2 $script:PushTestGetCalls 'each overwrite must GET remote for backup and again immediately before PUT'
    Assert-Equal 1 $script:PushTestPutCalls 'each overwrite must PUT once'
    Assert-True ($null -ne $pushResult.BackupSet) 'a mutating push must create a backup set'

    $backupPath = Join-Path $pushResult.BackupSet.Path ($scenario.Path.Replace('/', '\'))
    Assert-True (Test-Path -LiteralPath $backupPath -PathType Leaf) 'the remote original must be backed up before PUT'
    Assert-Equal `
        (Get-PushTestBytes -LiteralPath $backupPath) `
        ($pushTestUtf8.GetBytes($scenario.RemoteText)) `
        'the backup must hold the previous remote bytes, not the local publish payload'

    $afterBase = Read-BaseManifest -WorkspaceRoot $scenario.Workspace
    Assert-Equal `
        $scenario.LocalEntry.Sha256 `
        (Get-PushTestBaseEntrySha -Base $afterBase -Path $scenario.Path) `
        'BASE must record the published local hash'

    Assert-True `
        ($pushResult.Report -notmatch '(?i)bearer|authoriz|access[_-]?token|refresh[_-]?token|"content"') `
        'the push report must not contain tokens or file contents'
    Assert-True `
        (([string]$pushResult.Report) -match [regex]::Escape($pushResult.BackupRoot)) `
        'the report must print the backup root after a mutating push'

    $pushJournal = @(Read-RundotSyncJournal -WorkspaceRoot $scenario.Workspace)
    Assert-True ($pushJournal.Count -ge 2) 'a push must journal the run and its backups'
    Assert-True `
        (@($pushJournal | Where-Object { [string]$_.event -eq 'push' }).Count -eq 1) `
        'a push must write exactly one run record'
    Assert-True `
        (@($pushJournal | Where-Object { [string]$_.event -eq 'push-backup' }).Count -eq 1) `
        'a push must write one backup record per backed-up file'

    $pushRunRecord = @($pushJournal | Where-Object { [string]$_.event -eq 'push' })[0]
    Assert-Equal 'success' ([string]$pushRunRecord.status) 'a successful push must journal a success status'
    Assert-Equal $true $pushRunRecord.baseUpdated 'a successful push must journal baseUpdated true'
    Assert-Equal 1 $pushRunRecord.applied 'the push run record must report the applied count'
    Assert-Equal 1 $pushRunRecord.overwritten 'the push run record must report the overwrite count'
    Assert-Equal $pushTestProjectId ([string]$pushRunRecord.projectId) 'the push run record must carry the projectId'
    Assert-Equal $scenario.Artifact.planId ([string]$pushRunRecord.planId) 'the push run record must carry the plan artifact planId'

    $pushBackupRecord = @($pushJournal | Where-Object { [string]$_.event -eq 'push-backup' })[0]
    Assert-Equal $scenario.Path ([string]$pushBackupRecord.path) 'a push-backup record must name the backed-up path'
    Assert-True `
        (-not [string]::IsNullOrEmpty([string]$pushBackupRecord.backupSet)) `
        'a push-backup record must name the backup set'

    $pushJournalRaw = [System.IO.File]::ReadAllText(
        (Get-RundotSyncJournalPath -WorkspaceRoot $scenario.Workspace)
    )
    Assert-True `
        ($pushJournalRaw -notmatch '(?i)bearer|authoriz|accesstoken|refreshtoken|"content"') `
        'the push journal must never record tokens or contents'


    # --------------------------------------------------------------------------
    # Backup failure aborts before any PUT
    # --------------------------------------------------------------------------

    $backupFailScenario = New-PushTestTextOverwriteScenario -Root $pushTestRoot
    $backupFailSetPath = Join-Path (Get-RundotSyncBackupRoot -WorkspaceRoot $backupFailScenario.Workspace) 'injected-push-backup-set'
    $script:PushTestBackupFailPutCalls = 0
    $backupFailGetRemote = {
        param($Origin, $Id, $ApiPath, $Hdr)
        return [pscustomobject]@{
            encoding = 'utf8'
            content  = $backupFailScenario.RemoteText
        }
    }

    Assert-PushTestThrowsLike {
        Invoke-RundotSyncPushApply `
            -WorkspaceRoot $backupFailScenario.Workspace `
            -Actions @(
                [pscustomobject]@{
                    Path               = $backupFailScenario.Path
                    LocalSha256        = $backupFailScenario.LocalEntry.Sha256
                    ExpectedRemoteHash = $backupFailScenario.RemoteSha
                }
            ) `
            -StudioOrigin $pushTestOrigin `
            -ProjectId $pushTestProjectId `
            -Headers $headers `
            -BackupSetPath $backupFailSetPath `
            -GetRemoteFile $backupFailGetRemote `
            -PutRemoteFile {
                param($Origin, $Id, $Canonical, $BodyText, $Hdr)
                $script:PushTestBackupFailPutCalls++
                return [pscustomobject]@{ encoding = 'utf8'; content = $BodyText }
            } `
            -CopyBackupFile {
                throw [System.InvalidOperationException]::new('Injected backup failure.')
            } | Out-Null
    } 'Injected backup failure' 'a backup failure must abort the push before any PUT'

    Assert-Equal 0 $script:PushTestBackupFailPutCalls 'a backup failure must not PUT'
    Assert-True `
        (-not (Test-Path -LiteralPath (Join-Path $backupFailSetPath ($backupFailScenario.Path.Replace('/', '\'))) -PathType Leaf)) `
        'a backup failure must not leave a verified backup file behind'


    # --------------------------------------------------------------------------
    # GET hash mismatch and local drift refuse before PUT
    # --------------------------------------------------------------------------

    $badGetScenario = New-PushTestTextOverwriteScenario -Root $pushTestRoot
    $badGet = {
        param($Origin, $Id, $ApiPath, $Hdr)
        return [pscustomobject]@{
            encoding = 'utf8'
            content  = 'stale remote bytes'
        }
    }

    Assert-PushTestThrowsLike {
        Invoke-RundotSyncPushApply `
            -WorkspaceRoot $badGetScenario.Workspace `
            -Actions @(
                [pscustomobject]@{
                    Path               = $badGetScenario.Path
                    LocalSha256        = $badGetScenario.LocalEntry.Sha256
                    ExpectedRemoteHash = $badGetScenario.RemoteSha
                }
            ) `
            -StudioOrigin $pushTestOrigin `
            -ProjectId $pushTestProjectId `
            -Headers $headers `
            -GetRemoteFile $badGet `
            -PutRemoteFile $putRemote | Out-Null
    } 'no longer matches expectedRemoteHash' 'a remote hash mismatch must refuse before PUT'

    $driftPath = $badGetScenario.LocalFull
    [System.IO.File]::WriteAllBytes($driftPath, $pushTestUtf8.GetBytes('changed locally`n'))
    Assert-PushTestThrowsLike {
        Invoke-RundotSyncPushWriteAction `
            -WorkspaceRoot $badGetScenario.Workspace `
            -Action ([pscustomobject]@{
                Path               = $badGetScenario.Path
                LocalSha256        = $badGetScenario.LocalEntry.Sha256
                ExpectedRemoteHash = $badGetScenario.RemoteSha
            }) `
            -StudioOrigin $pushTestOrigin `
            -ProjectId $pushTestProjectId `
            -Headers $headers `
            -GetRemoteFile $getRemote `
            -PutRemoteFile $putRemote | Out-Null
    } 'changed since it was scanned' 'a concurrent local edit must refuse before PUT'


    # --------------------------------------------------------------------------
    # Partial failure: first PUT succeeds, second throws, BASE unchanged
    # --------------------------------------------------------------------------

    $partialWorkspace = New-PushTestWorkspace -Root $pushTestRoot
    $partial = New-PushTestTextOverwriteScenario -Root $pushTestRoot -Path 'src/one.ts' -Workspace $partialWorkspace
    $partialTwo = New-PushTestTextOverwriteScenario -Root $pushTestRoot -Path 'src/two.ts' -Workspace $partialWorkspace

    $partialLocalMap = @{
        'src/one.ts' = $partial.LocalEntry
        'src/two.ts' = $partialTwo.LocalEntry
    }
    $partialRemoteMap = @{
        'src/one.ts' = (New-PushTestRemoteEntry -Sha256 $partial.RemoteSha)
        'src/two.ts' = (New-PushTestRemoteEntry -Sha256 $partialTwo.RemoteSha)
    }
    $partialBaseMap = @{
        'src/one.ts' = (New-PushTestBaseEntry -Sha256 $partial.RemoteSha)
        'src/two.ts' = (New-PushTestBaseEntry -Sha256 $partialTwo.RemoteSha)
    }

    $partialArtifact = New-PushTestArtifact `
        -WorkspaceRoot $partialWorkspace `
        -LocalManifestHash (Get-SyncLocalManifestFingerprint -Local $partialLocalMap) `
        -Operations @(
            (New-PushTestPlanOperation `
                -Path 'src/one.ts' `
                -LocalSha256 $partial.LocalEntry.Sha256 `
                -RemoteSha256 $partial.RemoteSha `
                -ExpectedRemoteHash $partial.RemoteSha),
            (New-PushTestPlanOperation `
                -Path 'src/two.ts' `
                -LocalSha256 $partialTwo.LocalEntry.Sha256 `
                -RemoteSha256 $partialTwo.RemoteSha `
                -ExpectedRemoteHash $partialTwo.RemoteSha)
        )

    Save-BaseManifest `
        -WorkspaceRoot $partialWorkspace `
        -ProjectId $pushTestProjectId `
        -Files $partialBaseMap

    $partialBaseBefore = Read-BaseManifest -WorkspaceRoot $partialWorkspace
    $partialBaseOneBefore = Get-PushTestBaseEntrySha -Base $partialBaseBefore -Path 'src/one.ts'

    $script:PushTestPartialPutCount = 0
    $partialGetRemote = {
        param($Origin, $Id, $ApiPath, $Hdr)
        if ($ApiPath -match 'one') {
            return [pscustomobject]@{ encoding = 'utf8'; content = $partial.RemoteText }
        }
        return [pscustomobject]@{ encoding = 'utf8'; content = $partialTwo.RemoteText }
    }
    $partialPut = {
        param($Origin, $Id, $Canonical, $BodyText, $Hdr)
        $script:PushTestPartialPutCount++
        if ($Canonical -eq 'src/two.ts') {
            throw [System.InvalidOperationException]::new('Injected PUT failure on second path.')
        }
        return [pscustomobject]@{ encoding = 'utf8'; content = $BodyText }
    }

    Assert-PushTestThrowsLike {
        Invoke-RundotSyncPush `
            -WorkspaceRoot $partialWorkspace `
            -ProjectId $pushTestProjectId `
            -Resolution (New-PushTestResolution -Files $partialBaseMap) `
            -Artifact $partialArtifact `
            -Local $partialLocalMap `
            -Remote $partialRemoteMap `
            -Snapshot (New-PushTestSnapshot) `
            -StudioOrigin $pushTestOrigin `
            -Headers $headers `
            -Force `
            -GetRemoteFile $partialGetRemote `
            -PutRemoteFile $partialPut | Out-Null
    } 'Injected PUT failure' 'a failed second PUT must abort the run'

    $partialJournal = @(Read-RundotSyncJournal -WorkspaceRoot $partialWorkspace)
    Assert-Equal 1 $partialJournal.Count 'a failed push must journal exactly one run record'
    if ($partialJournal.Count -eq 1) {
        Assert-Equal 'failed' ([string]$partialJournal[0].status) 'a failed push must journal a failed status'
        Assert-Equal $false $partialJournal[0].baseUpdated 'a failed push must journal baseUpdated false'
        Assert-Equal 1 $partialJournal[0].applied 'a failed push must journal how many PUTs succeeded'
        Assert-True `
            (-not [string]::IsNullOrEmpty([string]$partialJournal[0].backupSet)) `
            'a failed push must journal the backup set name'
        Assert-True `
            (-not [string]::IsNullOrEmpty([string]$partialJournal[0].reason)) `
            'a failed push must journal why it failed'
    }

    Assert-Equal 2 $script:PushTestPartialPutCount 'the first PUT must have been attempted before the second failure'

    $partialBaseAfter = Read-BaseManifest -WorkspaceRoot $partialWorkspace
    Assert-Equal `
        $partialBaseOneBefore `
        (Get-PushTestBaseEntrySha -Base $partialBaseAfter -Path 'src/one.ts') `
        'BASE must not update when apply aborts mid-run'

    $partialBackupSets = @(Get-RundotSyncBackupSets -WorkspaceRoot $partialWorkspace)
    Assert-Equal 1 $partialBackupSets.Count 'a partial push must still keep the backup set it made before PUT'
    $partialBackupOne = Join-Path $partialBackupSets[0].Path 'src\one.ts'
    $partialBackupTwo = Join-Path $partialBackupSets[0].Path 'src\two.ts'
    Assert-Equal `
        ($pushTestUtf8.GetBytes($partial.RemoteText)) `
        (Get-PushTestBytes -LiteralPath $partialBackupOne) `
        'the backup set must hold the first remote original before PUT'
    Assert-Equal `
        ($pushTestUtf8.GetBytes($partialTwo.RemoteText)) `
        (Get-PushTestBytes -LiteralPath $partialBackupTwo) `
        'the backup set must hold the second remote original before PUT'


    # --------------------------------------------------------------------------
    # No-op push
    # --------------------------------------------------------------------------

    $noopArtifact = New-PushTestArtifact `
        -WorkspaceRoot $gateWorkspace `
        -LocalManifestHash $gateLocalHash `
        -Operations @(
            (New-PushTestPlanOperation `
                -Path 'public/x.png' `
                -LocalSha256 $pushTestShaB `
                -RemoteSha256 $pushTestShaA `
                -ExpectedRemoteHash $pushTestShaA `
                -Kind 'binary' `
                -Applicable $false `
                -Reason 'binary blocked')
        )

    $noopResult = Invoke-RundotSyncPush `
        -WorkspaceRoot $gateWorkspace `
        -ProjectId $pushTestProjectId `
        -Resolution $gateResolution `
        -Artifact $noopArtifact `
        -Local $gateLocalMap `
        -Remote $gateRemoteMap `
        -Snapshot $gateSnapshot `
        -StudioOrigin $pushTestOrigin `
        -Headers $headers `
        -GetRemoteFile $getRemote `
        -PutRemoteFile $putRemote

    Assert-Equal 0 $noopResult.Applied 'a plan with no publishable rows must no-op'
    Assert-Equal $false $noopResult.BaseUpdated 'a no-op push must not update BASE'
    Assert-Equal `
        0 `
        @(Read-RundotSyncJournal -WorkspaceRoot $gateWorkspace).Count `
        'a no-op push must not write a journal record'


    # --------------------------------------------------------------------------
    # Remote delete: selection, confirmation, backup, apply, BASE drop
    # --------------------------------------------------------------------------

    $deleteScenario = New-PushTestDeleteScenario -Root $pushTestRoot

    # The plan row is applicable, the live tree still matches, and selection
    # yields exactly one delete action and no overwrite action.
    $deleteSelection = Get-SyncPushSelection `
        -Artifact $deleteScenario.Artifact `
        -Base $deleteScenario.BaseMap `
        -Local $deleteScenario.LocalMap `
        -Remote $deleteScenario.RemoteMap

    $selectedDeleteActions = @($deleteSelection.DeleteActions)
    $selectedOverwriteActions = @($deleteSelection.Actions)
    Assert-Equal 0 $selectedOverwriteActions.Count 'a delete-only plan must select no overwrite'
    Assert-Equal 1 $selectedDeleteActions.Count 'a delete-only plan must select one delete action'
    Assert-Equal `
        $deleteScenario.Path `
        ([string]$selectedDeleteActions[0].Path) `
        'the selected delete path must be the planned one'

    # A reserved path is refused live even when a stale artifact said it was
    # applicable. The refusal must be the route rule, not a hash mismatch.
    Assert-PushTestThrowsLike {
        Get-SyncPushSelection `
            -Artifact $deleteScenario.ReservedArtifact `
            -Base $deleteScenario.ReservedBaseMap `
            -Local $deleteScenario.ReservedLocalMap `
            -Remote $deleteScenario.ReservedRemoteMap | Out-Null
    } 'Reserved path' 'a reserved path must refuse the whole run at selection'

    # A path that reappeared locally is no longer a remote delete.
    Assert-PushTestThrowsLike {
        Get-SyncPushSelection `
            -Artifact $deleteScenario.Artifact `
            -Base $deleteScenario.BaseMap `
            -Local $deleteScenario.ReappearedLocalMap `
            -Remote $deleteScenario.RemoteMap | Out-Null
    } 'no longer a remote delete candidate' 'a locally reappeared path must refuse the delete'

    # A declined delete confirmation changes nothing: no DELETE, no backup set,
    # no journal record, and BASE is untouched.
    $script:PushTestDeleteCalls = 0
    $deleteDeclineResult = Invoke-RundotSyncPush `
        -WorkspaceRoot $deleteScenario.Workspace `
        -ProjectId $pushTestProjectId `
        -Resolution $deleteScenario.Resolution `
        -Artifact $deleteScenario.Artifact `
        -Local $deleteScenario.LocalMap `
        -Remote $deleteScenario.RemoteMap `
        -Snapshot $deleteScenario.Snapshot `
        -StudioOrigin $pushTestOrigin `
        -Headers $headers `
        -ConfirmDelete {
            param($Count, $Paths)
            return $false
        } `
        -GetRemoteFile $deleteScenario.GetRemoteFile `
        -DeleteRemoteFile $deleteScenario.DeleteRemoteFile `
        -GetRemoteFileList $deleteScenario.GetRemoteFileList

    Assert-Equal $true $deleteDeclineResult.Cancelled 'a declined delete must report as cancelled'
    Assert-Equal 0 $deleteDeclineResult.Deleted 'a declined delete must delete nothing'
    Assert-Equal 0 $script:PushTestDeleteCalls 'a declined delete must not send DELETE'
    Assert-Equal `
        0 `
        @(Get-RundotSyncBackupSets -WorkspaceRoot $deleteScenario.Workspace).Count `
        'a declined delete must not create a backup set'
    Assert-Equal `
        0 `
        @(Read-RundotSyncJournal -WorkspaceRoot $deleteScenario.Workspace).Count `
        'a declined delete must not write a journal record'

    $deleteBaseBefore = Read-BaseManifest -WorkspaceRoot $deleteScenario.Workspace
    Assert-Equal `
        $deleteScenario.RemoteSha `
        (Get-PushTestBaseEntrySha -Base $deleteBaseBefore -Path $deleteScenario.Path) `
        'a declined delete must leave BASE unchanged'

    # No confirmation callback at all must fail closed rather than delete.
    Assert-PushTestThrowsLike {
        Invoke-RundotSyncPush `
            -WorkspaceRoot $deleteScenario.Workspace `
            -ProjectId $pushTestProjectId `
            -Resolution $deleteScenario.Resolution `
            -Artifact $deleteScenario.Artifact `
            -Local $deleteScenario.LocalMap `
            -Remote $deleteScenario.RemoteMap `
            -Snapshot $deleteScenario.Snapshot `
            -StudioOrigin $pushTestOrigin `
            -Headers $headers `
            -GetRemoteFile $deleteScenario.GetRemoteFile `
            -DeleteRemoteFile $deleteScenario.DeleteRemoteFile `
            -GetRemoteFileList $deleteScenario.GetRemoteFileList | Out-Null
    } 'Confirm the delete' 'a delete must fail closed without a confirmation callback'

    # A confirmed delete: backup holds the previous bytes, the DELETE is sent,
    # the path leaves BASE, and the journal records it without secrets.
    $script:PushTestDeleteCalls = 0
    $deleteResult = Invoke-RundotSyncPush `
        -WorkspaceRoot $deleteScenario.Workspace `
        -ProjectId $pushTestProjectId `
        -Resolution $deleteScenario.Resolution `
        -Artifact $deleteScenario.Artifact `
        -Local $deleteScenario.LocalMap `
        -Remote $deleteScenario.RemoteMap `
        -Snapshot $deleteScenario.Snapshot `
        -StudioOrigin $pushTestOrigin `
        -Headers $headers `
        -Force `
        -GetRemoteFile $deleteScenario.GetRemoteFile `
        -DeleteRemoteFile $deleteScenario.DeleteRemoteFile `
        -GetRemoteFileList $deleteScenario.GetRemoteFileList

    Assert-Equal 1 $deleteResult.Deleted 'a confirmed delete must delete one path'
    Assert-Equal 0 $deleteResult.Applied 'a delete-only push must not report an overwrite'
    Assert-Equal 1 $script:PushTestDeleteCalls 'a confirmed delete must send DELETE once'
    Assert-Equal $true $deleteResult.BaseUpdated 'BASE must move after a verified delete'

    $deleteBackupPath = Join-Path $deleteResult.BackupSet.Path ($deleteScenario.Path.Replace('/', '\'))
    Assert-True `
        (Test-Path -LiteralPath $deleteBackupPath -PathType Leaf) `
        'the remote original must be backed up before DELETE'
    Assert-Equal `
        ($pushTestUtf8.GetBytes($deleteScenario.RemoteText)) `
        (Get-PushTestBytes -LiteralPath $deleteBackupPath) `
        'the backup must hold the deleted remote bytes'

    $deleteBaseAfter = Read-BaseManifest -WorkspaceRoot $deleteScenario.Workspace
    Assert-True `
        ($null -eq $deleteBaseAfter.files.PSObject.Properties[$deleteScenario.Path]) `
        'a verified delete must drop the path from BASE rather than tombstone it'

    $deleteJournal = @(Read-RundotSyncJournal -WorkspaceRoot $deleteScenario.Workspace)
    $deleteRunRecord = @($deleteJournal | Where-Object { [string]$_.event -eq 'push' })[0]
    Assert-Equal 'success' ([string]$deleteRunRecord.status) 'a successful delete must journal success'
    Assert-Equal 1 $deleteRunRecord.deleted 'the run record must report the deleted count'
    Assert-Equal $true $deleteRunRecord.baseUpdated 'a successful delete must journal baseUpdated true'
    Assert-True `
        (@($deleteJournal | Where-Object { [string]$_.event -eq 'push-delete' }).Count -eq 1) `
        'a delete must write one push-delete record'

    $deleteRecord = @($deleteJournal | Where-Object { [string]$_.event -eq 'push-delete' })[0]
    Assert-Equal `
        $deleteScenario.Path `
        ([string]$deleteRecord.path) `
        'a push-delete record must name the deleted path'

    $deleteJournalRaw = [System.IO.File]::ReadAllText(
        (Get-RundotSyncJournalPath -WorkspaceRoot $deleteScenario.Workspace)
    )
    Assert-True `
        ($deleteJournalRaw -notmatch '(?i)bearer|authoriz|accesstoken|refreshtoken|"content"') `
        'the delete journal must never record tokens or contents'
    Assert-True `
        (([string]$deleteResult.Report) -match 'DELETED') `
        'the report must print a DELETED section'
    Assert-True `
        (([string]$deleteResult.Report) -notmatch '(?i)bearer|authoriz|accesstoken|refreshtoken|"content"') `
        'the report must not contain tokens or file contents'

    # A remote hash mismatch refuses that path before any DELETE.
    $mismatchScenario = New-PushTestDeleteScenario -Root $pushTestRoot
    $script:PushTestMismatchDeleteCalls = 0
    Assert-PushTestThrowsLike {
        Invoke-RundotSyncPushApply `
            -WorkspaceRoot $mismatchScenario.Workspace `
            -Actions @() `
            -DeleteActions @(
                [pscustomobject]@{
                    Path               = $mismatchScenario.Path
                    ExpectedRemoteHash = $mismatchScenario.RemoteSha
                    RemoteSha256       = $mismatchScenario.RemoteSha
                }
            ) `
            -StudioOrigin $pushTestOrigin `
            -ProjectId $pushTestProjectId `
            -Headers $headers `
            -GetRemoteFile {
                param($Origin, $Id, $ApiPath, $Hdr)
                return [pscustomobject]@{ encoding = 'utf8'; content = 'stale remote bytes' }
            } `
            -DeleteRemoteFile {
                param($Origin, $Id, $Canonical, $Hdr)
                $script:PushTestMismatchDeleteCalls++
                return [pscustomobject]@{ success = $true }
            } `
            -GetRemoteFileList $mismatchScenario.GetRemoteFileList | Out-Null
    } 'no longer matches expectedRemoteHash' 'a remote hash mismatch must refuse before DELETE'
    Assert-Equal 0 $script:PushTestMismatchDeleteCalls 'a hash mismatch must not send DELETE'

    # A backup failure aborts before any DELETE.
    $deleteBackupFailScenario = New-PushTestDeleteScenario -Root $pushTestRoot
    $script:PushTestDeleteBackupFailCalls = 0
    Assert-PushTestThrowsLike {
        Invoke-RundotSyncPushApply `
            -WorkspaceRoot $deleteBackupFailScenario.Workspace `
            -Actions @() `
            -DeleteActions @(
                [pscustomobject]@{
                    Path               = $deleteBackupFailScenario.Path
                    ExpectedRemoteHash = $deleteBackupFailScenario.RemoteSha
                    RemoteSha256       = $deleteBackupFailScenario.RemoteSha
                }
            ) `
            -StudioOrigin $pushTestOrigin `
            -ProjectId $pushTestProjectId `
            -Headers $headers `
            -GetRemoteFile $deleteBackupFailScenario.GetRemoteFile `
            -DeleteRemoteFile {
                param($Origin, $Id, $Canonical, $Hdr)
                $script:PushTestDeleteBackupFailCalls++
                return [pscustomobject]@{ success = $true }
            } `
            -GetRemoteFileList $deleteBackupFailScenario.GetRemoteFileList `
            -CopyBackupFile {
                throw [System.InvalidOperationException]::new('Injected delete backup failure.')
            } | Out-Null
    } 'Injected delete backup failure' 'a delete backup failure must abort before any DELETE'
    Assert-Equal 0 $script:PushTestDeleteBackupFailCalls 'a delete backup failure must not send DELETE'

    # A 404 on the DELETE is success when the postcondition holds: the path is
    # already absent, so this is not a new failure.
    $alreadyGoneScenario = New-PushTestDeleteScenario -Root $pushTestRoot
    $script:PushTestAlreadyGoneDeleteCalls = 0
    $alreadyGoneResult = Invoke-RundotSyncPushApply `
        -WorkspaceRoot $alreadyGoneScenario.Workspace `
        -Actions @() `
        -DeleteActions @(
            [pscustomobject]@{
                Path               = $alreadyGoneScenario.Path
                ExpectedRemoteHash = $alreadyGoneScenario.RemoteSha
                RemoteSha256       = $alreadyGoneScenario.RemoteSha
            }
        ) `
        -StudioOrigin $pushTestOrigin `
        -ProjectId $pushTestProjectId `
        -Headers $headers `
        -GetRemoteFile $alreadyGoneScenario.GetRemoteFile `
        -DeleteRemoteFile {
            param($Origin, $Id, $Canonical, $Hdr)
            $script:PushTestAlreadyGoneDeleteCalls++
            throw (New-RemoteHttpException -StatusCode 404 -Message 'not found')
        } `
        -GetRemoteFileList {
            param($Origin, $Id, $Hdr)
            return [pscustomobject]@{ files = @() }
        }

    Assert-Equal 1 $script:PushTestAlreadyGoneDeleteCalls 'the second DELETE must be attempted'
    Assert-Equal 1 $alreadyGoneResult.Deleted 'a 404 with the postcondition holding must count as deleted'
    Assert-Equal $true $alreadyGoneResult.DeletedActions[0].AlreadyAbsent 'an already-absent delete must be flagged'

    # A 404 whose postcondition does NOT hold is a real failure: the path is
    # still listed, so something is wrong and the run must not report success.
    $notGoneScenario = New-PushTestDeleteScenario -Root $pushTestRoot
    Assert-PushTestThrowsLike {
        Invoke-RundotSyncPushApply `
            -WorkspaceRoot $notGoneScenario.Workspace `
            -Actions @() `
            -DeleteActions @(
                [pscustomobject]@{
                    Path               = $notGoneScenario.Path
                    ExpectedRemoteHash = $notGoneScenario.RemoteSha
                    RemoteSha256       = $notGoneScenario.RemoteSha
                }
            ) `
            -StudioOrigin $pushTestOrigin `
            -ProjectId $pushTestProjectId `
            -Headers $headers `
            -GetRemoteFile $notGoneScenario.GetRemoteFile `
            -DeleteRemoteFile {
                param($Origin, $Id, $Canonical, $Hdr)
                throw (New-RemoteHttpException -StatusCode 404 -Message 'not found')
            } `
            -GetRemoteFileList $notGoneScenario.GetRemoteFileList | Out-Null
    } 'still lists it' 'a 404 with the path still listed must fail rather than report success'

    # A 200 whose postcondition does not hold is also a failure: a status is
    # not the proof the file is gone.
    $stillListedScenario = New-PushTestDeleteScenario -Root $pushTestRoot
    Assert-PushTestThrowsLike {
        Invoke-RundotSyncPushApply `
            -WorkspaceRoot $stillListedScenario.Workspace `
            -Actions @() `
            -DeleteActions @(
                [pscustomobject]@{
                    Path               = $stillListedScenario.Path
                    ExpectedRemoteHash = $stillListedScenario.RemoteSha
                    RemoteSha256       = $stillListedScenario.RemoteSha
                }
            ) `
            -StudioOrigin $pushTestOrigin `
            -ProjectId $pushTestProjectId `
            -Headers $headers `
            -GetRemoteFile $stillListedScenario.GetRemoteFile `
            -DeleteRemoteFile {
                param($Origin, $Id, $Canonical, $Hdr)
                return [pscustomobject]@{ success = $true }
            } `
            -GetRemoteFileList $stillListedScenario.GetRemoteFileList | Out-Null
    } 'still lists it' 'a 200 with the path still listed must fail the absence check'

    # A reserved path must never reach DELETE even when injected directly into
    # the apply layer, which is the last line of defense before the request.
    $reservedApplyScenario = New-PushTestDeleteScenario -Root $pushTestRoot
    $script:PushTestReservedApplyCalls = 0
    Assert-PushTestThrowsLike {
        Invoke-RundotSyncDeleteAction `
            -WorkspaceRoot $reservedApplyScenario.Workspace `
            -Action ([pscustomobject]@{
                Path               = '.rundot/config'
                ExpectedRemoteHash = $reservedApplyScenario.RemoteSha
            }) `
            -StudioOrigin $pushTestOrigin `
            -ProjectId $pushTestProjectId `
            -Headers $headers `
            -GetRemoteFile $reservedApplyScenario.GetRemoteFile `
            -DeleteRemoteFile {
                param($Origin, $Id, $Canonical, $Hdr)
                $script:PushTestReservedApplyCalls++
                return [pscustomobject]@{ success = $true }
            } `
            -GetRemoteFileList $reservedApplyScenario.GetRemoteFileList | Out-Null
    } 'Reserved path' 'the apply layer must refuse a reserved path'
    Assert-Equal 0 $script:PushTestReservedApplyCalls 'a reserved path must never send DELETE'


    # --------------------------------------------------------------------------
    # Local-wins selection and apply
    # --------------------------------------------------------------------------

    $lwBase = @{
        'src/conflict.ts' = (New-PushTestBaseEntry -Sha256 $pushTestShaA)
        'src/kind.ts'     = (New-PushTestBaseEntry -Sha256 $pushTestShaA)
        'src/remote.ts'   = (New-PushTestBaseEntry -Sha256 $pushTestShaA)
    }
    $lwLocal = @{
        'src/conflict.ts' = (New-PushTestLocalEntry -Sha256 $pushTestShaB)
        'src/kind.ts'     = (New-PushTestLocalEntry -Sha256 $pushTestShaB -Kind 'binary')
        'src/remote.ts'   = (New-PushTestLocalEntry -Sha256 $pushTestShaA)
        'src/local-only.ts' = (New-PushTestLocalEntry -Sha256 $pushTestShaC)
    }
    $lwRemote = @{
        'src/conflict.ts' = (New-PushTestRemoteEntry -Sha256 $pushTestShaC)
        'src/kind.ts'     = (New-PushTestRemoteEntry -Sha256 $pushTestShaA)
        'src/remote.ts'   = (New-PushTestRemoteEntry -Sha256 $pushTestShaB)
        'remote-only.ts'  = (New-PushTestRemoteEntry -Sha256 $pushTestShaD)
    }
    $lwArtifact = New-PushTestArtifact `
        -WorkspaceRoot $gateWorkspace `
        -LocalManifestHash (Get-SyncLocalManifestFingerprint -Local $lwLocal) `
        -Operations @(
            (New-PushTestPlanOperation -Path 'src/conflict.ts' -Status 'conflict' -Applicable $false -LocalSha256 $pushTestShaB -RemoteSha256 $pushTestShaC -ExpectedRemoteHash $pushTestShaC),
            (New-PushTestPlanOperation -Path 'src/kind.ts' -Status 'conflict' -Applicable $false -KindChange $true -LocalSha256 $pushTestShaB -RemoteSha256 $pushTestShaA -ExpectedRemoteHash $pushTestShaA -Kind 'binary'),
            (New-PushTestPlanOperation -Path 'src/remote.ts' -Status 'download' -Applicable $true -LocalSha256 $pushTestShaA -RemoteSha256 $pushTestShaB -ExpectedRemoteHash $pushTestShaB),
            (New-PushTestPlanOperation -Path 'remote-only.ts' -Status 'download' -Applicable $true -LocalSha256 $null -RemoteSha256 $pushTestShaD -ExpectedRemoteHash $pushTestShaD),
            (New-PushTestPlanOperation -Path 'src/local-only.ts' -Status 'upload' -Applicable $false -LocalSha256 $pushTestShaC -RemoteSha256 $null -ExpectedRemoteHash $null -Reason 'blocked')
        )

    $lwSelection = Get-SyncPushLocalWinsSelection `
        -Artifact $lwArtifact `
        -Base $lwBase `
        -Local $lwLocal `
        -Remote $lwRemote

    Assert-Equal 1 $lwSelection.Actions.Count 'local-wins must select a utf8 conflict overwrite'
    Assert-Equal 'src/conflict.ts' ([string]$lwSelection.Actions[0].Path) 'the conflict overwrite path must be selected'

    $lwRemoteDownload = @($lwSelection.DeleteActions | Where-Object { [string]$_.Path -eq 'remote-only.ts' })
    Assert-Equal 1 $lwRemoteDownload.Count 'local-wins must delete a remote-only download'

    $lwPullDownload = @($lwSelection.Excluded | Where-Object { [string]$_.Path -eq 'src/remote.ts' })
    Assert-Equal 1 $lwPullDownload.Count 'local-wins must skip A/A/B download rows'
    Assert-Equal 'download' ([string]$lwPullDownload[0].Status) 'the skipped row must stay download'

    $lwKind = @($lwSelection.Excluded | Where-Object { [string]$_.Path -eq 'src/kind.ts' })
    Assert-Equal 1 $lwKind.Count 'local-wins must skip kind-change conflicts'

    $defaultStill = Get-SyncPushSelection `
        -Artifact $lwArtifact `
        -Base $lwBase `
        -Local $lwLocal `
        -Remote $lwRemote
    Assert-Equal 0 $defaultStill.Actions.Count 'default Push must still refuse conflict overwrites'

    $lwDeclineWorkspace = New-PushTestWorkspace -Root $pushTestRoot
    $lwDecline = New-PushTestTextOverwriteScenario -Root $pushTestRoot -Path 'src/lw-decline.ts' -Workspace $lwDeclineWorkspace
    $lwDeclineArtifact = New-PushTestArtifact `
        -WorkspaceRoot $lwDeclineWorkspace `
        -LocalManifestHash (Get-SyncLocalManifestFingerprint -Local @{ 'src/lw-decline.ts' = $lwDecline.LocalEntry }) `
        -Operations @(
            (New-PushTestPlanOperation `
                -Path 'src/lw-decline.ts' `
                -Status 'conflict' `
                -Applicable $false `
                -LocalSha256 $lwDecline.LocalEntry.Sha256 `
                -RemoteSha256 $pushTestShaC `
                -ExpectedRemoteHash $pushTestShaC)
        )
    Save-BaseManifest `
        -WorkspaceRoot $lwDeclineWorkspace `
        -ProjectId $pushTestProjectId `
        -Files @{ 'src/lw-decline.ts' = (New-PushTestBaseEntry -Sha256 $lwDecline.RemoteSha) }

    $lwDeclineSelection = Get-SyncPushLocalWinsSelection `
        -Artifact $lwDeclineArtifact `
        -Base @{ 'src/lw-decline.ts' = (New-PushTestBaseEntry -Sha256 $lwDecline.RemoteSha) } `
        -Local @{ 'src/lw-decline.ts' = $lwDecline.LocalEntry } `
        -Remote @{ 'src/lw-decline.ts' = (New-PushTestRemoteEntry -Sha256 $pushTestShaC) }
    Assert-Equal 1 $lwDeclineSelection.Actions.Count 'local-wins must select a declined conflict overwrite'

    $script:PushTestLwPutCalls = 0
    $lwDeclineResult = Invoke-RundotSyncPush `
        -WorkspaceRoot $lwDeclineWorkspace `
        -ProjectId $pushTestProjectId `
        -Resolution (New-PushTestResolution -Files @{ 'src/lw-decline.ts' = (New-PushTestBaseEntry -Sha256 $lwDecline.RemoteSha) }) `
        -Artifact $lwDeclineArtifact `
        -Local @{ 'src/lw-decline.ts' = $lwDecline.LocalEntry } `
        -Remote @{ 'src/lw-decline.ts' = (New-PushTestRemoteEntry -Sha256 $pushTestShaC) } `
        -Snapshot (New-PushTestSnapshot) `
        -StudioOrigin $pushTestOrigin `
        -Headers $headers `
        -LocalWins `
        -ConfirmLocalWins { return $false } `
        -GetRemoteFile $getRemote `
        -PutRemoteFile {
            param($Origin, $Id, $Canonical, $BodyText, $Hdr)
            $script:PushTestLwPutCalls++
            return [pscustomobject]@{ encoding = 'utf8'; content = $BodyText }
        }

    Assert-Equal $true $lwDeclineResult.Cancelled 'a declined local-wins confirm must cancel'
    Assert-Equal 0 $script:PushTestLwPutCalls 'a declined local-wins confirm must not PUT'

    $lwPartialWorkspace = New-PushTestWorkspace -Root $pushTestRoot
    $lwOne = New-PushTestTextOverwriteScenario -Root $pushTestRoot -Path 'src/lw-one.ts' -Workspace $lwPartialWorkspace
    $lwTwo = New-PushTestTextOverwriteScenario -Root $pushTestRoot -Path 'src/lw-two.ts' -Workspace $lwPartialWorkspace

    $lwOneRemoteStaging = Join-Path $pushTestRoot ('lw-one-remote-' + [Guid]::NewGuid().ToString('N') + '.txt')
    $lwTwoRemoteStaging = Join-Path $pushTestRoot ('lw-two-remote-' + [Guid]::NewGuid().ToString('N') + '.txt')
    Write-PushTestBytes -LiteralPath $lwOneRemoteStaging -Bytes ($pushTestUtf8.GetBytes("conflict remote one`n"))
    Write-PushTestBytes -LiteralPath $lwTwoRemoteStaging -Bytes ($pushTestUtf8.GetBytes("conflict remote two`n"))
    $lwOneConflictRemoteSha = (Get-LocalFileIdentity -LiteralPath $lwOneRemoteStaging).Sha256
    $lwTwoConflictRemoteSha = (Get-LocalFileIdentity -LiteralPath $lwTwoRemoteStaging).Sha256
    $lwOneConflictRemoteText = $pushTestUtf8.GetString((Get-PushTestBytes -LiteralPath $lwOneRemoteStaging))
    $lwTwoConflictRemoteText = $pushTestUtf8.GetString((Get-PushTestBytes -LiteralPath $lwTwoRemoteStaging))

    $lwPartialLocal = @{
        'src/lw-one.ts' = $lwOne.LocalEntry
        'src/lw-two.ts' = $lwTwo.LocalEntry
    }
    $lwPartialRemote = @{
        'src/lw-one.ts' = (New-PushTestRemoteEntry -Sha256 $lwOneConflictRemoteSha)
        'src/lw-two.ts' = (New-PushTestRemoteEntry -Sha256 $lwTwoConflictRemoteSha)
    }
    $lwPartialBase = @{
        'src/lw-one.ts' = (New-PushTestBaseEntry -Sha256 $lwOne.RemoteSha)
        'src/lw-two.ts' = (New-PushTestBaseEntry -Sha256 $lwTwo.RemoteSha)
    }
    $lwPartialArtifact = New-PushTestArtifact `
        -WorkspaceRoot $lwPartialWorkspace `
        -LocalManifestHash (Get-SyncLocalManifestFingerprint -Local $lwPartialLocal) `
        -Operations @(
            (New-PushTestPlanOperation -Path 'src/lw-one.ts' -Status 'conflict' -Applicable $false -LocalSha256 $lwOne.LocalEntry.Sha256 -RemoteSha256 $lwOneConflictRemoteSha -ExpectedRemoteHash $lwOneConflictRemoteSha),
            (New-PushTestPlanOperation -Path 'src/lw-two.ts' -Status 'conflict' -Applicable $false -LocalSha256 $lwTwo.LocalEntry.Sha256 -RemoteSha256 $lwTwoConflictRemoteSha -ExpectedRemoteHash $lwTwoConflictRemoteSha)
        )
    Save-BaseManifest `
        -WorkspaceRoot $lwPartialWorkspace `
        -ProjectId $pushTestProjectId `
        -Files $lwPartialBase

    $script:PushTestLwTwoGetCount = 0
    $lwPartialGet = {
        param($Origin, $Id, $ApiPath, $Hdr)
        if ($ApiPath -match 'lw-one') {
            return [pscustomobject]@{ encoding = 'utf8'; content = $lwOneConflictRemoteText }
        }
        if ($ApiPath -match 'lw-two') {
            $script:PushTestLwTwoGetCount++
            if ($script:PushTestLwTwoGetCount -eq 1) {
                return [pscustomobject]@{ encoding = 'utf8'; content = $lwTwoConflictRemoteText }
            }
            return [pscustomobject]@{ encoding = 'utf8'; content = 'stale remote for two' }
        }
        return [pscustomobject]@{ encoding = 'utf8'; content = '' }
    }
    $script:PushTestLwPartialPut = 0
    $lwPartialResult = Invoke-RundotSyncPush `
        -WorkspaceRoot $lwPartialWorkspace `
        -ProjectId $pushTestProjectId `
        -Resolution (New-PushTestResolution -Files $lwPartialBase) `
        -Artifact $lwPartialArtifact `
        -Local $lwPartialLocal `
        -Remote $lwPartialRemote `
        -Snapshot (New-PushTestSnapshot) `
        -StudioOrigin $pushTestOrigin `
        -Headers $headers `
        -LocalWins `
        -Force `
        -GetRemoteFile $lwPartialGet `
        -PutRemoteFile {
            param($Origin, $Id, $Canonical, $BodyText, $Hdr)
            $script:PushTestLwPartialPut++
            return [pscustomobject]@{ encoding = 'utf8'; content = $BodyText }
        }

    Assert-Equal $true $lwPartialResult.HadRefusals 'local-wins must report refusals when a path drifts'
    Assert-Equal $true $lwPartialResult.BaseUpdated 'local-wins must update BASE for verified paths only'
    Assert-Equal 1 $lwPartialResult.AppliedActions.Count 'only one conflict overwrite must verify'
    Assert-Equal 1 $script:PushTestLwPartialPut 'only one PUT must succeed when the second path drifts'

    $lwPartialJournal = @(
        Read-RundotSyncJournal -WorkspaceRoot $lwPartialWorkspace |
        Where-Object { [string]$_.event -eq 'push' }
    )
    Assert-Equal 1 $lwPartialJournal.Count 'local-wins partial failure must journal one push run record'
    Assert-Equal 'failed' ([string]$lwPartialJournal[0].status) 'local-wins partial failure must journal failed'
    Assert-Equal $true $lwPartialJournal[0].baseUpdated 'local-wins partial failure must journal baseUpdated true when some paths verified'

    $lwPartialBaseAfter = Read-BaseManifest -WorkspaceRoot $lwPartialWorkspace
    Assert-Equal `
        $lwOne.LocalEntry.Sha256 `
        (Get-PushTestBaseEntrySha -Base $lwPartialBaseAfter -Path 'src/lw-one.ts') `
        'verified local-wins paths must update BASE'
    Assert-Equal `
        $lwTwo.RemoteSha `
        (Get-PushTestBaseEntrySha -Base $lwPartialBaseAfter -Path 'src/lw-two.ts') `
        'refused local-wins paths must keep the previous BASE entry'
}
finally {
    if (Test-Path -LiteralPath $pushTestRoot) {
        Remove-Item -LiteralPath $pushTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
