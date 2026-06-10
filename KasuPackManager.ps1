$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptRoot) {
    $scriptRoot = (Get-Location).Path
}

$script:Rows = New-Object System.Collections.ArrayList
$script:Metafiles = @()

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

function Get-TomlValue {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Key
    )

    $escaped = [regex]::Escape($Key)
    $match = [regex]::Match($Text, "(?m)^\s*$escaped\s*=\s*[""']([^""']+)[""']\s*$")
    if ($match.Success) {
        return $match.Groups[1].Value
    }
    return ""
}

function Read-PackMetafiles {
    param([Parameter(Mandatory = $true)][string]$Root)

    $indexDir = Join-Path $Root "mods/.index"
    $items = @()
    if (-not (Test-Path -LiteralPath $indexDir)) {
        return $items
    }

    foreach ($file in (Get-ChildItem -LiteralPath $indexDir -Filter "*.pw.toml" -File | Sort-Object Name)) {
        $text = [System.IO.File]::ReadAllText($file.FullName)
        $items += [pscustomobject]@{
            Path = $file.FullName
            Slug = [System.IO.Path]::GetFileNameWithoutExtension([System.IO.Path]::GetFileNameWithoutExtension($file.Name))
            Filename = Get-TomlValue -Text $text -Key "filename"
            Name = Get-TomlValue -Text $text -Key "name"
            ModId = Get-TomlValue -Text $text -Key "mod-id"
            VersionId = Get-TomlValue -Text $text -Key "version"
            VersionNumber = Get-TomlValue -Text $text -Key "x-prismlauncher-version-number"
        }
    }

    return $items
}

function New-Maps {
    param([object[]]$Metafiles)

    $byFilename = @{}
    $byModVersion = @{}
    $byMod = @{}

    foreach ($meta in $Metafiles) {
        if ($meta.Filename) {
            $byFilename[$meta.Filename.ToLowerInvariant()] = $meta
        }
        if ($meta.ModId -and $meta.VersionId) {
            $byModVersion["$($meta.ModId)|$($meta.VersionId)"] = $meta
        }
        if ($meta.ModId -and -not $byMod.ContainsKey($meta.ModId)) {
            $byMod[$meta.ModId] = $meta
        }
    }

    return [pscustomobject]@{
        ByFilename = $byFilename
        ByModVersion = $byModVersion
        ByMod = $byMod
    }
}

function Invoke-ModrinthGet {
    param([Parameter(Mandatory = $true)][string]$Url)

    $client = New-Object System.Net.WebClient
    try {
        $client.Headers.Set("User-Agent", "KasuPackManager/2.0")
        $json = $client.DownloadString($Url)
        return $json | ConvertFrom-Json
    } finally {
        $client.Dispose()
    }
}

function Get-PrimaryVersionFile {
    param(
        [Parameter(Mandatory = $true)]$Version,
        [Parameter(Mandatory = $true)][string]$Sha1
    )

    $file = @($Version.files | Where-Object { $_.hashes.sha1 -eq $Sha1 } | Select-Object -First 1)
    if (-not $file) {
        $file = @($Version.files | Where-Object { $_.primary } | Select-Object -First 1)
    }
    if (-not $file) {
        $file = @($Version.files | Select-Object -First 1)
    }
    return $file
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

function Sync-VisibleChecks {
    param([System.Windows.Forms.ListView]$List)
    foreach ($item in $List.Items) {
        $item.Tag.Checked = $item.Checked
    }
}

function Set-RowFromVersion {
    param(
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $true)]$Version,
        [Parameter(Mandatory = $true)]$Project,
        [Parameter(Mandatory = $true)]$File,
        [Parameter(Mandatory = $true)]$Maps
    )

    $Row.Project = $Project.title
    $Row.Version = $Version.version_number
    $Row.ModId = $Project.id
    $Row.VersionId = $Version.id
    $Row.ProjectSlug = $Project.slug
    $Row.VersionObject = $Version
    $Row.ProjectObject = $Project
    $Row.FileObject = $File

    $exactKey = "$($Project.id)|$($Version.id)"
    if ($Maps.ByModVersion.ContainsKey($exactKey)) {
        $meta = $Maps.ByModVersion[$exactKey]
        $Row.Status = "tracked"
        $Row.Source = "Modrinth id"
        $Row.Action = "already indexed"
        $Row.Metafile = "mods/.index/$([System.IO.Path]::GetFileName($meta.Path))"
        $Row.Checked = $false
    } elseif ($Maps.ByMod.ContainsKey($Project.id)) {
        $meta = $Maps.ByMod[$Project.id]
        $Row.Status = "different version"
        $Row.Source = "Modrinth id"
        $Row.Action = "will update existing metafile"
        $Row.Metafile = "mods/.index/$([System.IO.Path]::GetFileName($meta.Path))"
        $Row.TargetPath = $meta.Path
        $Row.Checked = $true
    } else {
        $Row.Status = "new"
        $Row.Source = "Modrinth hash"
        $Row.Action = "will create metafile"
        $Row.Metafile = "mods/.index/$($Project.slug).pw.toml"
        $Row.TargetPath = ""
        $Row.Checked = $true
    }
}

