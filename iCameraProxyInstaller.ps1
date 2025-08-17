#requires -Version 5.1
<#!
 iCamera Proxy Installer (Config-driven)
 Modes:
   - Interactive (default)
   - --quiet (unattended)
   - --uninstall (remove)
 Exit codes: 0 success, 1 general failure, 2 insufficient privileges (elevation denied), 3 another installer instance is running

 Primary constraint: All behavior driven by installer.config.json; avoid hardcoded product values.
!#>

param(
    [switch]$quiet,
    [switch]$uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================
# Globals & Utilities
# =============================
$script:BaseDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($PSCommandPath) { Split-Path -Path $PSCommandPath -Parent } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Path $MyInvocation.MyCommand.Path -Parent } else { (Get-Location).Path }

# Ensure FFmpeg layout is <Root>\bin\ffmpeg.exe. If extraction created a nested version folder, flatten it.
function Normalize-FfmpegLayout {
    param([Parameter(Mandatory=$true)][string]$Root)
    try {
        $exe = Join-Path $Root 'bin\ffmpeg.exe'
        if (Test-Path -LiteralPath $exe) { return }
        # look for a single top-level folder that contains bin\ffmpeg.exe
        $topDirs = Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue
        if ($topDirs.Count -eq 1) {
            $inner = $topDirs[0].FullName
            $innerExe = Join-Path $inner 'bin\ffmpeg.exe'
            if (Test-Path -LiteralPath $innerExe) {
                Write-Log INFO ("Normalizing FFmpeg layout by flattening '{0}' into '{1}'" -f $inner, $Root)
                Get-ChildItem -LiteralPath $inner -Force | ForEach-Object {
                    $dest = Join-Path $Root $_.Name
                    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue }
                    Move-Item -LiteralPath $_.FullName -Destination $Root -Force
                }
                Remove-Item -LiteralPath $inner -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        Write-Log WARN ("FFmpeg normalization skipped: {0}" -f $_.Exception.Message)
    }
}

# 7-Zip helpers for extracting .7z archives
function Get-SevenZipPath {
    # Try common locations and tools folder
    $candidates = @()
    $candidates += (Join-Path $script:ToolsDir '7zr.exe')
    $env:PATH.Split(';') | ForEach-Object {
        if ($_ -and (Test-Path -LiteralPath $_)) { $candidates += (Join-Path $_ '7zr.exe') }
    }
    foreach ($p in $candidates) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
    return $null
}

function Ensure-SevenZip {
    if ($script:SevenZipEnsured -and $script:SevenZipPath -and (Test-Path -LiteralPath $script:SevenZipPath)) { return $script:SevenZipPath }
    if (-not (Test-Path -LiteralPath $script:ToolsDir)) { New-Item -ItemType Directory -Path $script:ToolsDir -Force | Out-Null }
    $path = Get-SevenZipPath
    if ($path) { $script:SevenZipEnsured = $true; $script:SevenZipPath = $path; return $path }
    # Acquire 7zr.exe using the standard dependency mechanism, only if needed
    $portableUrl = $null
    $sha256 = $null
    $enforceLocalOnly = $false
    $searchPatterns = @('7zr.exe')
    $searchExts = @('.exe')
    if ($script:Config -and $script:Config.tools -and $script:Config.tools.sevenZip) {
        $portableUrl = $script:Config.tools.sevenZip.portableUrl
        if ($script:Config.tools.sevenZip.PSObject.Properties['sha256']) { $sha256 = $script:Config.tools.sevenZip.sha256 }
        if ($script:Config.tools.sevenZip.PSObject.Properties['enforceLocalOnly']) { $enforceLocalOnly = [bool]$script:Config.tools.sevenZip.enforceLocalOnly }
        if ($script:Config.tools.sevenZip.PSObject.Properties['search']) {
            if ($script:Config.tools.sevenZip.search.PSObject.Properties['patterns']) { $searchPatterns = @($script:Config.tools.sevenZip.search.patterns) }
            if ($script:Config.tools.sevenZip.search.PSObject.Properties['extensions']) { $searchExts = @($script:Config.tools.sevenZip.search.extensions) }
        }
    }
    if (-not $portableUrl) { $portableUrl = 'https://www.7-zip.org/a/7zr.exe' }
    $dep = [pscustomobject]@{
        name = '7-Zip (portable 7zr)'
        url = $portableUrl
        sha256 = $sha256
        target = $script:ToolsDir
        enforceLocalOnly = $enforceLocalOnly
        search = @{ patterns = $searchPatterns; extensions = $searchExts }
    }
    $ok = Ensure-Dependency -dep $dep
    if ($ok) {
        $sevenZr = Join-Path $script:ToolsDir '7zr.exe'
        if (Test-Path -LiteralPath $sevenZr) { $script:SevenZipEnsured = $true; $script:SevenZipPath = $sevenZr; return $sevenZr }
        $path = Get-SevenZipPath
        if ($path) { $script:SevenZipEnsured = $true; $script:SevenZipPath = $path; return $path }
    }
    return $null
}

function Expand-7ZipArchive {
    param([Parameter(Mandatory=$true)][string]$Archive,
          [Parameter(Mandatory=$true)][string]$Destination)
    $sevenZip = Ensure-SevenZip
    if (-not $sevenZip) { throw '7-Zip is required to extract .7z archives but could not be installed.' }
    if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
    Write-Log INFO "Extracting 7z archive to $Destination using: $sevenZip"
    $args = @('x','-y',("-o{0}" -f $Destination), $Archive)
    $proc = Start-Process -FilePath $sevenZip -ArgumentList $args -NoNewWindow -PassThru -Wait
    if ($proc.ExitCode -ne 0) { throw ("7-Zip extraction failed with exit code {0}" -f $proc.ExitCode) }
}

function Show-LocateOrDownloadDialog {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [string]$Url = ''
    )
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    } catch {}
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Dependency required'
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.Size = New-Object System.Drawing.Size(520,200)

    $label = New-Object System.Windows.Forms.Label
    $label.AutoSize = $true
    $label.MaximumSize = New-Object System.Drawing.Size(480,0)
    $label.Location = New-Object System.Drawing.Point(12,12)
    $label.Text = ("Package not found: {0}`r`n`r`nChoose an action for this dependency:`r`n`tLocate: pick an existing package from disk`r`n`tDownload: fetch from URL {1}" -f $Name, $Url)
    $form.Controls.Add($label)

    $btnLocate = New-Object System.Windows.Forms.Button
    $btnLocate.Text = 'Locate'
    $btnLocate.Size = New-Object System.Drawing.Size(100,28)
    $btnLocate.Location = New-Object System.Drawing.Point(260,130)
    $btnLocate.Add_Click({ $form.Tag = 'locate'; $form.Close() })
    $form.Controls.Add($btnLocate)

    $btnDownload = New-Object System.Windows.Forms.Button
    $btnDownload.Text = 'Download'
    $btnDownload.Size = New-Object System.Drawing.Size(100,28)
    $btnDownload.Location = New-Object System.Drawing.Point(372,130)
    $btnDownload.Add_Click({ $form.Tag = 'download'; $form.Close() })
    $form.Controls.Add($btnDownload)

    $form.AcceptButton = $btnDownload
    $form.CancelButton = $btnLocate
    $null = $form.ShowDialog()
    if ($form.Tag -eq 'download') { return 'download' }
    return 'locate'
}
$script:ConfigPath = Join-Path $script:BaseDir 'installer.config.json'
$script:IsQuiet = [bool]$quiet
$script:UserLevelInstall = $false  # flips to true if elevation denied or not admin
$script:Config = $null
$script:LockFile = Join-Path $env:TEMP 'iCameraProxyInstaller.lock'
$script:LogDir = $null
$script:LogPath = $null
$script:InstallRoot = $null
$script:SelectedDrive = 'C:'
$script:ToolsDir = Join-Path $script:BaseDir 'tools'
# Cache for 7-Zip to avoid repeated ensure attempts across multiple .7z dependencies
$script:SevenZipEnsured = $false
$script:SevenZipPath = $null
$script:DatabasePort = $null
$script:FileCatalystINF = Join-Path $script:BaseDir 'filecatalyst_hotfolder.inf'
$script:SkipShaChecks = $false
$script:DependencyMode = '' # 'locate_all' | 'download_all' | 'ask_each'

