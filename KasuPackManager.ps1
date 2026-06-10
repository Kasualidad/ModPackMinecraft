$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptRoot) {
    $scriptRoot = (Get-Location).Path
}

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
    [System.IO.File]::WriteAllText($Path, $normalized, $encoding)
}

function Escape-Toml {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return "" }
    return ($Value -replace "\\", "\\" -replace '"', '\"')
}

function Invoke-ModrinthGet {
    param([Parameter(Mandatory = $true)][string]$Url)

    $client = New-Object System.Net.WebClient
    try {
        $client.Headers.Set("User-Agent", "KasuPackManager/1.0")
        $json = $client.DownloadString($Url)
        return $json | ConvertFrom-Json
    } finally {
        $client.Dispose()
    }
}

function Get-IndexedByFilename {
    param([Parameter(Mandatory = $true)][string]$Root)

    $map = @{}
    $indexDir = Join-Path $Root "mods/.index"
    if (-not (Test-Path -LiteralPath $indexDir)) {
        return $map
    }

    Get-ChildItem -LiteralPath $indexDir -Filter "*.pw.toml" -File | ForEach-Object {
        $text = [System.IO.File]::ReadAllText($_.FullName)
        $match = [regex]::Match($text, '(?m)^\s*filename\s*=\s*["'']([^"'']+)["'']\s*$')
        if ($match.Success) {
            $map[$match.Groups[1].Value] = $_.FullName
        }
    }
    return $map
}

function Get-SelectedItems {
    param([System.Windows.Forms.ListView]$List)
    $items = New-Object System.Collections.Generic.List[System.Windows.Forms.ListViewItem]
    foreach ($item in $List.Items) {
        if ($item.Checked) {
            $items.Add($item)
        }
    }
    return $items
}

function Run-ProcessCapture {
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][System.Windows.Forms.TextBox]$Log
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.Arguments = $Arguments
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    if ($stdout) { $Log.AppendText($stdout + [Environment]::NewLine) }
    if ($stderr) { $Log.AppendText($stderr + [Environment]::NewLine) }
    if ($process.ExitCode -ne 0) {
        throw "$FileName failed with exit code $($process.ExitCode)."
    }
}

