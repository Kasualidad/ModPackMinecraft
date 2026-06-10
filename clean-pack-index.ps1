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

$entries = @{}
$content = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath "index.toml"))
$content = ($content -replace "`r`n", "`n") -replace "`r", "`n"
$blockPattern = "(?ms)^\s*\[\[files\]\]\s*.*?(?=^\s*\[\[files\]\]|\z)"
$filePattern = '(?m)^\s*file\s*=\s*"([^"]+)"\s*$'
$hashPattern = '(?m)^\s*hash\s*=\s*"([a-fA-F0-9]{64})"\s*$'

foreach ($match in [regex]::Matches($content, $blockPattern)) {
    $block = $match.Value.Trim()
    $fileMatch = [regex]::Match($block, $filePattern)
    $hashMatch = [regex]::Match($block, $hashPattern)
    if (-not $fileMatch.Success -or -not $hashMatch.Success) {
        continue
    }

    $filePath = $fileMatch.Groups[1].Value
    if ($filePath -match '^mods/\.index/[^/\\]+\.pw\.toml$') {
        $entries[$filePath] = $hashMatch.Groups[1].Value.ToLowerInvariant()
    }
}

$indexDir = Join-Path $PWD "mods/.index"
if (Test-Path -LiteralPath $indexDir) {
    foreach ($file in (Get-ChildItem -LiteralPath $indexDir -Filter "*.pw.toml" -File)) {
        $relativePath = "mods/.index/$($file.Name)"
        $entries[$relativePath] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

$blocks = New-Object System.Collections.Generic.List[string]
foreach ($filePath in ($entries.Keys | Sort-Object)) {
    $hash = $entries[$filePath]
    $blocks.Add("[[files]]`nfile = `"$filePath`"`nhash = `"$hash`"`nmetafile = true")
}

$output = "hash-format = `"sha256`"`n"
if ($blocks.Count -gt 0) {
    $output += "`n"
    $output += ($blocks -join "`n`n")
    $output += "`n"
}

Write-Utf8NoBomLf -Path "index.toml" -Content $output
Write-Host "Cleaned index.toml safely. Kept or updated $($blocks.Count) mods/.index/*.pw.toml entries."