function Write-Log {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('INFO','WARN','ERROR','SUCCESS')][string]$Level,
        [Parameter(Mandatory=$true)][string]$Message
    )
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$ts][$($Level.ToUpper())] $Message"
    if (-not $script:IsQuiet -or $Level -in @('ERROR','WARN','SUCCESS')) { Write-Host $line }
    if ($script:LogPath) { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 }
}

function Show-ErrorDialog {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [string]$Title = 'iCamera Proxy Installer'
    )
    try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop } catch {}
    try {
        [void][System.Windows.Forms.MessageBox]::Show(
            $Message,
            $Title,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    } catch {}
}

function Initialize-Logging {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        throw "Config file not found: $script:ConfigPath"
    }
    $script:Config = Get-Content -Raw -LiteralPath $script:ConfigPath | ConvertFrom-Json
    # Pre-log dir: use BaseDir/logs until InstallRoot decided; later move if needed
    $preLogDir = Join-Path $script:BaseDir 'logs'
    if (-not (Test-Path -LiteralPath $preLogDir)) { New-Item -ItemType Directory -Path $preLogDir -Force | Out-Null }
    $script:LogDir = $preLogDir
    $script:LogPath = Join-Path $script:LogDir 'installer.log'
    New-Item -ItemType File -Path $script:LogPath -Force | Out-Null
    Write-Log INFO "Initialized logging at $script:LogPath"
    # Options
    if ($script:Config.options -and $script:Config.options.skipShaChecks) {
        $script:SkipShaChecks = [bool]$script:Config.options.skipShaChecks
        if ($script:SkipShaChecks) { Write-Log INFO 'SHA256 verification is DISABLED by configuration.' }
    }
}

function Replace-Tokens {
    param(
        [Parameter(Mandatory=$true)][string]$Text
    )
    $result = $Text
    if ($script:InstallRoot) { $result = $result -replace [regex]::Escape('<Install Root>'), [Regex]::Escape($script:InstallRoot) -replace '\\E','' }
    if ($script:DatabasePort) { $result = $result -replace '\$\{DatabasePort\}', [string]$script:DatabasePort }
    return $result
}

function Is-Admin { return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }

function Ensure-ElevationOrFallback {
    if (Is-Admin) { Write-Log INFO 'Process is elevated.'; return }
    Write-Log WARN 'Not running as administrator. Attempting elevation...'
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-Process -Id $PID).Path
        $psi.Verb = 'runas'
        $args = @()
        $args += '-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath)
        if ($script:IsQuiet) { $args += '--quiet' }
        if ($uninstall) { $args += '--uninstall' }
        $psi.Arguments = $args -join ' '
        [System.Diagnostics.Process]::Start($psi) | Out-Null
        exit 0
    } catch {
        Write-Log WARN "Elevation denied or failed. Continuing with user-level installation."
        $script:UserLevelInstall = $true
    }
}

function New-InstallerLock {
    if (Test-Path -LiteralPath $script:LockFile) {
        $existing = Get-Content -LiteralPath $script:LockFile -ErrorAction SilentlyContinue
        if ($existing) {
            $existingPid = [int]$existing
            if (Get-Process -Id $existingPid -ErrorAction SilentlyContinue) {
                Write-Log ERROR "Another installer instance is running (PID=$existingPid)."
                exit 3
            } else {
                Write-Log WARN 'Found stale lock file. Cleaning up.'
                Remove-Item -LiteralPath $script:LockFile -Force -ErrorAction SilentlyContinue
            }
        } else {
            Remove-Item -LiteralPath $script:LockFile -Force -ErrorAction SilentlyContinue
        }
    }
    Set-Content -LiteralPath $script:LockFile -Value $PID -Encoding ASCII
}

function Remove-InstallerLock { if (Test-Path -LiteralPath $script:LockFile) { Remove-Item -LiteralPath $script:LockFile -Force -ErrorAction SilentlyContinue } }

function Select-InstallationDrive {
    if ($script:UserLevelInstall) {
        $script:InstallRoot = Join-Path $env:LOCALAPPDATA 'iCamera'
        Write-Log INFO "User-level install root: $script:InstallRoot"
        return
    }
    $drives = Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 -and $_.FileSystem }
    if (-not $drives) { throw 'No fixed drives found.' }
    $driveList = @($drives)
    $sorted = $driveList | Sort-Object -Property FreeSpace -Descending
    $default = ($sorted | Select-Object -First 1).DeviceID
    $count = $driveList.Count
    if ($script:IsQuiet -or $count -eq 1) {
        $script:SelectedDrive = if ($driveList | Where-Object DeviceID -eq 'C:') { 'C:' } else { ($sorted | Select-Object -First 1).DeviceID }
    } else {
        Write-Host "Available drives:"; $i=1
        foreach ($d in $sorted) { $gb=[math]::Round($d.FreeSpace/1GB,2); Write-Host ("  [{0}] {1} (Free {2} GB)" -f $i,$d.DeviceID,$gb); $i++ }
        $sel = Read-Host "Select drive number (default $default)"
        if ([string]::IsNullOrWhiteSpace($sel)) { $script:SelectedDrive=$default } else { $script:SelectedDrive=$sorted[[int]$sel-1].DeviceID }
    }
    $script:InstallRoot = "$($script:SelectedDrive)\iCamera"
    Write-Log INFO "Install root: $script:InstallRoot"
}

function Ensure-InstallDirectories {
    $paths = @($script:InstallRoot, (Join-Path $script:InstallRoot 'proxy'), (Join-Path $script:InstallRoot 'logs'), (Join-Path $script:InstallRoot 'config'))
    foreach ($p in $paths) { if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }
    # Switch logging to final logs folder
    $script:LogDir = Join-Path $script:InstallRoot 'logs'
    $script:LogPath = Join-Path $script:LogDir 'installer.log'
    if (-not (Test-Path -LiteralPath $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $script:LogPath)) { New-Item -ItemType File -Path $script:LogPath -Force | Out-Null }
    Write-Log INFO "Logging moved to $script:LogPath"
}

