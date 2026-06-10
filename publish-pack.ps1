param(
    [string]$Message = "Update pack"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath "pack.toml") -or -not (Test-Path -LiteralPath "index.toml")) {
    throw "Run this script from the pack repository root, next to pack.toml and index.toml."
}

& "$PSScriptRoot\clean-pack-index.ps1"
& "$PSScriptRoot\update-pack-hash.ps1"

$paths = @(
    ".gitattributes",
    ".nojekyll",
    ".gitignore",
    ".packignore",
    "pack.toml",
    "index.toml",
    "add-modrinth-mod.ps1",
    "clean-pack-index.ps1",
    "update-pack-hash.ps1",
    "publish-pack.ps1",
    "verify-remote-pack.ps1",
    "KasuPackManager.ps1"
)

& git add -- $paths
if ($LASTEXITCODE -ne 0) {
    throw "git add failed."
}

$metafiles = @(Get-ChildItem -LiteralPath "mods/.index" -Filter "*.pw.toml" -File -ErrorAction SilentlyContinue)
if ($metafiles.Count -gt 0) {
    & git add -- ($metafiles | ForEach-Object { $_.FullName })
    if ($LASTEXITCODE -ne 0) {
        throw "git add for mods/.index metafiles failed."
    }
}

& git diff --cached --quiet
if ($LASTEXITCODE -eq 0) {
    Write-Host "No changes to commit. Pack is already up to date."
    exit 0
}

& git commit -m $Message
if ($LASTEXITCODE -ne 0) {
    throw "git commit failed."
}

& git push -u origin master --force
if ($LASTEXITCODE -ne 0) {
    throw "git push failed."
}

Write-Host "Published pack to origin/master."
Write-Host "Next verification step:"
Write-Host "  .\verify-remote-pack.ps1"