function Recognize-Row {
    param(
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $true)]$Maps
    )

    if ($Row.Status -eq "tracked" -and $Row.Source -eq "filename") {
        return
    }

    $sha1 = (Get-FileHash -LiteralPath $Row.JarPath -Algorithm SHA1).Hash.ToLowerInvariant()
    $Row.Sha1 = $sha1

    try {
        $version = Invoke-ModrinthGet -Url "https://api.modrinth.com/v2/version_file/$sha1?algorithm=sha1"
        $project = Invoke-ModrinthGet -Url "https://api.modrinth.com/v2/project/$($version.project_id)"
        $file = Get-PrimaryVersionFile -Version $version -Sha1 $sha1
        Set-RowFromVersion -Row $Row -Version $version -Project $project -File $file -Maps $Maps
    } catch {
        $Row.Status = "not recognized"
        $Row.Source = "local jar"
        $Row.Project = ""
        $Row.Version = ""
        $Row.Action = "not found on Modrinth"
        $Row.Checked = $false
    }
}

function Apply-Filter {
    param(
        [System.Windows.Forms.ListView]$List,
        [System.Windows.Forms.TextBox]$SearchBox,
        [System.Windows.Forms.ComboBox]$FilterBox
    )

    Sync-VisibleChecks -List $List
    $query = $SearchBox.Text.Trim().ToLowerInvariant()
    $filter = [string]$FilterBox.SelectedItem

    $List.BeginUpdate()
    $List.Items.Clear()

    foreach ($row in $script:Rows) {
        $visible = $true
        if ($query) {
            $haystack = "$($row.Jar) $($row.Status) $($row.Project) $($row.Version) $($row.Action)".ToLowerInvariant()
            $visible = $haystack.Contains($query)
        }
        if ($visible -and $filter -and $filter -ne "All") {
            if ($filter -eq "Needs action") {
                $visible = @("new", "different version", "unknown") -contains $row.Status
            } else {
                $visible = $row.Status -eq $filter.ToLowerInvariant()
            }
        }
        if (-not $visible) {
            continue
        }

        $item = New-Object System.Windows.Forms.ListViewItem($row.Jar)
        [void]$item.SubItems.Add($row.Status)
        [void]$item.SubItems.Add($row.Source)
        [void]$item.SubItems.Add($row.Project)
        [void]$item.SubItems.Add($row.Version)
        [void]$item.SubItems.Add($row.Action)
        [void]$item.SubItems.Add($row.Metafile)
        $item.Checked = [bool]$row.Checked
        $item.Tag = $row
        [void]$List.Items.Add($item)
    }

    $List.EndUpdate()
}