function Test-SystemPrereqs {
    # OS
    $os = (Get-CimInstance Win32_OperatingSystem)
    $ver = [version]$os.Version
    $minOk = ($ver.Major -ge 10) -or ($os.Caption -match 'Server 2016|Server 2019|Server 2022')
    if (-not $minOk) { throw "Unsupported OS: $($os.Caption) $($os.Version)" }
    # Disk
    # PowerShell 5.1 doesn't support ternary operator; use explicit if/else
    if ($script:UserLevelInstall) {
        $drive = (Get-Item $env:LOCALAPPDATA).PSDrive
    } else {
        $drive = Get-PSDrive -Name $script:SelectedDrive.TrimEnd(':')
    }
    $freeGB = [math]::Round($drive.Free/1GB,2)
    if ($freeGB -lt 10) { throw "Insufficient disk space on $($drive.Name): needs >= 10 GB (free=$freeGB GB)" }
    # Memory
    $comp = Get-CimInstance Win32_ComputerSystem
    $totalGB = [math]::Round($comp.TotalPhysicalMemory/1GB,2)
    if ($totalGB -lt 8) { throw "Insufficient total RAM: ${totalGB}GB (min 8GB)" }
    $osStats = Get-CimInstance Win32_OperatingSystem
    $availGB = [math]::Round(($osStats.FreePhysicalMemory*1KB)/1GB,2)
    if ($availGB -lt 4) { Write-Log WARN "Low available RAM: ${availGB}GB (<4GB)" }
    # Network
    $urls = @()
    if ($script:Config.networkChecks -and $script:Config.networkChecks.urls) { $urls = $script:Config.networkChecks.urls }
    foreach ($url in $urls) {
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -Method Head -TimeoutSec 15
            if (-not $resp) { throw "No response" }
        } catch {
            throw "Network check failed for ${url}: $($_.Exception.Message)"
        }
    }
}

function Cleanup-LegacyInstall {
    try {
        Write-Log INFO 'Starting legacy cleanup...'
        # Remove legacy scheduled task
        $taskName = 'iCameraProcessMonitor'
        $t = schtasks /Query /TN $taskName 2>$null
        if ($LASTEXITCODE -eq 0) {
            if ($script:IsQuiet -or (Read-Host "Remove legacy scheduled task '$taskName'? (y/N)") -match '^(y|Y)') {
                schtasks /End /TN $taskName 2>$null | Out-Null
                schtasks /Delete /TN $taskName /F 2>$null | Out-Null
                Write-Log INFO "Removed legacy scheduled task $taskName"
            }
        }
        # Remove legacy directories on fixed drives
        $drives = Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 }
        foreach ($d in $drives) {
            $p = "$(($d.DeviceID))\iCamera"
            if (Test-Path -LiteralPath $p) {
                if ($script:InstallRoot -and ($p -ieq $script:InstallRoot)) {
                    Write-Log INFO "Skipping legacy path equal to current InstallRoot: $p"
                    continue
                }
                $remove = $script:IsQuiet -or ((Read-Host "Remove legacy directory '$p'? (y/N)") -match '^(y|Y)')
                if ($remove) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue; Write-Log INFO "Removed legacy directory $p" }
            }
        }
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match 'cannot find the file specified') {
            Write-Log INFO 'No legacy installation found; continuing.'
        } else {
            Write-Log WARN "Legacy cleanup encountered issues: $msg"
        }
    }
}

function Get-LocalFile {
    param([Parameter(Mandatory=$true)][string]$FileName)
    $local = Join-Path $script:BaseDir $FileName
    if (Test-Path -LiteralPath $local) { return $local }
    return $null
}

function Select-LocalFileDialog {
    param(
        [Parameter(Mandatory=$true)][string]$Title,
        [string]$Filter = 'Archives (*.zip;*.exe)|*.zip;*.exe|All files (*.*)|*.*'
    )
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = $Title
        $dlg.Filter = $Filter
        $dlg.InitialDirectory = $script:BaseDir
        $null = $dlg.ShowDialog()
        if ($dlg.FileName -and (Test-Path -LiteralPath $dlg.FileName)) { return $dlg.FileName }
        return $null
    } catch {
        Write-Log WARN "File dialog unavailable: $($_.Exception.Message)"
        return $null
    }
}

function Select-DependencyMode {
    if ($script:IsQuiet -or $script:DependencyMode) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $form = New-Object System.Windows.Forms.Form
        $form.Text = 'Dependency Mode'
        $form.StartPosition = 'CenterScreen'
        $form.Size = New-Object System.Drawing.Size(420,180)
        
        $label = New-Object System.Windows.Forms.Label
        $label.Text = 'Dependency mode: (L)ocate all, (D)ownload all, (A)sk each'
        $label.AutoSize = $true
        $label.Location = New-Object System.Drawing.Point(12,12)
        $form.Controls.Add($label)

        $rbAsk = New-Object System.Windows.Forms.RadioButton
        $rbAsk.Text = 'Ask each (default)'
        $rbAsk.Checked = $true
        $rbAsk.Location = New-Object System.Drawing.Point(15,40)
        $form.Controls.Add($rbAsk)

        $rbLocate = New-Object System.Windows.Forms.RadioButton
        $rbLocate.Text = 'Locate all'
        $rbLocate.Location = New-Object System.Drawing.Point(15,65)
        $form.Controls.Add($rbLocate)

        $rbDownload = New-Object System.Windows.Forms.RadioButton
        $rbDownload.Text = 'Download all'
        $rbDownload.Location = New-Object System.Drawing.Point(15,90)
        $form.Controls.Add($rbDownload)

        $okBtn = New-Object System.Windows.Forms.Button
        $okBtn.Text = 'OK'
        $okBtn.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $okBtn.Location = New-Object System.Drawing.Point(300,110)
        $form.AcceptButton = $okBtn
        $form.Controls.Add($okBtn)

        $null = $form.ShowDialog()
        if ($rbLocate.Checked) { $script:DependencyMode = 'locate_all' }
        elseif ($rbDownload.Checked) { $script:DependencyMode = 'download_all' }
        else { $script:DependencyMode = 'ask_each' }
        Write-Log INFO "Dependency mode set to: $script:DependencyMode"
    } catch {
        # Fallback to console prompt if WinForms fails
        $ans = Read-Host "Dependency mode: (L)ocate all, (D)ownload all, (A)sk each [default A]"
        switch -Regex ($ans) {
            '^(l|L)' { $script:DependencyMode = 'locate_all'; break }
            '^(d|D)' { $script:DependencyMode = 'download_all'; break }
            default { $script:DependencyMode = 'ask_each' }
        }
        Write-Log INFO "Dependency mode set to: $script:DependencyMode"
    }
}

function Get-FileSha256 {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLower()
}

function Download-File {
    param([string]$Url,[string]$Dest)
    Write-Log INFO "Downloading $Url -> $Dest"
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 600 -ErrorAction Stop
        return $true
    } catch {
        $status = $null
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) { $status = [int]$_.Exception.Response.StatusCode }
        if ($status) {
            Write-Log ERROR "Download failed ($status) for $Url"
        } else {
            Write-Log ERROR ("Download failed for {0}: {1}" -f $Url, $_.Exception.Message)
        }
        return $false
    }
}

