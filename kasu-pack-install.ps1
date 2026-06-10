param(
    [string]$PackUrl = "https://kasualidad.github.io/ModPackMinecraft/pack.toml"
)

$ErrorActionPreference = "Stop"

function Write-Step([string]$Message) {
    Write-Host "[KasuPack] $Message"
}

function Get-RemoteBytes([string]$Url) {
    $request = [System.Net.WebRequest]::Create($Url)
    $request.UserAgent = "KasuPackInstaller/1.0"
    $response = $request.GetResponse()
    try {
        $stream = $response.GetResponseStream()
        $memory = New-Object System.IO.MemoryStream
        $stream.CopyTo($memory)
        $memory.ToArray()
    }
    finally {
        $response.Dispose()
    }
}

function Get-RemoteText([string]$Url) {
    [Text.Encoding]::UTF8.GetString((Get-RemoteBytes $Url))
}

function Get-TomlValue([string]$Text, [string]$Key) {
    $pattern = '(?m)^' + [regex]::Escape($Key) + '\s*=\s*[''\"](.+?)[''\"]'
    $match = [regex]::Match($Text, $pattern)
    if ($match.Success) { return $match.Groups[1].Value }
    return $null
}

function Get-HashHex([string]$Path, [string]$Format) {
    $algorithm = switch ($Format.ToLowerInvariant()) {
        "sha1" { "SHA1" }
        "sha256" { "SHA256" }
        "sha512" { "SHA512" }
        default { throw "Formato de hash no soportado: $Format" }
    }
    (Get-FileHash -Algorithm $algorithm -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Join-PackUrl([string]$BaseUrl, [string]$RelativePath) {
    $base = $BaseUrl.Substring(0, $BaseUrl.LastIndexOf('/') + 1)
    $encoded = (($RelativePath -split '/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    "$base$encoded"
}

function Get-CurseForgeDownloadUrl([string]$FileId, [string]$Filename) {
    $id = [int64]$FileId
    $first = [Math]::Floor($id / 1000)
    $last = ($id % 1000).ToString('000')
    $encodedName = [Uri]::EscapeDataString($Filename)
    "https://edge.forgecdn.net/files/$first/$last/$encodedName"
}

function Save-RemoteFile([string]$Url, [string]$TargetPath) {
    $tmp = "$TargetPath.tmp"
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    $bytes = Get-RemoteBytes $Url
    [IO.File]::WriteAllBytes($tmp, $bytes)
    Move-Item -LiteralPath $tmp -Destination $TargetPath -Force
}

$root = (Get-Location).Path
$modsDir = Join-Path $root "mods"
if (!(Test-Path -LiteralPath $modsDir)) {
    New-Item -ItemType Directory -Path $modsDir | Out-Null
}

$cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
Write-Step "Leyendo pack remoto"
$packText = Get-RemoteText "$PackUrl`?v=$cacheBust"
$indexFile = Get-TomlValue $packText "file"
if ([string]::IsNullOrWhiteSpace($indexFile)) { $indexFile = "index.toml" }
$indexUrl = Join-PackUrl $PackUrl $indexFile
$indexText = Get-RemoteText "$indexUrl`?v=$cacheBust"
$metafiles = @([regex]::Matches($indexText, 'file\s*=\s*"([^"]+\.pw\.toml)"') | ForEach-Object { $_.Groups[1].Value })
if ($metafiles.Count -eq 0) { throw "No se encontraron mods .pw.toml en index.toml" }

$expected = New-Object System.Collections.Generic.HashSet[string]
$downloaded = 0
$ok = 0
$errors = New-Object System.Collections.Generic.List[string]

foreach ($meta in $metafiles) {
    $metaUrl = Join-PackUrl $PackUrl $meta
    $metaText = Get-RemoteText "$metaUrl`?v=$cacheBust"
    $filename = Get-TomlValue $metaText "filename"
    $hash = Get-TomlValue $metaText "hash"
    $hashFormat = Get-TomlValue $metaText "hash-format"
    $mode = Get-TomlValue $metaText "mode"
    $url = Get-TomlValue $metaText "url"
    $fileId = Get-TomlValue $metaText "file-id"

    if ([string]::IsNullOrWhiteSpace($filename)) {
        $errors.Add("Sin filename: $meta")
        continue
    }

    [void]$expected.Add($filename)
    $target = Join-Path $modsDir $filename

    if ([string]::IsNullOrWhiteSpace($url) -and $mode -eq "metadata:curseforge" -and $fileId) {
        $url = Get-CurseForgeDownloadUrl $fileId $filename
    }

    if ([string]::IsNullOrWhiteSpace($url)) {
        if ((Test-Path -LiteralPath $target) -and ((Get-Item -LiteralPath $target).Length -gt 0)) {
            $ok++
        }
        else {
            $errors.Add("No puedo descargar y falta el jar: $filename")
        }
        continue
    }

    $needsDownload = $true
    if ((Test-Path -LiteralPath $target) -and ((Get-Item -LiteralPath $target).Length -gt 0) -and $hash -and $hashFormat) {
        try {
            if ((Get-HashHex $target $hashFormat) -eq $hash.ToLowerInvariant()) {
                $needsDownload = $false
                $ok++
            }
        }
        catch {
            $needsDownload = $true
        }
    }

    if ($needsDownload) {
        Write-Step "Descargando $filename"
        Save-RemoteFile $url $target
        if ((Get-Item -LiteralPath $target).Length -eq 0) {
            $errors.Add("Descarga vacia: $filename")
            continue
        }
        if ($hash -and $hashFormat) {
            $actual = Get-HashHex $target $hashFormat
            if ($actual -ne $hash.ToLowerInvariant()) {
                $errors.Add("Hash incorrecto: $filename")
                continue
            }
        }
        $downloaded++
    }
}

Get-ChildItem -LiteralPath $modsDir -File -Filter "*.pw.toml" -ErrorAction SilentlyContinue | Remove-Item -Force
Get-ChildItem -LiteralPath $modsDir -File -Filter "*.jar" | Where-Object { $_.Length -eq 0 } | Remove-Item -Force

if ($errors.Count -gt 0) {
    Write-Step "ERROR"
    $errors | ForEach-Object { Write-Host "  $_" }
    exit 1
}

Write-Step "OK: $($metafiles.Count) mods revisados, $downloaded descargados, $ok ya estaban bien."
