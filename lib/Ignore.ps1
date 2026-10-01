# Default ignore matcher for local sync inventory, plus an additive root
# .gitignore layer (#64).
#
# There is still no .rundotignore parser. The root .gitignore is an ADDITIVE
# FLOOR over the fixed built-in set: it can only add ignores, never re-include
# or override a built-in entry. Negation ('!pattern') is recorded and reported
# but not obeyed, so a negation can never re-include a built-in ignore.
#
# Classifiers must consult Test-IgnoredSyncPath before emitting upload or
# deleteRemoteCandidate. The effective ignore set is per-workspace state, set
# once by Set-SyncIgnoreContext before a run and cleared by Clear-SyncIgnoreContext.
#
# Callers must load Paths.ps1 first.

$script:SyncGitIgnoreFileName = '.gitignore'
$script:SyncGitIgnoreContext = $null

function New-SyncGitIgnoreRule {
    # One parsed, validated rule. Throws on a pattern this patch cannot
    # represent safely: the caller fails the run closed rather than skipping a
    # rule silently (#64).
    param(
        [Parameter(Mandatory)]
        [int]$LineNumber,

        [Parameter(Mandatory)]
        [string]$Text
    )

    if (Test-EmbeddedNul -Text $Text) {
        throw [System.InvalidOperationException]::new(
            ".gitignore line $LineNumber contains an embedded NUL and cannot be parsed."
        )
    }

    $line = $Text.Replace('\', '/')

    if ($line.EndsWith('/') -and $line.Length -gt 0) {
        $line = $line.Substring(0, $line.Length - 1)
    }

    if ([string]::IsNullOrEmpty($line)) {
        throw [System.InvalidOperationException]::new(
            ".gitignore line $LineNumber does not name a path and cannot be parsed."
        )
    }

    if ($line.StartsWith('/')) {
        $leadingSlash = $true
        $line = $line.Substring(1)
    }
    else {
        $leadingSlash = $false
    }

    if ([string]::IsNullOrEmpty($line)) {
        throw [System.InvalidOperationException]::new(
            ".gitignore line $LineNumber names only '/' and cannot be parsed."
        )
    }

    $segments = $line.Split(@('/'), [System.StringSplitOptions]::None)
    foreach ($segment in $segments) {
        if ($segment -eq '') {
            throw [System.InvalidOperationException]::new(
                ".gitignore line $LineNumber has an empty path segment and cannot be parsed."
            )
        }

        if ($segment -eq '.' -or $segment -eq '..') {
            throw [System.InvalidOperationException]::new(
                ".gitignore line $LineNumber contains a '.' or '..' segment and cannot be parsed."
            )
        }
    }

    $leaf = $segments[$segments.Length - 1]
    $hasSlash = ($segments.Length -gt 1)

    # A leading slash or an internal slash anchors the rule to the workspace
    # root (git semantics). A truly slashless rule is unanchored and matches at
    # any depth, which also covers a directory of that name and its contents.
    $anchored = ($leadingSlash -or $hasSlash)

    return [pscustomobject]@{
        LineNumber = [int]$LineNumber
        Text       = [string]$line
        Leaf       = [string]$leaf
        HasSlash   = [bool]$hasSlash
        Anchored   = [bool]$anchored
        Segments   = [string[]]$segments
    }
}

function Get-SyncGitIgnoreRules {
    # Parse root .gitignore text into rules. Blank lines and '#' comments are
    # skipped. A negation line ('!pattern') is returned with Negated = $true so
    # the caller can report it; it is never obeyed in this patch. A parse
    # failure throws, which fails the whole run closed.
    param([AllowNull()][string]$Text)

    $rules = New-Object 'System.Collections.Generic.List[object]'

    if ([string]::IsNullOrEmpty($Text)) {
        return $rules.ToArray()
    }

    $lines = $Text -split "`r`n|`n|`r"
    for ($index = 0; $index -lt $lines.Length; $index++) {
        $lineNumber = $index + 1
        $line = [string]$lines[$index]

        if ($line.EndsWith("`r")) {
            $line = $line.Substring(0, $line.Length - 1)
        }

        $trimmed = $line.Trim()

        # A UTF-8 BOM is not stripped by the reader, and left in place it would
        # silently defeat the first rule. Strip it from the first line only.
        if (
            $index -eq 0 -and
            $trimmed.Length -gt 0 -and
            [int][char]$trimmed[0] -eq 0xFEFF
        ) {
            $trimmed = $trimmed.Substring(1).Trim()
        }

        if ([string]::IsNullOrEmpty($trimmed)) {
            continue
        }

        if ($trimmed.StartsWith('#')) {
            continue
        }

        if ($trimmed.StartsWith('!')) {
            $negated = $trimmed.Substring(1).Trim()
            if ([string]::IsNullOrEmpty($negated)) {
                throw [System.InvalidOperationException]::new(
                    ".gitignore line $lineNumber is an empty negation and cannot be parsed."
                )
            }

            $rules.Add([pscustomobject]@{
                LineNumber = [int]$lineNumber
                Text       = [string]$line
                Negated    = $true
            })
            continue
        }

        $rule = New-SyncGitIgnoreRule -LineNumber $lineNumber -Text $trimmed
        $rules.Add([pscustomobject]@{
            LineNumber = [int]$rule.LineNumber
            Text       = [string]$rule.Text
            Leaf       = [string]$rule.Leaf
            HasSlash   = [bool]$rule.HasSlash
            Anchored   = [bool]$rule.Anchored
            Segments   = [string[]]$rule.Segments
            Negated    = $false
        })
    }

    return $rules.ToArray()
}

function Test-SyncGitIgnoreSegmentMatch {
    param(
        [Parameter(Mandatory)]
        [string]$Segment,

        [Parameter(Mandatory)]
        [string]$Pattern
    )

    if ($Pattern.Contains('*') -or $Pattern.Contains('?')) {
        return $Segment -like $Pattern
    }

    return [string]::Equals($Segment, $Pattern, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-SyncGitIgnoreRuleMatch {
    # Does one non-negated rule ignore this canonical path?
    #
    # An UNANCHORED (slashless) rule matches a path segment of that name at any
    # depth, so 'node_modules' ignores both the directory and its contents. An
    # ANCHORED rule (leading slash or an internal slash) is pinned to the
    # workspace root: its segments must match the path's leading segments, and
    # its last segment may also match a later segment so a directory's contents
    # are ignored.
    param(
        [Parameter(Mandatory)]
        [string]$CanonicalPath,

        [Parameter(Mandatory)]
        $Rule
    )

    $path = Get-SyncIgnoreMatchPath -CanonicalPath $CanonicalPath
    if ([string]::IsNullOrEmpty($path)) {
        return $false
    }

    $segments = $path.Split(@('/'), [System.StringSplitOptions]::None)
    $leafPattern = [string]$Rule.Leaf

    if (-not [bool]$Rule.Anchored) {
        foreach ($segment in $segments) {
            if (Test-SyncGitIgnoreSegmentMatch -Segment $segment -Pattern $leafPattern) {
                return $true
            }
        }

        return $false
    }

    $ruleSegments = @($Rule.Segments)

    if ($segments.Length -lt $ruleSegments.Length) {
        return $false
    }

    # Every rule segment must match the path's leading segments in order. A
    # longer path means the rule matched an ancestor directory, so its contents
    # are ignored too.
    for ($i = 0; $i -lt $ruleSegments.Length; $i++) {
        if (
            -not (Test-SyncGitIgnoreSegmentMatch `
                -Segment $segments[$i] `
                -Pattern ([string]$ruleSegments[$i]))
        ) {
            return $false
        }
    }

    return $true
}

function Set-SyncIgnoreContext {
    # Parse a root .gitignore for one run and publish it to the matcher. $Text
    # of $null (or no file present) clears the layer. A parse failure throws
    # here, before any inventory, so the run fails closed.
    param([AllowNull()][string]$Text)

    $script:SyncGitIgnoreContext = $null

    if ([string]::IsNullOrEmpty($Text)) {
        return $false
    }

    $rules = @(Get-SyncGitIgnoreRules -Text $Text)
    $script:SyncGitIgnoreContext = [pscustomobject]@{
        Rules = [object[]]$rules
    }

    return $true
}

function Clear-SyncIgnoreContext {
    $script:SyncGitIgnoreContext = $null
}

function Get-SyncIgnoreLayerNotice {
    # A plain, host-visible description of the root .gitignore layer for this
    # run. Never silent: it states how many rules were added and reports every
    # negation line that was recorded but not obeyed (#64).
    if ($null -eq $script:SyncGitIgnoreContext) {
        return @()
    }

    $lines = New-Object 'System.Collections.Generic.List[string]'

    $added = 0
    $negations = New-Object 'System.Collections.Generic.List[string]'
    foreach ($rule in @($script:SyncGitIgnoreContext.Rules)) {
        if ([bool]$rule.Negated) {
            $negations.Add([string]$rule.Text)
        }
        else {
            $added++
        }
    }

    $lines.Add(
        ("Ignoring $added additional rule(s) from the root .gitignore (additive floor over the built-in set).")
    )

    if ($negations.Count -gt 0) {
        $lines.Add(
            ("$($negations.Count) .gitignore negation line(s) are NOT obeyed in this version and cannot re-include a path: " +
                ($negations.ToArray() -join ', '))
        )
    }

    return $lines.ToArray()
}

function Get-SyncRootGitIgnorePath {
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot
    )

    return (Join-Path $WorkspaceRoot $script:SyncGitIgnoreFileName)
}

function Read-SyncRootGitIgnoreText {
    # Read a present root .gitignore as UTF-8 text. A missing file is $null. A
    # read failure throws so the caller fails the run closed rather than
    # silently treating the tree as if no rule existed.
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot
    )

    $path = Get-SyncRootGitIgnorePath -WorkspaceRoot $WorkspaceRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }

    $utf8 = New-Object System.Text.UTF8Encoding $false, $true
    $stream = New-Object System.IO.FileStream(
        $path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    try {
        $reader = New-Object System.IO.StreamReader($stream, $utf8, $false, 1024, $true)
        try {
            return $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Test-GitIgnoredSyncPath {
    # The root .gitignore layer alone. Built-in ignores are handled by
    # Test-IgnoredSyncPath, which calls this after its own patterns.
    param(
        [Parameter(Mandatory)]
        [string]$CanonicalPath
    )

    if ($null -eq $script:SyncGitIgnoreContext) {
        return $false
    }

    foreach ($rule in @($script:SyncGitIgnoreContext.Rules)) {
        if ([bool]$rule.Negated) {
            # Not obeyed in this patch. A negation is reported, never a
            # re-include, so it can never override a built-in or added ignore.
            continue
        }

        if (Test-SyncGitIgnoreRuleMatch -CanonicalPath $CanonicalPath -Rule $rule) {
            return $true
        }
    }

    return $false
}

function Get-DefaultSyncIgnorePatterns {
    return @(
        '.git/',
        '.rundot-sync/',
        'node_modules/',
        'dist/',
        'build/',
        'out/',
        '.vs/',
        '.idea/',
        '.vscode/',
        '.rundot-studio-export/',
        'Thumbs.db',
        'desktop.ini',
        '.DS_Store',
        '*.swp',
        '*~',
        '*.tmp',
        '*.bak'
    )
}

function Get-SyncIgnoreMatchPath {
    param([string]$CanonicalPath)

    $path = $CanonicalPath.Replace('\', '/')

    if ($path.StartsWith('/')) {
        $path = $path.Substring(1)
    }

    while ($path.EndsWith('/') -and $path.Length -gt 0) {
        $path = $path.Substring(0, $path.Length - 1)
    }

    return $path
}

function Test-IgnoredSyncPath {
    param(
        [Parameter(Mandatory)]
        [string]$CanonicalPath
    )

    $path = Get-SyncIgnoreMatchPath -CanonicalPath $CanonicalPath

    if ([string]::IsNullOrEmpty($path)) {
        return $false
    }

    $segments = $path.Split(@('/'), [System.StringSplitOptions]::None)
    $leaf = $segments[$segments.Length - 1]

    foreach ($pattern in Get-DefaultSyncIgnorePatterns) {
        if ($pattern.EndsWith('/')) {
            $directoryName = $pattern.Substring(0, $pattern.Length - 1)
            foreach ($segment in $segments) {
                if ([string]::Equals($segment, $directoryName, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $true
                }
            }

            continue
        }

        if ($pattern.Contains('*')) {
            if ($leaf -like $pattern) {
                return $true
            }

            continue
        }

        if ([string]::Equals($leaf, $pattern, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    # Additive floor (#64): a root .gitignore can only ADD ignores. This runs
    # after the built-in set, so a gitignore negation can never re-include a
    # built-in ignore, and a gitignore rule can never override one.
    if (Test-GitIgnoredSyncPath -CanonicalPath $CanonicalPath) {
        return $true
    }

    return $false
}