function Normalize-JreLayout {
    param([Parameter(Mandatory=$true)][string]$Root)
    try {
        $expected = Join-Path $Root 'bin\java.exe'
        if (Test-Path -LiteralPath $expected) { return }
        # Find a java.exe under a top-level subfolder (e.g., Root\jre8\bin\java.exe)
        $cand = Get-ChildItem -LiteralPath $Root -Recurse -Filter 'java.exe' -ErrorAction SilentlyContinue |
            Where-Object { $_.DirectoryName -like '*\bin' } |
            Select-Object -First 1
        if (-not $cand) { return }
        # Identify the top-level folder directly under $Root that contains this java.exe
        $binDir = Split-Path -Parent $cand.FullName
        $top = Split-Path -Parent $binDir
        # If $top is Root itself, nothing to normalize
        if ([System.IO.Path]::GetFullPath($top).TrimEnd('\') -ieq [System.IO.Path]::GetFullPath($Root).TrimEnd('\\')) { return }
        # Move contents of $top into $Root
        Write-Log INFO ("Normalizing JRE layout by flattening '{0}' into '{1}'" -f $top, $Root)
        Get-ChildItem -LiteralPath $top -Force | ForEach-Object {
            $dest = Join-Path $Root $_.Name
            if (Test-Path -LiteralPath $dest) {
                Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
            }
            Move-Item -LiteralPath $_.FullName -Destination $Root -Force
        }
        # Remove now-empty top folder
        Remove-Item -LiteralPath $top -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Log WARN ("JRE normalization skipped: {0}" -f $_.Exception.Message)
    }
}

function Resolve-JavaExe {
    param([Parameter(Mandatory=$true)][string]$Root)
    $default = Join-Path $Root 'bin\java.exe'
    if (Test-Path -LiteralPath $default) { return $default }
    $cand = Get-ChildItem -LiteralPath $Root -Recurse -Filter 'java.exe' -ErrorAction SilentlyContinue |
        Where-Object { $_.DirectoryName -like '*\bin' } |
        Select-Object -First 1
    if ($cand) { return $cand.FullName }
    return $default
}

function Ensure-Dependency {
    param([psobject]$dep)
    $url = $dep.url
    # Replace unsupported ternary operator with if/else for PowerShell 5.1
    if ($dep.sha256) { $sha = $dep.sha256.ToLower() } else { $sha = '' }
    $target = Replace-Tokens -Text $dep.target
    if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
    # Determine display name and local file if any
    $displayName = if ($dep.name) { [string]$dep.name } else { 'package' }
    $local = $null
    $urlFileName = $null
    if ($url) {
        try { $urlFileName = [System.IO.Path]::GetFileName((New-Object System.Uri($url)).AbsolutePath) } catch { $urlFileName = $null }
    }
    # Pattern-based local search across configured paths
    $searchPaths = @()
    if ($script:Config -and $script:Config.dependencySearch -and $script:Config.dependencySearch.paths) {
        foreach ($p in $script:Config.dependencySearch.paths) {
            if ($p -eq '<Self>') { $searchPaths += $script:BaseDir }
            elseif ($p -eq '<Downloads>') { $searchPaths += (Join-Path $env:USERPROFILE 'Downloads') }
            elseif ($p) { $searchPaths += $p }
        }
    }
    if (-not $searchPaths -or $searchPaths.Count -eq 0) { $searchPaths = @($script:BaseDir) }
    $patterns = @()
    $exts = @()
    if ($dep.search) {
        if ($dep.search.patterns) { $patterns = @($dep.search.patterns) }
        if ($dep.search.extensions) { $exts = @($dep.search.extensions) }
    }
    # Fallbacks
    if (-not $patterns -or $patterns.Count -eq 0) {
        if ($urlFileName) {
            $patterns = @($urlFileName)
        }
    }
    if (-not $exts -or $exts.Count -eq 0) {
        if ($urlFileName) { $exts = @([System.IO.Path]::GetExtension($urlFileName)) }
    }
    # Search
    foreach ($base in $searchPaths) {
        if (-not $base -or -not (Test-Path -LiteralPath $base)) { continue }
        # First, try exact filename if known
        if ($urlFileName) {
            $cand = Join-Path $base $urlFileName
            if (Test-Path -LiteralPath $cand) { $local = $cand; break }
        }
        # Then try patterns with extensions
        if ($patterns -and $patterns.Count -gt 0) {
            foreach ($pat in $patterns) {
                $filters = @($pat)
                if ($exts -and $exts.Count -gt 0) {
                    $filters = @()
                    foreach ($e in $exts) {
                        if ($pat -like '*.*') { $filters += $pat } else { $filters += ("{0}{1}" -f $pat, $e) }
                    }
                }
                foreach ($f in $filters) {
                    $match = Get-ChildItem -LiteralPath $base -File -Filter $f -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                    if ($match) { $local = $match.FullName; break }
                }
                if ($local) { break }
            }
            if ($local) { break }
        } elseif ($exts -and $exts.Count -gt 0) {
            foreach ($e in $exts) {
                $match = Get-ChildItem -LiteralPath $base -File -Filter ("*{0}" -f $e) -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($match) { $local = $match.FullName; break }
            }
            if ($local) { break }
        }
    }
    # Legacy single-path check in BaseDir if still not found and urlFileName known
    if (-not $local -and $urlFileName) {
        $maybeLocal = Join-Path $script:BaseDir $urlFileName
        if (Test-Path -LiteralPath $maybeLocal) { $local = $maybeLocal }
    }
    $downloaded = $false
    $src = $local
    if (-not $src) {
        # Respect enforceLocalOnly flag: do not prompt or download if no local package is found
        if ($dep.enforceLocalOnly) {
            Write-Log ERROR "Dependency '$displayName' is enforceLocalOnly but no local package was found in configured search paths."
            return $false
        }
        Select-DependencyMode
        if (-not $script:IsQuiet) {
            $choice = Show-LocateOrDownloadDialog -Name $displayName -Url $url
            if ($choice -eq 'locate') {
                $picked = Select-LocalFileDialog -Title "Locate package for $displayName"
                if ($picked) { $src = $picked } else { Write-Log WARN "User canceled file selection for $displayName" }
            } elseif ($choice -eq 'download') {
                if ([string]::IsNullOrWhiteSpace($url)) { Write-Log ERROR "No download URL configured for $displayName"; return $false }
                $dlName = if ($urlFileName) { $urlFileName } else { 'download.tmp' }
                $src = Join-Path $script:BaseDir $dlName
                $ok = Download-File -Url $url -Dest $src
                if (-not $ok) { Write-Log ERROR "Could not obtain dependency $displayName"; return $false }
                $downloaded = $true
            } else {
                Write-Log WARN "User canceled acquisition for $displayName"
                return $false
            }
        }
        if (-not $src) {
            # Non-interactive or still not resolved: follow mode
            if ([string]::IsNullOrWhiteSpace($url)) { Write-Log ERROR "Dependency '$displayName' not found locally and no URL provided."; return $false }
            $dlName = if ($urlFileName) { $urlFileName } else { 'download.tmp' }
            $src = Join-Path $script:BaseDir $dlName
            $autoDownload = $script:IsQuiet -or $script:DependencyMode -eq 'download_all'
            if ($autoDownload) {
                $ok = Download-File -Url $url -Dest $src
                if (-not $ok) { Write-Log ERROR "Could not obtain dependency $displayName"; return $false }
                $downloaded = $true
            } else {
                # In locate_all mode but not interactive or unresolved: fail gracefully
                Write-Log ERROR "Dependency '$displayName' not located."
                return $false
            }
        }
    }
    if ($sha -and -not $script:SkipShaChecks) {
        $calc = Get-FileSha256 -Path $src
        if ($calc -ne $sha) { Write-Log ERROR "Checksum mismatch for $displayName. Expected $sha, got $calc"; return $false }
    }
    if ($script:SkipShaChecks -and $sha) { Write-Log WARN "Skipping SHA256 verification for $displayName by configuration." }
    # Extract or copy based on actual source file extension
    $ext = ([System.IO.Path]::GetExtension($src)).ToLower()
    if ($ext -eq '.zip') {
        Write-Log INFO "Extracting $displayName (.zip) to $target"
        Expand-Archive -LiteralPath $src -DestinationPath $target -Force
    } elseif ($ext -eq '.7z') {
        Write-Log INFO "Extracting $displayName (.7z) to $target"
        Expand-7ZipArchive -Archive $src -Destination $target
    } elseif ($ext -eq '.exe') {
        # Leave EXE in target, preserve original filename
        $srcBase = [System.IO.Path]::GetFileName($src)
        Copy-Item -LiteralPath $src -Destination (Join-Path $target $srcBase) -Force
    } else {
        Copy-Item -LiteralPath $src -Destination $target -Force
    }
    # Normalize JRE layout if this dependency is the Java runtime
    if ($dep -and (
        ($dep.target -and ($dep.target -like '*\\jre')) -or
        ($dep.name -and ($dep.name -match '(?i)jre|corretto|openjdk'))
    )) {
        Normalize-JreLayout -Root $target
    }
    # Normalize FFmpeg layout if this dependency is FFmpeg
    if ($dep -and (
        ($dep.target -and ($dep.target -like '*\\ffmpeg')) -or
        ($dep.name -and ($dep.name -match '(?i)ffmpeg'))
    )) {
        Normalize-FfmpegLayout -Root $target
        $ffexe = Join-Path $target 'bin\ffmpeg.exe'
        if (Test-Path -LiteralPath $ffexe) {
            Write-Log SUCCESS "FFmpeg ready: $ffexe"
        } else {
            Write-Log ERROR "FFmpeg not found after extraction. Expected: $ffexe"
            return $false
        }
    }
    # Keep the downloaded file in self folder as requested; do not delete
    return $true
}

function Find-AvailablePort {
    param([int]$Start=9001,[int]$End=9100)
    for ($p=$Start; $p -le $End; $p++) {
        $inUse = Test-NetConnection -ComputerName 'localhost' -Port $p -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        if (-not $inUse.TcpTestSucceeded) { return $p }
    }
    throw "No available TCP port in range $Start-$End"
}

function Configure-HSQLDB {
    $hs = $script:Config.dependencies.hsqldb
    if (-not $hs) { throw 'HSQLDB dependency not configured.' }
    $ok = Ensure-Dependency -dep $hs
    if (-not $ok) { throw 'HSQLDB dependency acquisition failed.' }
    $dbName = $hs.dbName
    $portRange = $hs.portRange
    $script:DatabasePort = Find-AvailablePort -Start $portRange.start -End $portRange.end
    Write-Log INFO "Selected HSQLDB port: $script:DatabasePort"
    $hsRoot = Replace-Tokens -Text $hs.target
    $dataDir = Join-Path $hsRoot 'data'
    if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }
    # server.properties
    $serverProps = @(
        "server.database.0=file:$dataDir\$dbName",
        "server.dbname.0=$dbName",
        "server.port=$script:DatabasePort"
    )
    Set-Content -LiteralPath (Join-Path $hsRoot 'server.properties') -Value $serverProps -Encoding ASCII
    # sqltool.rc (use configured dbName; HSQLDB expects space-separated rc syntax)
    $sqltool = @("urlid $dbName jdbc:hsqldb:hsql://localhost:$script:DatabasePort/$dbName user=SA password=")
    Set-Content -LiteralPath (Join-Path $hsRoot 'sqltool.rc') -Value $sqltool -Encoding ASCII
    # Initialize DB using sqltool if scripts provided
    if ($hs.sqlInitScripts) {
        $sqltoolJar = Get-ChildItem -Path $hsRoot -Recurse -Filter 'sqltool*.jar' | Select-Object -First 1
        $hsqldbJar = Get-ChildItem -Path $hsRoot -Recurse -Filter 'hsqldb*.jar' | Select-Object -First 1
        if ($sqltoolJar -and $hsqldbJar) {
            Write-Log INFO 'Initializing HSQLDB database with SQL scripts.'
            $rcFile = Join-Path $hsRoot 'sqltool.rc'
            Write-Log INFO ("Using sqltool.rc: {0}" -f (Get-Content -LiteralPath $rcFile -ErrorAction SilentlyContinue | Select-Object -First 1))
            foreach ($scriptPath in $hs.sqlInitScripts) {
                $resolved = Replace-Tokens -Text $scriptPath
                if (Test-Path -LiteralPath $resolved) {
                    $javaExe = Resolve-JavaExe -Root (Join-Path $script:InstallRoot 'jre')
                    $classpath = "$($hsqldbJar.FullName);$($sqltoolJar.FullName)"
                    & $javaExe -cp $classpath org.hsqldb.cmdline.SqlTool "--rcFile=$rcFile" $dbName $resolved
                } else {
                    Write-Log WARN "SQL init script not found: $resolved"
                }
            }
        } else {
            Write-Log WARN 'sqltool.jar or hsqldb.jar not found; skipping DB initialization.'
        }
    }
}

function Install-FileCatalystHotFolder {
    $fc = $script:Config.dependencies.filecatalyst
    if (-not $fc) { Write-Log INFO 'FileCatalyst not configured.'; return }
    Ensure-Dependency -dep $fc
    # Discover installer EXE: prefer any .exe in target; fallback to URL filename in local folder
    $targetDir = Replace-Tokens -Text $fc.target
    $exePath = $null
    if (Test-Path -LiteralPath $targetDir) {
        $cand = Get-ChildItem -Path $targetDir -Filter '*.exe' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($cand) { $exePath = $cand.FullName }
        if (-not $exePath) {
            # try to prefer names containing 'transferagent' or 'install'
            $pref = Get-ChildItem -Path $targetDir -Filter '*.exe' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'transferagent|install' } | Select-Object -First 1
            if ($pref) { $exePath = $pref.FullName }
        }
    }
    if (-not $exePath -and $fc.url) {
        try {
            $urlFile = [System.IO.Path]::GetFileName((New-Object System.Uri($fc.url)).AbsolutePath)
            $maybeLocal = Join-Path $script:BaseDir $urlFile
            if (Test-Path -LiteralPath $maybeLocal) { $exePath = $maybeLocal }
        } catch {}
    }
    if (-not $exePath) { Write-Log WARN 'FileCatalyst HotFolder installer EXE not found.'; return }
    # Build absolute INF path and enforce it in args
    $infPath = $script:FileCatalystINF
    $saveArgsArr = @()
    foreach ($arg in ($fc.saveInfArgs | ForEach-Object { Replace-Tokens -Text $_ })) {
        if ($arg -match '^(?i)(/|-)SAVEINF(?::|=)?') { $arg = ('/SAVEINF="{0}"' -f $infPath) }
        $saveArgsArr += $arg
    }
    $saveArgs = $saveArgsArr -join ' '
    Write-Log INFO "Running FileCatalyst HotFolder SAVEINF: $saveArgs (wd=$script:BaseDir)"
    Start-Process -FilePath $exePath -ArgumentList $saveArgs -WorkingDirectory $script:BaseDir -Wait -PassThru | Out-Null
    # LOADINF
    $loadArgsArr = @()
    foreach ($arg in ($fc.loadInfArgs | ForEach-Object { Replace-Tokens -Text $_ })) {
        if ($arg -match '^(?i)(/|-)LOADINF(?::|=)?') { $arg = ('/LOADINF="{0}"' -f $infPath) }
        $loadArgsArr += $arg
    }
    $loadArgs = $loadArgsArr -join ' '
    Write-Log INFO "Running FileCatalyst HotFolder LOADINF: $loadArgs (wd=$script:BaseDir)"
    Start-Process -FilePath $exePath -ArgumentList $loadArgs -WorkingDirectory $script:BaseDir -Wait -PassThru | Out-Null
}