function New-ModrinthMetafile {
    param(
        [Parameter(Mandatory = $true)]$Version,
        [Parameter(Mandatory = $true)]$Project,
        [Parameter(Mandatory = $true)]$File,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    $sha512 = $File.hashes.sha512
    if (-not $sha512) {
        throw "Modrinth did not return a sha512 hash for $($File.filename)."
    }

    $name = Escape-Toml $Project.title
    $filename = Escape-Toml $File.filename
    $url = Escape-Toml $File.url
    $projectId = Escape-Toml $Project.id
    $versionId = Escape-Toml $Version.id
    $versionNumber = Escape-Toml $Version.version_number
    $releaseType = Escape-Toml $Version.version_type

    $content = @"
filename = "$filename"
name = "$name"
side = "both"
x-prismlauncher-loaders = [ "forge" ]
x-prismlauncher-mc-versions = [ "1.20.1" ]
x-prismlauncher-release-type = "$releaseType"
x-prismlauncher-version-number = "$versionNumber"

[download]
hash = "$sha512"
hash-format = "sha512"
mode = "url"
url = "$url"

[update.modrinth]
mod-id = "$projectId"
version = "$versionId"
"@

    Write-Utf8NoBomLf -Path $TargetPath -Content $content
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "KasuPack Manager"
$form.Size = New-Object System.Drawing.Size(1040, 720)
$form.StartPosition = "CenterScreen"

$rootLabel = New-Object System.Windows.Forms.Label
$rootLabel.Text = "Pack root"
$rootLabel.Location = New-Object System.Drawing.Point(12, 16)
$rootLabel.Size = New-Object System.Drawing.Size(70, 22)
$form.Controls.Add($rootLabel)

$rootBox = New-Object System.Windows.Forms.TextBox
$rootBox.Location = New-Object System.Drawing.Point(84, 12)
$rootBox.Size = New-Object System.Drawing.Size(760, 24)
$rootBox.Text = $scriptRoot
$form.Controls.Add($rootBox)

$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Text = "Browse"
$browseButton.Location = New-Object System.Drawing.Point(854, 10)
$browseButton.Size = New-Object System.Drawing.Size(76, 28)
$form.Controls.Add($browseButton)

$scanButton = New-Object System.Windows.Forms.Button
$scanButton.Text = "Scan mods"
$scanButton.Location = New-Object System.Drawing.Point(12, 48)
$scanButton.Size = New-Object System.Drawing.Size(110, 30)
$form.Controls.Add($scanButton)

$recognizeButton = New-Object System.Windows.Forms.Button
$recognizeButton.Text = "Add selected jars"
$recognizeButton.Location = New-Object System.Drawing.Point(132, 48)
$recognizeButton.Size = New-Object System.Drawing.Size(130, 30)
$form.Controls.Add($recognizeButton)

$publishButton = New-Object System.Windows.Forms.Button
$publishButton.Text = "Publish to GitHub"
$publishButton.Location = New-Object System.Drawing.Point(272, 48)
$publishButton.Size = New-Object System.Drawing.Size(130, 30)
$form.Controls.Add($publishButton)

$verifyButton = New-Object System.Windows.Forms.Button
$verifyButton.Text = "Verify remote"
$verifyButton.Location = New-Object System.Drawing.Point(412, 48)
$verifyButton.Size = New-Object System.Drawing.Size(120, 30)
$form.Controls.Add($verifyButton)

$list = New-Object System.Windows.Forms.ListView
$list.Location = New-Object System.Drawing.Point(12, 90)
$list.Size = New-Object System.Drawing.Size(1000, 390)
$list.View = "Details"
$list.CheckBoxes = $true
$list.FullRowSelect = $true
$list.GridLines = $true
[void]$list.Columns.Add("Jar", 320)
[void]$list.Columns.Add("Status", 120)
[void]$list.Columns.Add("Project", 220)
[void]$list.Columns.Add("Version", 120)
[void]$list.Columns.Add("Action", 180)
$form.Controls.Add($list)

$log = New-Object System.Windows.Forms.TextBox
$log.Location = New-Object System.Drawing.Point(12, 492)
$log.Size = New-Object System.Drawing.Size(1000, 175)
$log.Multiline = $true
$log.ScrollBars = "Vertical"
$log.ReadOnly = $true
$form.Controls.Add($log)

$browseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.SelectedPath = $rootBox.Text
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $rootBox.Text = $dialog.SelectedPath
    }
})

$scanButton.Add_Click({
    try {
        $root = $rootBox.Text.Trim()
        $modsDir = Join-Path $root "mods"
        if (-not (Test-Path -LiteralPath (Join-Path $root "pack.toml"))) {
            throw "pack.toml not found in selected root."
        }
        if (-not (Test-Path -LiteralPath $modsDir)) {
            throw "mods folder not found."
        }

        $list.Items.Clear()
        $indexed = Get-IndexedByFilename -Root $root
        $jars = @(Get-ChildItem -LiteralPath $modsDir -Filter "*.jar" -File | Sort-Object Name)

        foreach ($jar in $jars) {
            $status = "new"
            $action = "select to add"
            $checked = $true
            if ($indexed.ContainsKey($jar.Name)) {
                $status = "tracked"
                $action = "already indexed"
                $checked = $false
            }

            $item = New-Object System.Windows.Forms.ListViewItem($jar.Name)
            [void]$item.SubItems.Add($status)
            [void]$item.SubItems.Add("")
            [void]$item.SubItems.Add("")
            [void]$item.SubItems.Add($action)
            $item.Checked = $checked
            $item.Tag = [pscustomobject]@{ Path = $jar.FullName; Name = $jar.Name; Status = $status }
            [void]$list.Items.Add($item)
        }

        $log.AppendText("Scanned $($jars.Count) jar files." + [Environment]::NewLine)
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Scan failed", "OK", "Error") | Out-Null
    }
})

