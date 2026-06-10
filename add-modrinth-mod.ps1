param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Slug
)

$ErrorActionPreference = "Stop"

function Assert-RepoRoot {
    if (-not (Test-Path -LiteralPath "pack.toml") -or -not (Test-Path -LiteralPath "index.toml")) {
        throw "Run this script from the pack repository root, next to pack.toml and index.toml."
    }
}

Assert-RepoRoot

$modsDir = Join-Path $PWD "mods"
New-Item -ItemType Directory -Force -Path $modsDir | Out-Null

$before = @{}
if (Test-Path -LiteralPath $modsDir) {
    Get-ChildItem -LiteralPath $modsDir -Filter "*.pw.toml" -File | ForEach-Object {
        $before[$_.FullName] = $true
    }
}

Write-Host "Adding Modrinth project: $Slug"
& packwiz modrinth add $Slug
if ($LASTEXITCODE -ne 0) {
    throw "packwiz modrinth add failed with exit code $LASTEXITCODE."
}

$createdOrLoose = @(Get-ChildItem -LiteralPath $modsDir -Filter "*.pw.toml" -File | Where-Object {
    -not $before.ContainsKey($_.FullName)
})

if ($createdOrLoose.Count -eq 0) {
    Write-Warning "No loose .pw.toml file was found in mods/. The mod may already exist or packwiz may have changed its output."
} else {
    foreach ($file in $createdOrLoose) {
        Write-Host "Created metafile: mods/$($file.Name)"
    }
}

$staleLoose = @(Get-ChildItem -LiteralPath $modsDir -Filter "*.pw.toml" -File -ErrorAction SilentlyContinue)
if ($staleLoose.Count -gt 0) {
    Write-Host "Packwiz metafiles in mods/: $($staleLoose.Count)"
}

$jarMatches = @(Get-ChildItem -LiteralPath $modsDir -Filter "*.jar" -File -ErrorAction SilentlyContinue | Where-Object {
    $_.BaseName -like "*$Slug*"
})

if ($jarMatches.Count -gt 0) {
    Write-Warning "Found possible manual jar files. They are ignored by git/packwiz, but review them locally:"
    $jarMatches | ForEach-Object { Write-Warning "  mods/$($_.Name)" }
}

if ((Test-Path -LiteralPath "$PSScriptRoot\clean-pack-index.ps1") -and (Test-Path -LiteralPath "$PSScriptRoot\update-pack-hash.ps1")) {
    & "$PSScriptRoot\clean-pack-index.ps1"
    & "$PSScriptRoot\update-pack-hash.ps1"
}

Write-Host ""
Write-Host "Done. Next safe step:"
Write-Host "  .\publish-pack.ps1"