function Get-FileCatalystInstallDir {
    $inf = $script:FileCatalystINF
    if (-not (Test-Path -LiteralPath $inf)) { return $null }
    try {
        $content = Get-Content -LiteralPath $inf -ErrorAction SilentlyContinue
        $line = $content | Where-Object { $_ -match '^(?i)Dir\s*=\s*(.+)$' } | Select-Object -First 1
        if ($line) {
            $m = [regex]::Match($line, '^(?i)Dir\s*=\s*(.+)$')
            if ($m.Success) {
                $dir = $m.Groups[1].Value.Trim()
                return $dir
            }
        }
    } catch {}
    return $null
}

function Get-FileCatalystHotFolder {
    $fc = $script:Config.dependencies.filecatalyst
    if (-not $fc) { return $null }
    # Prefer hotfolders.xml inside the FileCatalyst installation directory (from INF Dir)
    $installDir = Get-FileCatalystInstallDir
    if ($installDir) {
        $xmlPath = Join-Path $installDir 'hotfolders.xml'
        if (Test-Path -LiteralPath $xmlPath) {
            try {
                [xml]$doc = Get-Content -LiteralPath $xmlPath -ErrorAction Stop
                $nodes = $doc.SelectNodes('//HotFolder')
                if ($nodes -and $nodes.Count -gt 0) {
                    $locs = @()
                    foreach ($n in $nodes) {
                        $loc = $n.GetAttribute('Location')
                        if ($loc) { $locs += ($loc -replace '/', '\\') }
                    }
                    if ($locs.Count -gt 0) { return ($locs -join ';') }
                }
            } catch {
                Write-Log WARN ("Failed to read hotfolders.xml: {0}" -f $_.Exception.Message)
            }
        }
    }
    return $null
}

