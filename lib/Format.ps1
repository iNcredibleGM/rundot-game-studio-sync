# Shared display form for SHA-256 values in plan and Adopt reports.
# Empty or null renders as <none>. Values of 16 characters or fewer are
# unchanged. Longer values render as the first 8 characters, '...', and the
# last 4.

function Format-SyncShortHash {
    param($Value)

    $text = [string]$Value
    if ([string]::IsNullOrEmpty($text)) {
        return '<none>'
    }

    if ($text.Length -le 16) {
        return $text
    }

    return ($text.Substring(0, 8) + '...' + $text.Substring($text.Length - 4))
}