function Build-Rows {
    param([Parameter(Mandatory = $true)][string]$Root)

    $modsDir = Join-Path $Root "mods"
    if (-not (Test-Path -LiteralPath (Join-Path $Root "pack.toml"))) {
        throw "pack.toml not found in selected root."
    }
    if (-not (Test-Path -LiteralPath $modsDir)) {
        throw "mods folder not found."
    }

    $script:Metafiles = @(Read-PackMetafiles -Root $Root)
    $maps = New-Maps -Metafiles $script:Metafiles
    $script:Rows.Clear()

    $jars = @(Get-ChildItem -LiteralPath $modsDir -Filter "*.jar" -File | Sort-Object Name)
    foreach ($jar in $jars) {
        $key = $jar.Name.ToLowerInvariant()
        $row = [pscustomobject]@{
            Checked = $true
            Jar = $jar.Name
            JarPath = $jar.FullName
            Status = "unknown"
            Source = "local jar"
            Project = ""
            Version = ""
            Action = "recognize or select"
            Metafile = ""
            TargetPath = ""
            Sha1 = ""
            ModId = ""
            VersionId = ""
            ProjectSlug = ""
            VersionObject = $null
            ProjectObject = $null
            FileObject = $null
        }

        if ($maps.ByFilename.ContainsKey($key)) {
            $meta = $maps.ByFilename[$key]
            $row.Checked = $false
            $row.Status = "tracked"
            $row.Source = "filename"
            $row.Project = $meta.Name
            $row.Version = $meta.VersionNumber
            $row.Action = "already indexed"
            $row.Metafile = "mods/.index/$([System.IO.Path]::GetFileName($meta.Path))"
        }

        [void]$script:Rows.Add($row)
    }

    return [pscustomobject]@{
        JarCount = $jars.Count
        MetaCount = $script:Metafiles.Count
    }
}

function Get-VisibleRows {
    param([System.Windows.Forms.ListView]$List)
    Sync-VisibleChecks -List $List
    $rows = @()
    foreach ($item in $List.Items) {
        $rows += $item.Tag
    }
    return $rows
}