function Copy-ApplicationFiles {
    if (-not $script:Config.application.files) { return }
    foreach ($f in $script:Config.application.files) {
        $src = Join-Path $script:BaseDir $f.source
        $destDir = Replace-Tokens -Text $f.dest
        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Copy-Item -LiteralPath $src -Destination $destDir -Force
        Write-Log INFO "Copied $($f.source) -> $destDir"
    }
}

function Update-ApplicationProperties {
    $installDir = Get-FileCatalystInstallDir
    $hotFolders = (Get-FileCatalystHotFolder)
    if (-not $hotFolders) { $hotFolders = 'NOT_CONFIGURED' }
    if (-not $installDir) { $installDir = 'NOT_CONFIGURED' }
    $cfg = $script:Config.application.properties.cameraproxy
    if (-not $cfg) { return }
    $file = Replace-Tokens -Text $cfg.file
    $map = $cfg.keys
    if (-not (Test-Path -LiteralPath $file)) { Write-Log WARN "Properties file not found: $file"; return }
    $props = @{}
    if (Test-Path -LiteralPath $file) {
        Get-Content -LiteralPath $file | ForEach-Object { if ($_ -match '^(?<k>[^#=]+)=(?<v>.*)$') { $props[$Matches.k.Trim()]=$Matches.v } }
    }
    # Set dynamic values
    if ($map.dbPort) { $props[$map.dbPort] = [string]$script:DatabasePort }
    if ($map.PSObject.Properties['fileCatalystHotFolders']) { $props[$map.fileCatalystHotFolders] = $hotFolders }
    if ($map.PSObject.Properties['fileCatalystInstallDir']) { $props[$map.fileCatalystInstallDir] = $installDir }
    # Write back
    $lines = @()
    foreach ($k in $props.Keys) { $lines += "$k=$($props[$k])" }
    Set-Content -LiteralPath $file -Value $lines -Encoding UTF8
    Write-Log INFO "Updated properties in $file"
}

function Build-JvmOptionsString {
    param([psobject]$jvm)
    $opts = @()
    if ($jvm.initialHeapSize) { $opts += "-Xms$($jvm.initialHeapSize)" }
    if ($jvm.maximumHeapSize) { $opts += "-Xmx$($jvm.maximumHeapSize)" }
    if ($jvm.customParameters) { $opts += $jvm.customParameters }
    if ($jvm.systemProperties) { foreach ($k in $jvm.systemProperties.PSObject.Properties.Name) { $val = Replace-Tokens -Text ($jvm.systemProperties.$k); $opts += "-D$k=$val" } }
    return ($opts -join ' ')
}

function Register-WindowsService {
    param([string]$name,[psobject]$svc)
    $prunsrv = Replace-Tokens -Text $svc.procrunExe
    if (-not (Test-Path -LiteralPath $prunsrv)) { throw "Procrun prunsrv.exe not found: $prunsrv" }
    # Resolve JavaHome: allow override via svc.jreHome, else default to <Install Root>\jre
    if ($svc.PSObject.Properties['jreHome']) {
        $jreHome = Replace-Tokens -Text $svc.jreHome
    } else {
        $jreHome = Join-Path $script:InstallRoot 'jre'
    }
    # Ensure service log directory exists (avoid system32 fallback)
    $serviceLogDir = Join-Path $script:InstallRoot 'logs'
    if (-not (Test-Path -LiteralPath $serviceLogDir)) { New-Item -ItemType Directory -Path $serviceLogDir -Force | Out-Null }
    # Resolve start class (support both startClass and mainClass)
    $startClass = $null
    if ($svc.PSObject.Properties['startClass']) { $startClass = $svc.startClass }
    elseif ($svc.PSObject.Properties['mainClass']) { $startClass = $svc.mainClass }
    if (-not $startClass) { throw "Service '$name' is missing startClass/mainClass in configuration." }

    # If service already exists, stop and delete it to support re-install
    try {
        $existing = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Log WARN "Service $name already exists. Replacing it."
            try { if ($existing.Status -ne 'Stopped') { Write-Log INFO "Stopping existing service $name"; Stop-Service -Name $name -Force -ErrorAction SilentlyContinue } } catch {}
            try { sc.exe delete "$name" | Out-Null } catch {}
            # wait briefly until it's gone
            $tries = 0; while ($tries -lt 20) { Start-Sleep -Milliseconds 250; $tries++; if (-not (Get-Service -Name $name -ErrorAction SilentlyContinue)) { break } }
        }
    } catch {}

    $common = @("//IS//$name",
        "--DisplayName=$($svc.displayName)",
        "--StartMode=Java",
        "--JavaHome=$jreHome",
        "--StartClass=$startClass")
    if ($svc.PSObject.Properties['classpath'] -and $svc.classpath) { $common += "--Classpath=$(Replace-Tokens -Text $svc.classpath)" }
    if ($svc.PSObject.Properties['startParams'] -and $svc.startParams) { $common += "--StartParams=" + (($svc.startParams | ForEach-Object { Replace-Tokens -Text $_ }) -join ' ') }
    if ($svc.PSObject.Properties['stopClass'] -and $svc.stopClass) { $common += "--StopMode=Java","--StopClass=$($svc.stopClass)" }
    if ($svc.PSObject.Properties['stopParams'] -and $svc.stopParams) { $common += "--StopParams=" + (($svc.stopParams | ForEach-Object { Replace-Tokens -Text $_ }) -join ' ') }
    if ($svc.dependsOn) { $common += "--DependsOn=" + (($svc.dependsOn) -join ',') }
    # iCamera JVM & ENV handling (guard for missing properties)
    if ($svc.PSObject.Properties['jvmOptions']) { $common += "--JvmOptions=$(Build-JvmOptionsString -jvm $svc.jvmOptions)" }
    if ($svc.PSObject.Properties['env']) {
        $envObj = $svc.env
        foreach ($k in $envObj.PSObject.Properties.Name) {
            $common += "--Env=$k=$(Replace-Tokens -Text ($envObj.$k))"
        }
    }
    $common += '--Startup=automatic','--LogPath=' + (Join-Path $script:InstallRoot 'logs')
    Write-Log INFO "Registering Windows service $name"
    $p = Start-Process -FilePath $prunsrv -ArgumentList ($common -join ' ') -Wait -NoNewWindow -PassThru
    if ($p.ExitCode -ne 0) { throw "Apache Commons Daemon procrun failed with exit value: $($p.ExitCode) (failed to install service)" }
    # Optional: configure delayed auto-start
    if ($svc.PSObject.Properties['delayedAutoStart'] -and $svc.delayedAutoStart) {
        try {
            Write-Log INFO "Enabling delayed auto-start for service $name"
            sc.exe config "$name" start= delayed-auto | Out-Null
        } catch {
            Write-Log WARN "Failed to set delayed auto-start for $($name): $($_.Exception.Message)"
        }
    }
    # Optional: configure service recovery (restart on failure)
    if ($svc.PSObject.Properties['recovery'] -and $svc.recovery.enabled) {
        $reset = if ($svc.recovery.resetSeconds) { [int]$svc.recovery.resetSeconds } else { 86400 }
        $attempts = if ($svc.recovery.attempts) { [int]$svc.recovery.attempts } else { 3 }
        $delay = if ($svc.recovery.restartDelayMs) { [int]$svc.recovery.restartDelayMs } else { 10000 }
        # Build actions string: repeat 'restart/<delay>' for attempts count
        $acts = @()
        for ($i = 0; $i -lt $attempts; $i++) { $acts += "restart/$delay" }
        $actionsStr = ($acts -join '/')
        try {
            Write-Log INFO "Configuring recovery for service $($name): reset=$reset actions=$actionsStr"
            sc.exe failure "$name" reset= $reset actions= $actionsStr | Out-Null
            sc.exe failureflag "$name" 1 | Out-Null
        } catch {
            Write-Log WARN "Failed to configure service recovery for $($name): $($_.Exception.Message)"
        }
    }
}

