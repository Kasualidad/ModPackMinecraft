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

$indexDir = Join-Path $PWD "mods/.index"
if (-not (Test-Path -LiteralPath $indexDir)) {
    throw "mods/.index not found. This pack expects Packwiz metafiles there."
}

$metafiles = @(Get-ChildItem -LiteralPath $indexDir -Filter "*.pw.toml" -File | Sort-Object Name)

$blocks = New-Object System.Collections.Generic.List[string]
foreach ($file in $metafiles) {
    $relativePath = "mods/.index/$($file.Name)"
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $blocks.Add("[[files]]`nfile = `"$relativePath`"`nhash = `"$hash`"`nmetafile = true")
}

$output = "hash-format = `"sha256`"`n"
if ($blocks.Count -gt 0) {
    $output += "`n"
    $output += ($blocks -join "`n`n")
    $output += "`n"
}

Write-Utf8NoBomLf -Path "index.toml" -Content $output
Write-Host "Rebuilt index.toml from $($blocks.Count) mods/.index/*.pw.toml entries."
