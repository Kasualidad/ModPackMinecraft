param(
    [string]$BaseUrl = "https://kasualidad.github.io/ModPackMinecraft"
)

$ErrorActionPreference = "Stop"

function Get-RemoteBytes {
    param([Parameter(Mandatory = $true)][string]$Url)

    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        Invoke-WebRequest -Uri $Url -OutFile $tempFile -UseBasicParsing -Headers @{
            "Cache-Control" = "no-cache"
            "Pragma" = "no-cache"
        } | Out-Null
        return [System.IO.File]::ReadAllBytes($tempFile)
    } finally {
        if (Test-Path -LiteralPath $tempFile) {
            Remove-Item -LiteralPath $tempFile -Force
        }
    }
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash($Bytes)
        return (($hashBytes | ForEach-Object { $_.ToString("x2") }) -join "")
    } finally {
        $sha.Dispose()
    }
}

$cacheBuster = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$packUrl = "$BaseUrl/pack.toml?v=$cacheBuster"
$indexUrl = "$BaseUrl/index.toml?v=$cacheBuster"

Write-Host "Downloading:"
Write-Host "  $packUrl"
Write-Host "  $indexUrl"

$packBytes = Get-RemoteBytes -Url $packUrl
$indexBytes = Get-RemoteBytes -Url $indexUrl

$packText = [System.Text.Encoding]::UTF8.GetString($packBytes)
$match = [regex]::Match($packText, '(?ms)\[index\].*?hash\s*=\s*"([a-fA-F0-9]{64})"')
if (-not $match.Success) {
    throw "Could not extract the [index] hash from remote pack.toml."
}

$packHash = $match.Groups[1].Value.ToLowerInvariant()
$actualHash = Get-Sha256Hex -Bytes $indexBytes

if ($packHash -eq $actualHash) {
    Write-Host "OK: remote index.toml hash matches pack.toml."
    Write-Host "  $actualHash"
    exit 0
}

Write-Host "ERROR: remote index.toml hash does not match pack.toml."
Write-Host "  pack.toml hash:  $packHash"
Write-Host "  index.toml hash: $actualHash"
exit 1