function Register-ScheduledTaskEquivalent {
    param([string]$taskName,[psobject]$svc,[string]$delayISO)
    $jre = Resolve-JavaExe -Root (Join-Path $script:InstallRoot 'jre')
    $actionArgs = @()
    if ($svc.PSObject.Properties['jvmOptions']) { $actionArgs += (Build-JvmOptionsString -jvm $svc.jvmOptions).Split(' ') }
    if ($svc.PSObject.Properties['classpath'] -and $svc.classpath) { $actionArgs += '-cp'; $actionArgs += (Replace-Tokens -Text $svc.classpath) }
    # Reinstall-safe: remove existing scheduled task if present
    try {
        $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Log WARN "Scheduled task $taskName already exists. Replacing it."
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        }
    } catch {}
    # Resolve start class for scheduled task as well
    $startClass2 = $null
    if ($svc.PSObject.Properties['startClass']) { $startClass2 = $svc.startClass }
    elseif ($svc.PSObject.Properties['mainClass']) { $startClass2 = $svc.mainClass }
    if (-not $startClass2) { throw "Scheduled Task action missing startClass/mainClass for service '$name'" }
    $actionArgs += $startClass2
    if ($svc.PSObject.Properties['startParams'] -and $svc.startParams) { $actionArgs += ($svc.startParams | ForEach-Object { Replace-Tokens -Text $_ }) }
    $argLine = ($actionArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $trigger = New-ScheduledTaskTrigger -AtStartup
    if ($delayISO) { $trigger.Delay = $delayISO }
    # Run at boot as SYSTEM without user logon, with highest privileges
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $action = New-ScheduledTaskAction -Execute $jre -Argument $argLine -WorkingDirectory $script:InstallRoot
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $taskName -Trigger $trigger -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Write-Log INFO "Registered scheduled task $taskName"
}

function Register-ServicesOrTasks {
    $svc = $script:Config.services
    $tasks = $script:Config.tasks
    if ($script:UserLevelInstall) {
        # HSQLDB first
        Register-ScheduledTaskEquivalent -taskName $tasks.hsqldbTask.name -svc $svc.hsqldb -delayISO $tasks.hsqldbTask.delay
        # iCamera with delay and implicit dependency
        Register-ScheduledTaskEquivalent -taskName $tasks.icameraTask.name -svc $svc.iCameraProxy -delayISO $tasks.icameraTask.delay
    } else {
        Register-WindowsService -name $svc.hsqldb.serviceName -svc $svc.hsqldb
        Register-WindowsService -name $svc.iCameraProxy.serviceName -svc $svc.iCameraProxy
    }
}

function Invoke-CustomCommand {
    param([psobject]$cmd)
    try {
        $exe = $cmd.command
        $args = @()
        if ($cmd.arguments) { $args = $cmd.arguments | ForEach-Object { Replace-Tokens -Text $_ } }
        $wd = $cmd.workingDirectory
        if ($wd) { $wd = Replace-Tokens -Text $wd } else { $wd = $script:BaseDir }
        Write-Log INFO "Exec: $exe $($args -join ' ') (wd=$wd)"
        $p = Start-Process -FilePath $exe -ArgumentList ($args -join ' ') -WorkingDirectory $wd -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw "ExitCode=$($p.ExitCode)" }
    } catch {
        if ($cmd.continueOnError) { Write-Log WARN "Custom command failed but continueOnError=true: $($_.Exception.Message)" }
        else { throw "Custom command failed: $($_.Exception.Message)" }
    }
}

function Invoke-PreInstallCommands { if ($script:Config.customCommands.preInstall) { foreach ($c in $script:Config.customCommands.preInstall) { Invoke-CustomCommand -cmd $c } } }
function Invoke-PostInstallCommands { if ($script:Config.customCommands.postInstall) { foreach ($c in $script:Config.customCommands.postInstall) { Invoke-CustomCommand -cmd $c } } }

function Write-StartStopScripts {
    $startBat = Join-Path $script:InstallRoot 'start-icamera.bat'
    $stopBat = Join-Path $script:InstallRoot 'stop-icamera.bat'
    if ($script:UserLevelInstall) {
        $start = @(
            '@echo off',
            ('schtasks /Run /TN "{0}"' -f $script:Config.tasks.hsqldbTask.name),
            'timeout /t 2 >nul',
            ('schtasks /Run /TN "{0}"' -f $script:Config.tasks.icameraTask.name)
        )
        $stop = @(
            '@echo off',
            ('schtasks /End /TN "{0}" 2>nul' -f $script:Config.tasks.icameraTask.name),
            ('schtasks /End /TN "{0}" 2>nul' -f $script:Config.tasks.hsqldbTask.name)
        )
    } else {
        $start = @(
            "@echo off",
            "sc start $($script:Config.services.hsqldb.serviceName)",
            "sc start $($script:Config.services.iCameraProxy.serviceName)"
        )
        $stop = @(
            "@echo off",
            "sc stop $($script:Config.services.iCameraProxy.serviceName)",
            "sc stop $($script:Config.services.hsqldb.serviceName)"
        )
    }
    Set-Content -LiteralPath $startBat -Value $start -Encoding ASCII
    Set-Content -LiteralPath $stopBat -Value $stop -Encoding ASCII
}