$recognizeButton.Add_Click({
    try {
        $root = $rootBox.Text.Trim()
        $indexDir = Join-Path $root "mods/.index"
        New-Item -ItemType Directory -Force -Path $indexDir | Out-Null

        $selected = Get-SelectedItems -List $list
        if ($selected.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Select one or more new jar files first.", "Nothing selected", "OK", "Information") | Out-Null
            return
        }

        foreach ($item in $selected) {
            $jarPath = $item.Tag.Path
            $sha1 = (Get-FileHash -LiteralPath $jarPath -Algorithm SHA1).Hash.ToLowerInvariant()
            $log.AppendText("Recognizing $($item.Tag.Name)..." + [Environment]::NewLine)

            try {
                $version = Invoke-ModrinthGet -Url "https://api.modrinth.com/v2/version_file/$sha1?algorithm=sha1"
                $project = Invoke-ModrinthGet -Url "https://api.modrinth.com/v2/project/$($version.project_id)"
                $file = @($version.files | Where-Object { $_.hashes.sha1 -eq $sha1 } | Select-Object -First 1)
                if (-not $file) {
                    $file = @($version.files | Where-Object { $_.primary } | Select-Object -First 1)
                }
                if (-not $file) {
                    $file = @($version.files | Select-Object -First 1)
                }

                $slug = $project.slug
                $targetPath = Join-Path $indexDir "$slug.pw.toml"
                New-ModrinthMetafile -Version $version -Project $project -File $file -TargetPath $targetPath

                $item.SubItems[1].Text = "indexed"
                $item.SubItems[2].Text = $project.title
                $item.SubItems[3].Text = $version.version_number
                $item.SubItems[4].Text = "wrote mods/.index/$slug.pw.toml"
                $item.Checked = $false
                $log.AppendText("Wrote mods/.index/$slug.pw.toml" + [Environment]::NewLine)
            } catch {
                $item.SubItems[1].Text = "not found"
                $item.SubItems[4].Text = "not recognized on Modrinth"
                $log.AppendText("Could not recognize $($item.Tag.Name): $($_.Exception.Message)" + [Environment]::NewLine)
            }
        }

        Run-ProcessCapture -FileName "powershell.exe" -Arguments "-NoProfile -ExecutionPolicy Bypass -File `"$root\clean-pack-index.ps1`"" -WorkingDirectory $root -Log $log
        Run-ProcessCapture -FileName "powershell.exe" -Arguments "-NoProfile -ExecutionPolicy Bypass -File `"$root\update-pack-hash.ps1`"" -WorkingDirectory $root -Log $log
        $log.AppendText("Prepared pack locally. Use Publish to GitHub when ready." + [Environment]::NewLine)
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Add failed", "OK", "Error") | Out-Null
    }
})

$publishButton.Add_Click({
    try {
        $root = $rootBox.Text.Trim()
        $answer = [System.Windows.Forms.MessageBox]::Show("This will commit and push to origin/master. Continue?", "Publish", "YesNo", "Question")
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            return
        }
        Run-ProcessCapture -FileName "powershell.exe" -Arguments "-NoProfile -ExecutionPolicy Bypass -File `"$root\publish-pack.ps1`"" -WorkingDirectory $root -Log $log
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Publish failed", "OK", "Error") | Out-Null
    }
})

$verifyButton.Add_Click({
    try {
        $root = $rootBox.Text.Trim()
        Run-ProcessCapture -FileName "powershell.exe" -Arguments "-NoProfile -ExecutionPolicy Bypass -File `"$root\verify-remote-pack.ps1`"" -WorkingDirectory $root -Log $log
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Verify failed", "OK", "Error") | Out-Null
    }
})

[void]$form.ShowDialog()
