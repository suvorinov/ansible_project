<#
.SYNOPSIS
  Сбор данных для аудита Windows-хоста: нагрузка, процессы, браузеры,
  закладки и история посещений.

.DESCRIPTION
  Скрипт рассчитан на запуск от имени локального администратора
  (через WinRM/Ansible или вручную). Складывает результат в ZIP,
  который затем забирается на control-node и разбирается Python-скриптом.

  Что собирается:
    system.json              - ОС, CPU, RAM, диски, IP, часовой пояс;
    processes.csv            - все процессы: память, CPU, владелец, путь;
    browsers.json            - установленные и запущенные браузеры;
    users/<user>/<browser>/<profile>/
        Bookmarks            - закладки Chromium-браузеров (JSON);
        History + -wal/-shm  - история Chromium-браузеров (SQLite);
        places.sqlite + ...  - история и закладки Firefox (SQLite);
        meta.json            - что и откуда скопировано.
    warnings.txt             - проблемы доступа (если были).

  НЕ собираются: Cookies, Login Data, Web Data, Local State и прочие
  файлы с паролями/токенами. Только история и закладки.

.PARAMETER OutputZip
  Полный путь к итоговому ZIP. Каталог создаётся автоматически.

.PARAMETER SkipHistory
  Не копировать базы истории.

.PARAMETER SkipBookmarks
  Не копировать закладки.

.PARAMETER KeepWork
  Оставить рабочий каталог (по умолчанию удаляется).

.PARAMETER WorkDir
  Рабочий каталог. По умолчанию C:\ProgramData\RMMAudit\work.

.PARAMETER SkipProfiles
  Не обходить профили пользователей (только система, процессы и браузеры).

.NOTES
  Требуется PowerShell 5.1+ и права локального администратора.
  Версия формата: 1.1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputZip,

    [switch]$SkipHistory,
    [switch]$SkipBookmarks,
    [switch]$SkipProfiles,
    [switch]$KeepWork,

    [string]$WorkDir = (Join-Path $env:ProgramData 'RMMAudit\work')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# На 32-битной Windows ProgramFiles(x86) пуст: для поиска exe
# используем основной Program Files, чтобы Join-Path не падал.
$pf86 = ${env:ProgramFiles(x86)}
if (-not $pf86) { $pf86 = $env:ProgramFiles }

$script:Warnings = New-Object System.Collections.Generic.List[string]

function Add-Warning {
    param([string]$Message)
    $script:Warnings.Add($Message) | Out-Null
    Write-Warning $Message
}

function Copy-SharedFile {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) { return $false }

    $dir = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $srcStream = $null
    $dstStream = $null
    try {
        # Браузер держит файл открытым. FileShare.ReadWrite|Delete позволяет
        # прочитать его, не останавливая браузер.
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $srcStream = [System.IO.File]::Open($Source, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
        $dstStream = [System.IO.File]::Create($Destination)
        $srcStream.CopyTo($dstStream)
        return $true
    }
    catch {
        Add-Warning ("Не удалось скопировать {0}: {1}" -f $Source, $_.Exception.Message)
        return $false
    }
    finally {
        if ($dstStream) { $dstStream.Dispose() }
        if ($srcStream) { $srcStream.Dispose() }
    }
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )
    $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

# --- 1. Проверка прав -------------------------------------------------------
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Нужны права локального администратора: учётная запись '$($identity.Name)' ими не обладает."
}

# --- 2. Рабочий каталог -----------------------------------------------------
if (Test-Path -LiteralPath $WorkDir) {
    Remove-Item -LiteralPath $WorkDir -Recurse -Force
}
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
$usersRoot = Join-Path $WorkDir 'users'
New-Item -ItemType Directory -Path $usersRoot -Force | Out-Null

$startedAt = Get-Date

# --- 3. Система и нагрузка --------------------------------------------------
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$cpuInfo = Get-CimInstance Win32_Processor | Select-Object -First 1
$timeZone = Get-TimeZone

$fqdn = $env:COMPUTERNAME
try { $fqdn = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName } catch { }