function Get-CheckedRows {
    param([System.Windows.Forms.ListView]$List)
    Sync-VisibleChecks -List $List
    return @($script:Rows | Where-Object { $_.Checked })
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "KasuPack Manager"
$form.Size = New-Object System.Drawing.Size(1220, 760)
$form.StartPosition = "CenterScreen"

$rootLabel = New-Object System.Windows.Forms.Label
$rootLabel.Text = "Pack root"
$rootLabel.Location = New-Object System.Drawing.Point(12, 16)
$rootLabel.Size = New-Object System.Drawing.Size(70, 22)
$form.Controls.Add($rootLabel)

$rootBox = New-Object System.Windows.Forms.TextBox
$rootBox.Location = New-Object System.Drawing.Point(84, 12)
$rootBox.Size = New-Object System.Drawing.Size(900, 24)
$rootBox.Text = $scriptRoot
$form.Controls.Add($rootBox)

$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Text = "Browse"
$browseButton.Location = New-Object System.Drawing.Point(994, 10)
$browseButton.Size = New-Object System.Drawing.Size(80, 28)
$form.Controls.Add($browseButton)

$scanButton = New-Object System.Windows.Forms.Button
$scanButton.Text = "Scan"
$scanButton.Location = New-Object System.Drawing.Point(12, 48)
$scanButton.Size = New-Object System.Drawing.Size(80, 30)
$form.Controls.Add($scanButton)

$recognizeButton = New-Object System.Windows.Forms.Button
$recognizeButton.Text = "Recognize visible"
$recognizeButton.Location = New-Object System.Drawing.Point(102, 48)
$recognizeButton.Size = New-Object System.Drawing.Size(130, 30)
$form.Controls.Add($recognizeButton)

$addButton = New-Object System.Windows.Forms.Button
$addButton.Text = "Add/update selected"
$addButton.Location = New-Object System.Drawing.Point(242, 48)
$addButton.Size = New-Object System.Drawing.Size(145, 30)
$form.Controls.Add($addButton)

$selectNeedsButton = New-Object System.Windows.Forms.Button
$selectNeedsButton.Text = "Select action"
$selectNeedsButton.Location = New-Object System.Drawing.Point(397, 48)
$selectNeedsButton.Size = New-Object System.Drawing.Size(105, 30)
$form.Controls.Add($selectNeedsButton)

$selectVisibleButton = New-Object System.Windows.Forms.Button
$selectVisibleButton.Text = "Select visible"
$selectVisibleButton.Location = New-Object System.Drawing.Point(512, 48)
$selectVisibleButton.Size = New-Object System.Drawing.Size(105, 30)
$form.Controls.Add($selectVisibleButton)

$clearButton = New-Object System.Windows.Forms.Button
$clearButton.Text = "Clear"
$clearButton.Location = New-Object System.Drawing.Point(627, 48)
$clearButton.Size = New-Object System.Drawing.Size(75, 30)
$form.Controls.Add($clearButton)

$publishButton = New-Object System.Windows.Forms.Button
$publishButton.Text = "Publish"
$publishButton.Location = New-Object System.Drawing.Point(712, 48)
$publishButton.Size = New-Object System.Drawing.Size(90, 30)
$form.Controls.Add($publishButton)

$verifyButton = New-Object System.Windows.Forms.Button
$verifyButton.Text = "Verify"
$verifyButton.Location = New-Object System.Drawing.Point(812, 48)
$verifyButton.Size = New-Object System.Drawing.Size(80, 30)
$form.Controls.Add($verifyButton)

$searchLabel = New-Object System.Windows.Forms.Label
$searchLabel.Text = "Search"
$searchLabel.Location = New-Object System.Drawing.Point(12, 91)
$searchLabel.Size = New-Object System.Drawing.Size(55, 22)
$form.Controls.Add($searchLabel)

$searchBox = New-Object System.Windows.Forms.TextBox
$searchBox.Location = New-Object System.Drawing.Point(70, 88)
$searchBox.Size = New-Object System.Drawing.Size(360, 24)
$form.Controls.Add($searchBox)

$filterLabel = New-Object System.Windows.Forms.Label
$filterLabel.Text = "Filter"
$filterLabel.Location = New-Object System.Drawing.Point(444, 91)
$filterLabel.Size = New-Object System.Drawing.Size(45, 22)
$form.Controls.Add($filterLabel)

$filterBox = New-Object System.Windows.Forms.ComboBox
$filterBox.Location = New-Object System.Drawing.Point(490, 88)
$filterBox.Size = New-Object System.Drawing.Size(180, 24)
$filterBox.DropDownStyle = "DropDownList"
[void]$filterBox.Items.Add("All")
[void]$filterBox.Items.Add("Needs action")
[void]$filterBox.Items.Add("tracked")
[void]$filterBox.Items.Add("new")
[void]$filterBox.Items.Add("different version")
[void]$filterBox.Items.Add("unknown")
[void]$filterBox.Items.Add("not recognized")
$filterBox.SelectedIndex = 0
$form.Controls.Add($filterBox)

$summaryLabel = New-Object System.Windows.Forms.Label
$summaryLabel.Text = "No scan yet"
$summaryLabel.Location = New-Object System.Drawing.Point(690, 91)
$summaryLabel.Size = New-Object System.Drawing.Size(500, 22)
$form.Controls.Add($summaryLabel)

$list = New-Object System.Windows.Forms.ListView
$list.Location = New-Object System.Drawing.Point(12, 122)
$list.Size = New-Object System.Drawing.Size(1180, 405)
$list.View = "Details"
$list.CheckBoxes = $true
$list.FullRowSelect = $true
$list.GridLines = $true
[void]$list.Columns.Add("Jar", 280)
[void]$list.Columns.Add("Status", 110)
[void]$list.Columns.Add("Source", 110)
[void]$list.Columns.Add("Project", 190)
[void]$list.Columns.Add("Version", 120)
[void]$list.Columns.Add("Action", 170)
[void]$list.Columns.Add("Metafile", 190)
$form.Controls.Add($list)

$log = New-Object System.Windows.Forms.TextBox
$log.Location = New-Object System.Drawing.Point(12, 540)
$log.Size = New-Object System.Drawing.Size(1180, 165)
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
        $result = Build-Rows -Root $rootBox.Text.Trim()
        Apply-Filter -List $list -SearchBox $searchBox -FilterBox $filterBox
        $tracked = @($script:Rows | Where-Object { $_.Status -eq "tracked" }).Count
        $unknown = @($script:Rows | Where-Object { $_.Status -eq "unknown" }).Count
        $summaryLabel.Text = "Jars: $($result.JarCount) | Metafiles: $($result.MetaCount) | Tracked: $tracked | Unknown: $unknown"
        $log.AppendText("Scan complete. Read $($result.MetaCount) metafiles and $($result.JarCount) jars." + [Environment]::NewLine)
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Scan failed", "OK", "Error") | Out-Null
    }
})