function Write-UninstallRegistry {
    $meta = $script:Config.metadata
    $keyName = 'HKLM:SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\' + ($script:Config.uninstall.registry.uninstallKeyName)
    $tryHKCU = $false
    try {
        if (-not (Test-Path $keyName)) { New-Item -Path $keyName -Force | Out-Null }
        New-ItemProperty -Path $keyName -Name 'DisplayName' -Value $meta.displayName -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $keyName -Name 'DisplayVersion' -Value $meta.displayVersion -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $keyName -Name 'InstallDate' -Value (Get-Date).ToString('yyyyMMdd') -PropertyType String -Force | Out-Null
        $uninst = "powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" --uninstall"
        New-ItemProperty -Path $keyName -Name 'UninstallString' -Value $uninst -PropertyType String -Force | Out-Null
    } catch { $tryHKCU = $true }
    if ($tryHKCU) {
        $keyName = 'HKCU:SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\' + ($script:Config.uninstall.registry.uninstallKeyName)
        if (-not (Test-Path $keyName)) { New-Item -Path $keyName -Force | Out-Null }
        New-ItemProperty -Path $keyName -Name 'DisplayName' -Value $meta.displayName -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $keyName -Name 'DisplayVersion' -Value $meta.displayVersion -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $keyName -Name 'InstallDate' -Value (Get-Date).ToString('yyyyMMdd') -PropertyType String -Force | Out-Null
        $uninst = "powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" --uninstall"
        New-ItemProperty -Path $keyName -Name 'UninstallString' -Value $uninst -PropertyType String -Force | Out-Null
    }
}

function Set-FilePermissions {
    param([string]$path)
    try {
        $acl = Get-Acl -LiteralPath $path
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($env:USERNAME,'Modify','ContainerInherit,ObjectInherit','None','Allow')
        $acl.SetAccessRuleProtection($true,$false)
        $acl.SetAccessRule($rule)
        Set-Acl -LiteralPath $path -AclObject $acl
    } catch { Write-Log WARN "Failed to set ACL on ${path}: $($_.Exception.Message)" }
}

function Uninstall-Application {
    Write-Log INFO 'Starting uninstallation...'
    try {
        # Stop and remove services/tasks
        if (Is-Admin) {
            sc stop $script:Config.services.iCameraProxy.serviceName 2>$null | Out-Null
            sc stop $script:Config.services.hsqldb.serviceName 2>$null | Out-Null
            Start-Sleep -Seconds 2
            & (Replace-Tokens -Text $script:Config.services.iCameraProxy.procrunExe) "//DS//$($script:Config.services.iCameraProxy.serviceName)" 2>$null | Out-Null
            & (Replace-Tokens -Text $script:Config.services.hsqldb.procrunExe) "//DS//$($script:Config.services.hsqldb.serviceName)" 2>$null | Out-Null
        } else {
            schtasks /End /TN $script:Config.tasks.icameraTask.name 2>$null | Out-Null
            schtasks /End /TN $script:Config.tasks.hsqldbTask.name 2>$null | Out-Null
            schtasks /Delete /TN $script:Config.tasks.icameraTask.name /F 2>$null | Out-Null
            schtasks /Delete /TN $script:Config.tasks.hsqldbTask.name /F 2>$null | Out-Null
        }
        # FileCatalyst uninstaller
        if ($script:Config.uninstall.filecatalystUninstall) {
            $u = $script:Config.uninstall.filecatalystUninstall
            $args = ($u.arguments -join ' ')
            if (Test-Path $u.command) { Start-Process -FilePath $u.command -ArgumentList $args -Wait -NoNewWindow | Out-Null }
        }
        # Remove install directory
        if ($script:InstallRoot -and (Test-Path -LiteralPath $script:InstallRoot)) {
            Remove-Item -LiteralPath $script:InstallRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        # Remove legacy task
        schtasks /Delete /TN iCameraProcessMonitor /F 2>$null | Out-Null
        # Remove uninstall registry
        $key = 'HKLM:SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\' + $script:Config.uninstall.registry.uninstallKeyName
        if (Test-Path $key) { Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue }
        $key = 'HKCU:SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\' + $script:Config.uninstall.registry.uninstallKeyName
        if (Test-Path $key) { Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue }
        Write-Log SUCCESS 'Uninstallation completed.'
        exit 0
    } catch {
        Write-Log ERROR "Uninstallation failed: $($_.Exception.Message)"
        exit 1
    }
}

# =============================
# Main Flow
# =============================
try {
    Initialize-Logging
    New-InstallerLock
    if ($uninstall) {
        # Determine InstallRoot if possible from default drive C or LOCALAPPDATA; proceed best-effort
        $script:InstallRoot = (Join-Path $env:LOCALAPPDATA 'iCamera')
        Uninstall-Application
    }
    Ensure-ElevationOrFallback
    Select-InstallationDrive
    Ensure-InstallDirectories
    Set-FilePermissions -path $script:InstallRoot
    Write-Log INFO "Resolved placeholders will use InstallRoot=$script:InstallRoot"

    Invoke-PreInstallCommands
    Cleanup-LegacyInstall
    Test-SystemPrereqs

    # Dependencies with failure tracking
    $depFailures = @()
    if ($script:Config.dependencies.java) {
        if (-not (Ensure-Dependency -dep $script:Config.dependencies.java)) { $depFailures += 'Java (JRE)'; }
    }
    if ($script:Config.dependencies.ffmpeg) {
        if (-not (Ensure-Dependency -dep $script:Config.dependencies.ffmpeg)) { $depFailures += 'FFMPEG'; }
    }
    if ($script:Config.dependencies.procrun) {
        if (-not (Ensure-Dependency -dep $script:Config.dependencies.procrun)) { $depFailures += 'Apache Procrun'; }
    }

    # Optional dependency: FileCatalyst HotFolder (do not fail install)
    if ($script:Config.dependencies.filecatalyst) {
        try { Install-FileCatalystHotFolder } catch { Write-Log WARN "FileCatalyst HotFolder installation skipped/failed: $($_.Exception.Message)" }
    }

    # Exit early if required dependencies failed
    if ($depFailures.Count -gt 0) {
        $msg = "The following required dependencies were not installed: " + ($depFailures -join ', ') + ". Installation will now exit."
        Write-Log ERROR $msg
        Show-ErrorDialog -Message $msg
        throw $msg
    }

    # Application files should exist before DB init scripts run
    Copy-ApplicationFiles

    # Database (throws if its own dependency fails)
    if ($script:Config.dependencies.hsqldb) { Configure-HSQLDB }

    # Now that DatabasePort is known, update properties
    Update-ApplicationProperties

    # Services / Tasks
    Register-ServicesOrTasks

    # Post-install
    Write-StartStopScripts
    Write-UninstallRegistry
    Invoke-PostInstallCommands

    Write-Log SUCCESS 'Installation completed successfully.'
    exit 0
} catch {
    $fatal = "Installation failed: {0}" -f $_.Exception.Message
    Write-Log ERROR $fatal
    Show-ErrorDialog -Message $fatal
    exit 1
} finally {
    Remove-InstallerLock
}
