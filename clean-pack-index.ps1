$ErrorActionPreference = "Stop"

function Write-Utf8NoBomLf {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $normalized = ($Content -replace "`r`n", "`n") -replace "`r", "`n"
    if (-not $normalized.EndsWith("`n")) {
        $normalized += "`n"
    }

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $Path), $normalized, $encoding)
}

if (-not (Test-Path -LiteralPath "index.toml")) {
    throw "index.toml not found. Run this script from the pack repository root."
}

$content = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath "index.toml"))
$content = ($content -replace "`r`n", "`n") -replace "`r", "`n"

$validBlocks = New-Object System.Collections.Generic.List[string]
$blockPattern = "(?ms)^\s*\[\[files\]\]\s*.*?(?=^\s*\[\[files\]\]|\z)"
$filePattern = '(?m)^\s*file\s*=\s*"([^"]+)"\s*$'

foreach ($match in [regex]::Matches($content, $blockPattern)) {
    $block = $match.Value.Trim()
    $fileMatch = [regex]::Match($block, $filePattern)
    if (-not $fileMatch.Success) {
        continue
    }

    $filePath = $fileMatch.Groups[1].Value
    if ($filePath -match '^mods/\.index/[^/\\]+\.pw\.toml$') {
        $validBlocks.Add($block)
    }
}

$output = "hash-format = `"sha256`"`n"
if ($validBlocks.Count -gt 0) {
    $output += "`n"
    $output += ($validBlocks -join "`n`n")
    $output += "`n"
}

Write-Utf8NoBomLf -Path "index.toml" -Content $output
Write-Host "Cleaned index.toml. Kept $($validBlocks.Count) mods/.index/*.pw.toml entries."