$ipv4 = @(
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -ne '127.0.0.1' } |
        Select-Object -ExpandProperty IPAddress
)

$disks = @(
    Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue |
        ForEach-Object {
            [pscustomobject]@{
                drive   = $_.DeviceID
                size_gb = [math]::Round($_.Size / 1GB, 1)
                free_gb = [math]::Round($_.FreeSpace / 1GB, 1)
            }
        }
)

$system = [pscustomobject]@{
    format_version     = 1
    collected_at_utc   = $startedAt.ToUniversalTime().ToString('o')
    hostname           = $env:COMPUTERNAME
    fqdn               = $fqdn
    domain             = $cs.Domain
    os                 = $os.Caption
    os_version         = $os.Version
    os_build           = $os.BuildNumber
    architecture       = $env:PROCESSOR_ARCHITECTURE
    current_user       = $identity.Name
    logged_on_user     = $cs.UserName
    last_boot          = if ($os.LastBootUpTime) { $os.LastBootUpTime.ToString('o') } else { $null }
    uptime_hours       = if ($os.LastBootUpTime) { [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1) } else { $null }
    timezone           = $timeZone.Id
    utc_offset_minutes = [int](([TimeZoneInfo]::Local.GetUtcOffset($startedAt)).TotalMinutes)
    cpu                = [pscustomobject]@{
        name         = if ($cpuInfo) { $cpuInfo.Name.Trim() } else { '' }
        cores        = if ($cpuInfo) { $cpuInfo.NumberOfCores } else { $null }
        logical      = if ($cpuInfo) { $cpuInfo.NumberOfLogicalProcessors } else { $null }
        load_percent = if ($cpuInfo) { $cpuInfo.LoadPercentage } else { $null }
    }
    memory             = [pscustomobject]@{
        total_gb = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        free_gb  = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    }
    disks              = $disks
    ipv4               = $ipv4
    collector_version  = '1.1'
}
Write-JsonFile -Path (Join-Path $WorkDir 'system.json') -Value $system

# --- 4. Процессы ------------------------------------------------------------
# Проценты CPU по процессам берём из счётчиков производительности.
$cpuByPid = @{}
try {
    Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -ErrorAction Stop |
        Where-Object { $_.IDProcess -gt 0 -and $_.Name -notin @('_Total', 'Idle') } |
        ForEach-Object { $cpuByPid[[int]$_.IDProcess] = [int]$_.PercentProcessorTime }
}
catch {
    Add-Warning ("Не удалось получить проценты CPU: {0}" -f $_.Exception.Message)
}