$recognizeButton.Add_Click({
    try {
        $root = $rootBox.Text.Trim()
        $maps = New-Maps -Metafiles @(Read-PackMetafiles -Root $root)
        $rows = @(Get-VisibleRows -List $list | Where-Object { $_.Status -ne "tracked" })
        foreach ($row in $rows) {
            $log.AppendText("Recognizing $($row.Jar)..." + [Environment]::NewLine)
            Recognize-Row -Row $row -Maps $maps
            $log.AppendText("  $($row.Status): $($row.Project) $($row.Version)" + [Environment]::NewLine)
            [System.Windows.Forms.Application]::DoEvents()
        }
        Apply-Filter -List $list -SearchBox $searchBox -FilterBox $filterBox
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Recognition failed", "OK", "Error") | Out-Null
    }
})

$addButton.Add_Click({
    try {
        $root = $rootBox.Text.Trim()
        $indexDir = Join-Path $root "mods/.index"
        New-Item -ItemType Directory -Force -Path $indexDir | Out-Null

        $maps = New-Maps -Metafiles @(Read-PackMetafiles -Root $root)
        $rows = @(Get-CheckedRows -List $list)
        if ($rows.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Select at least one row first.", "Nothing selected", "OK", "Information") | Out-Null
            return
        }

        foreach ($row in $rows) {
            if (-not $row.FileObject) {
                $log.AppendText("Recognizing $($row.Jar) before writing..." + [Environment]::NewLine)
                Recognize-Row -Row $row -Maps $maps
            }
            if ($row.Status -notin @("new", "different version")) {
                $log.AppendText("Skipping $($row.Jar): $($row.Status)." + [Environment]::NewLine)
                continue
            }

            $target = $row.TargetPath
            if (-not $target) {
                $target = Join-Path $indexDir "$($row.ProjectSlug).pw.toml"
            }

            New-ModrinthMetafile -Version $row.VersionObject -Project $row.ProjectObject -File $row.FileObject -TargetPath $target
            $row.Status = "tracked"
            $row.Source = "written"
            $row.Action = "metafile written"
            $row.Metafile = "mods/.index/$([System.IO.Path]::GetFileName($target))"
            $row.Checked = $false
            $log.AppendText("Wrote $($row.Metafile)" + [Environment]::NewLine)
        }

        Run-ProcessCapture -FileName "powershell.exe" -Arguments "-NoProfile -ExecutionPolicy Bypass -File `"$root\clean-pack-index.ps1`"" -WorkingDirectory $root -Log $log
        Run-ProcessCapture -FileName "powershell.exe" -Arguments "-NoProfile -ExecutionPolicy Bypass -File `"$root\update-pack-hash.ps1`"" -WorkingDirectory $root -Log $log
        Apply-Filter -List $list -SearchBox $searchBox -FilterBox $filterBox
        $log.AppendText("Pack prepared locally. Publish when ready." + [Environment]::NewLine)
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Add/update failed", "OK", "Error") | Out-Null
    }
})

$selectNeedsButton.Add_Click({
    Sync-VisibleChecks -List $list
    foreach ($row in $script:Rows) {
        $row.Checked = @("new", "different version", "unknown") -contains $row.Status
    }
    Apply-Filter -List $list -SearchBox $searchBox -FilterBox $filterBox
})

$selectVisibleButton.Add_Click({
    foreach ($item in $list.Items) {
        $item.Tag.Checked = $true
    }
    Apply-Filter -List $list -SearchBox $searchBox -FilterBox $filterBox
})

$clearButton.Add_Click({
    foreach ($row in $script:Rows) {
        $row.Checked = $false
    }
    Apply-Filter -List $list -SearchBox $searchBox -FilterBox $filterBox
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

$searchBox.Add_TextChanged({
    Apply-Filter -List $list -SearchBox $searchBox -FilterBox $filterBox
})

$filterBox.Add_SelectedIndexChanged({
    Apply-Filter -List $list -SearchBox $searchBox -FilterBox $filterBox
})

[void]$form.ShowDialog()
