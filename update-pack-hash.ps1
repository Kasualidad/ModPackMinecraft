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

if (-not (Test-Path -LiteralPath "index.toml") -or -not (Test-Path -LiteralPath "pack.toml")) {
    throw "pack.toml or index.toml not found. Run this script from the pack repository root."
}

$indexHash = (Get-FileHash -LiteralPath "index.toml" -Algorithm SHA256).Hash.ToLowerInvariant()
$pack = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath "pack.toml"))
$pack = ($pack -replace "`r`n", "`n") -replace "`r", "`n"

$pattern = '(?ms)(\[index\].*?hash-format\s*=\s*"sha256"\s*?\n\s*hash\s*=\s*")[a-fA-F0-9]{64}(")'
if (-not [regex]::IsMatch($pack, $pattern)) {
    throw "Could not find the [index] sha256 hash entry in pack.toml."
}

$pack = [regex]::Replace($pack, $pattern, "`${1}$indexHash`${2}", 1)
Write-Utf8NoBomLf -Path "pack.toml" -Content $pack

Write-Host "Updated pack.toml index hash:"
Write-Host "  $indexHash"
