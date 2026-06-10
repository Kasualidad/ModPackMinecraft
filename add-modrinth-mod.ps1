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
$indexDir = Join-Path $modsDir ".index"
New-Item -ItemType Directory -Force -Path $indexDir | Out-Null

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

$allLoose = @(Get-ChildItem -LiteralPath $modsDir -Filter "*.pw.toml" -File)
if ($allLoose.Count -gt $createdOrLoose.Count) {
    $createdOrLoose = @($createdOrLoose + ($allLoose | Where-Object { $createdOrLoose.FullName -notcontains $_.FullName }) | Sort-Object FullName -Unique)
}

if ($createdOrLoose.Count -eq 0) {
    Write-Warning "No loose .pw.toml file was found in mods/. The mod may already exist or packwiz may have changed its output."
} else {
    foreach ($file in $createdOrLoose) {
        $target = Join-Path $indexDir $file.Name
        if (Test-Path -LiteralPath $target) {
            $sourceHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
            $targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
            if ($sourceHash -ne $targetHash) {
                throw "Target already exists with different content: $target"
            }
            Remove-Item -LiteralPath $file.FullName -Force
            Write-Host "Removed duplicate loose metafile: mods/$($file.Name)"
        } else {
            Move-Item -LiteralPath $file.FullName -Destination $target
            Write-Host "Moved metafile to: mods/.index/$($file.Name)"
        }
    }
}

$jarMatches = @(Get-ChildItem -LiteralPath $modsDir -Filter "*.jar" -File -ErrorAction SilentlyContinue | Where-Object {
    $_.BaseName -like "*$Slug*"
})

if ($jarMatches.Count -gt 0) {
    Write-Warning "Found possible manual jar files. They are ignored by git/packwiz, but review them locally:"
    $jarMatches | ForEach-Object { Write-Warning "  mods/$($_.Name)" }
}

Write-Host ""
Write-Host "Done. Next safe step:"
Write-Host "  .\publish-pack.ps1"