$processes = foreach ($p in (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
    $ownerName = ''
    try {
        $owner = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop
        if ($owner.UserName) {
            $ownerName = if ($owner.Domain) { "$($owner.Domain)\$($owner.UserName)" } else { $owner.UserName }
        }
    }
    catch { }

    $cpuSeconds = $null
    if ($null -ne $p.KernelModeTime -and $null -ne $p.UserModeTime) {
        $cpuSeconds = [math]::Round((($p.KernelModeTime + $p.UserModeTime) / 10000000), 1)
    }

    [pscustomobject]@{
        name           = $p.Name
        pid            = [int]$p.ProcessId
        ppid           = [int]$p.ParentProcessId
        user           = $ownerName
        session_id     = $p.SessionId
        working_set_mb = if ($p.WorkingSetSize) { [math]::Round($p.WorkingSetSize / 1MB, 1) } else { 0 }
        private_mb     = if ($p.PrivatePageCount) { [math]::Round($p.PrivatePageCount / 1MB, 1) } else { 0 }
        cpu_seconds    = $cpuSeconds
        cpu_percent    = if ($cpuByPid.ContainsKey([int]$p.ProcessId)) { $cpuByPid[[int]$p.ProcessId] } else { $null }
        start_time     = if ($p.CreationDate) { $p.CreationDate.ToString('o') } else { $null }
        path           = $p.ExecutablePath
        command_line   = $p.CommandLine
    }
}
$processes |
    Sort-Object working_set_mb -Descending |
    Export-Csv -LiteralPath (Join-Path $WorkDir 'processes.csv') -NoTypeInformation -Encoding UTF8

# --- 5. Браузеры ------------------------------------------------------------
$browserDefs = @(
    @{
        key = 'chrome'; name = 'Google Chrome'; mode = 'chromium'
        data = 'Google\Chrome\User Data'
        exes = @('chrome.exe')
        paths = @(
            (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
            (Join-Path $pf86 'Google\Chrome\Application\chrome.exe')
        )
    },
    @{
        key = 'edge'; name = 'Microsoft Edge'; mode = 'chromium'
        data = 'Microsoft\Edge\User Data'
        exes = @('msedge.exe')
        paths = @(
            (Join-Path $pf86 'Microsoft\Edge\Application\msedge.exe'),
            (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
        )
    },
    @{
        key = 'yandex'; name = 'Yandex Browser'; mode = 'chromium'
        data = 'Yandex\YandexBrowser\User Data'
        exes = @('browser.exe')
        paths = @(
            (Join-Path $env:LOCALAPPDATA 'Yandex\YandexBrowser\Application\browser.exe'),
            (Join-Path $env:ProgramFiles 'Yandex\YandexBrowser\Application\browser.exe')
        )
    },
    @{
        key = 'brave'; name = 'Brave'; mode = 'chromium'
        data = 'BraveSoftware\Brave-Browser\User Data'
        exes = @('brave.exe')
        paths = @(
            (Join-Path $env:ProgramFiles 'BraveSoftware\Brave-Browser\Application\brave.exe'),
            (Join-Path $pf86 'BraveSoftware\Brave-Browser\Application\brave.exe')
        )
    },
    @{
        key = 'vivaldi'; name = 'Vivaldi'; mode = 'chromium'
        data = 'Vivaldi\User Data'
        exes = @('vivaldi.exe')
        paths = @(
            (Join-Path $env:LOCALAPPDATA 'Vivaldi\Application\vivaldi.exe'),
            (Join-Path $env:ProgramFiles 'Vivaldi\Application\vivaldi.exe')
        )
    },
    @{
        key = 'chromium'; name = 'Chromium'; mode = 'chromium'
        data = 'Chromium\User Data'
        exes = @('chromium.exe')
        paths = @(
            (Join-Path $env:LOCALAPPDATA 'Chromium\Application\chrome.exe')
        )
    },
    @{
        key = 'opera'; name = 'Opera'; mode = 'single'; base = 'roaming'
        data = 'Opera Software\Opera Stable'
        exes = @('opera.exe')
        paths = @(
            (Join-Path $env:LOCALAPPDATA 'Programs\Opera\opera.exe'),
            (Join-Path $pf86 'Opera\opera.exe')
        )
    },
    @{
        key = 'operagx'; name = 'Opera GX'; mode = 'single'; base = 'roaming'
        data = 'Opera Software\Opera GX Stable'
        exes = @('opera.exe')
        paths = @(
            (Join-Path $env:LOCALAPPDATA 'Programs\Opera GX\opera.exe'),
            (Join-Path $pf86 'Opera GX\opera.exe')
        )
    }
)

$browserExeNames = @($browserDefs | ForEach-Object { $_.exes } | Sort-Object -Unique)

$installed = @()
foreach ($def in $browserDefs) {
    $exe = $def.paths | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if ($exe) {
        $version = ''
        try { $version = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion } catch { }
        $installed += [pscustomobject]@{
            name = $def.name
            key  = $def.key
            exe  = $exe
            version = $version
        }
    }
}

# Firefox ставится в Program Files, версию берём из exe.
$firefoxExe = @(
    (Join-Path $env:ProgramFiles 'Mozilla Firefox\firefox.exe'),
    (Join-Path $pf86 'Mozilla Firefox\firefox.exe')
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if ($firefoxExe) {
    $version = ''
    try { $version = (Get-Item -LiteralPath $firefoxExe).VersionInfo.FileVersion } catch { }
    $installed += [pscustomobject]@{
        name = 'Mozilla Firefox'
        key  = 'firefox'
        exe  = $firefoxExe
        version = $version
    }
}

$running = @(
    $processes |
        Where-Object { $browserExeNames -contains $_.name -or $_.name -eq 'firefox.exe' } |
        Select-Object name, pid, user, session_id, working_set_mb, cpu_percent, start_time, path, command_line
)

# Браузер мог быть поставлен в профиль конкретного пользователя
# (%LOCALAPPDATA%\Programs\...), а мы искали exe в Program Files.
# Если он сейчас запущен — добавляем его в список установленных по пути.
$installedExe = @{}
foreach ($b in $installed) {
    if ($b.exe) { $installedExe[$b.exe.ToLower()] = $true }
}
foreach ($proc in $running) {
    if (-not $proc.path) { continue }
    $exeKey = $proc.path.ToLower()
    if ($installedExe.ContainsKey($exeKey)) { continue }
    if (-not (Test-Path -LiteralPath $proc.path)) { continue }
    $def = $browserDefs | Where-Object { $_.exes -contains $proc.name } | Select-Object -First 1
    $version = ''
    try { $version = (Get-Item -LiteralPath $proc.path).VersionInfo.FileVersion } catch { }
    $installed += [pscustomobject]@{
        name    = if ($def) { $def.name } else { $proc.name }
        key     = if ($def) { $def.key } else { 'other' }
        exe     = $proc.path
        version = $version
    }
    $installedExe[$exeKey] = $true
}

Write-JsonFile -Path (Join-Path $WorkDir 'browsers.json') -Value ([pscustomobject]@{
    installed     = @($installed)
    running       = @($running)
    running_count = @($running).Count
})

# --- 6. Профили и данные браузеров -----------------------------------------
$excludedUsers = @('Public', 'Default', 'Default User', 'All Users', 'defaultuser0')

# Профили берём из реестра: так находятся и перенесённые каталоги
# (например, D:\Users\ivan), а не только C:\Users.
$userDirs = @()
$profileList = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
foreach ($key in (Get-ChildItem -LiteralPath $profileList -ErrorAction SilentlyContinue)) {
    $image = (Get-ItemProperty -LiteralPath $key.PSPath -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
    if (-not $image) { continue }
    if (-not (Test-Path -LiteralPath $image)) { continue }
    # SYSTEM, LocalService, NetworkService и прочие служебные профили.
    if ($image -like "$env:SystemRoot\*") { continue }
    $leaf = Split-Path -Leaf $image
    if ($excludedUsers -contains $leaf) { continue }
    $userDirs += [pscustomobject]@{ Name = $leaf; FullName = $image }
}
if ($userDirs.Count -eq 0) {
    $userDirs = @(
        Get-ChildItem -LiteralPath 'C:\Users' -Directory -ErrorAction SilentlyContinue |
            Where-Object { $excludedUsers -notcontains $_.Name } |
            ForEach-Object { [pscustomobject]@{ Name = $_.Name; FullName = $_.FullName } }
    )
}

$copiedProfiles = 0

if (-not $SkipProfiles) {
foreach ($userDir in $userDirs) {
    $userName = $userDir.Name
    $localAppData = Join-Path $userDir.FullName 'AppData\Local'
    $roamingAppData = Join-Path $userDir.FullName 'AppData\Roaming'

    foreach ($def in $browserDefs) {
        # Opera (и GX) хранят профиль в Roaming, остальные — в Local.
        $appData = $localAppData
        if ($def.ContainsKey('base') -and $def.base -eq 'roaming') {
            $appData = $roamingAppData
        }
        $root = Join-Path $appData $def.data
        if (-not (Test-Path -LiteralPath $root)) { continue }

        if ($def.mode -eq 'single') {
            $profiles = @(Get-Item -LiteralPath $root)
        }
        else {
            $profiles = @(
                Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                    Where-Object {
                        ($_.Name -eq 'Default' -or $_.Name -like 'Profile *') -and
                        $_.Name -notin @('Guest Profile', 'System Profile')
                    }
            )
        }

        foreach ($profile in $profiles) {
            $dest = Join-Path $usersRoot (Join-Path $userName (Join-Path $def.name $profile.Name))
            $copied = @()

            if (-not $SkipBookmarks) {
                $bookmarks = Join-Path $profile.FullName 'Bookmarks'
                if (Copy-SharedFile -Source $bookmarks -Destination (Join-Path $dest 'Bookmarks')) {
                    $copied += 'Bookmarks'
                }
            }

            if (-not $SkipHistory) {
                $history = Join-Path $profile.FullName 'History'
                if (Copy-SharedFile -Source $history -Destination (Join-Path $dest 'History')) {
                    $copied += 'History'
                    # WAL/SHM и старый журнал нужны, чтобы SQLite смог
                    # восстановить свежие записи.
                    foreach ($suffix in @('-wal', '-shm', '-journal')) {
                        if (Test-Path -LiteralPath "$history$suffix") {
                            Copy-SharedFile -Source "$history$suffix" -Destination (Join-Path $dest "History$suffix") | Out-Null
                        }
                    }
                }
            }

            if ($copied.Count -gt 0) {
                $copiedProfiles++
                Write-JsonFile -Path (Join-Path $dest 'meta.json') -Value ([pscustomobject]@{
                    user    = $userName
                    browser = $def.name
                    profile = $profile.Name
                    source  = $profile.FullName
                    files   = $copied
                })
            }
        }
    }

    # Firefox: история и закладки в places.sqlite (Roaming, не Local).
    $firefoxRoot = Join-Path $roamingAppData 'Mozilla\Firefox\Profiles'
    if (Test-Path -LiteralPath $firefoxRoot) {
        foreach ($profile in (Get-ChildItem -LiteralPath $firefoxRoot -Directory -ErrorAction SilentlyContinue)) {
            if ($SkipHistory -and $SkipBookmarks) { continue }

            $dest = Join-Path $usersRoot (Join-Path $userName (Join-Path 'Mozilla Firefox' $profile.Name))
            $places = Join-Path $profile.FullName 'places.sqlite'
            if (Copy-SharedFile -Source $places -Destination (Join-Path $dest 'places.sqlite')) {
                foreach ($suffix in @('-wal', '-shm')) {
                    if (Test-Path -LiteralPath "$places$suffix") {
                        Copy-SharedFile -Source "$places$suffix" -Destination (Join-Path $dest "places.sqlite$suffix") | Out-Null
                    }
                }
                $copiedProfiles++
                Write-JsonFile -Path (Join-Path $dest 'meta.json') -Value ([pscustomobject]@{
                    user             = $userName
                    browser          = 'Mozilla Firefox'
                    profile          = $profile.Name
                    source           = $profile.FullName
                    files            = @('places.sqlite')
                    include_history  = (-not $SkipHistory)
                    include_bookmarks = (-not $SkipBookmarks)
                })
            }
        }
    }
}
}  # SkipProfiles

# --- 7. Предупреждения ------------------------------------------------------
if ($script:Warnings.Count -gt 0) {
    $script:Warnings | Set-Content -LiteralPath (Join-Path $WorkDir 'warnings.txt') -Encoding UTF8
}

# --- 8. Упаковка ------------------------------------------------------------
$zipDir = Split-Path -Parent $OutputZip
if ($zipDir -and -not (Test-Path -LiteralPath $zipDir)) {
    New-Item -ItemType Directory -Path $zipDir -Force | Out-Null
}
if (Test-Path -LiteralPath $OutputZip) {
    Remove-Item -LiteralPath $OutputZip -Force
}

Compress-Archive -Path (Join-Path $WorkDir '*') -DestinationPath $OutputZip -CompressionLevel Optimal

$result = [pscustomobject]@{
    host           = $env:COMPUTERNAME
    zip            = $OutputZip
    size_bytes     = (Get-Item -LiteralPath $OutputZip).Length
    users          = $userDirs.Count
    profiles       = $copiedProfiles
    processes      = @($processes).Count
    warnings       = @($script:Warnings)
}
$result | ConvertTo-Json -Depth 4 -Compress

if (-not $KeepWork) {
    Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}
