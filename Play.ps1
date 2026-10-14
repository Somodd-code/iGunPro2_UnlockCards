param([switch]$Fix)

# ===============================================================
#  EDIT THESE SETTINGS (everything else is automatic)
# ===============================================================
$ApkUrl      = ''                 # direct download link to your patched APK (leave empty to use a local game.apk)
$Device      = 'localhost:6520'   # adb address of the Google Play Games developer emulator
$GamePackage = ''                 # leave empty: detected automatically on first run
$ProxyPort   = 8080
# ===============================================================

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'   # makes downloads much faster in Windows PowerShell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Here   = $PSScriptRoot
$Tools  = Join-Path $Here 'tools'
$Data   = Join-Path $Here 'data'
New-Item -ItemType Directory -Force $Tools, $Data | Out-Null

function Say($m)  { Write-Host "`n$m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "`n  [PROBLEM] $m" -ForegroundColor Red }

# ---------------- adb ----------------
function Get-Adb {
    $found = (Get-Command adb -ErrorAction SilentlyContinue).Source
    if ($found) { return $found }
    $local = Join-Path $Tools 'adb.exe'
    if (Test-Path $local) { return $local }

    Say 'Downloading adb (small, about 10 MB)...'
    $zip = Join-Path $env:TEMP 'platform-tools.zip'
    Invoke-WebRequest 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' -OutFile $zip -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    foreach ($name in 'adb.exe', 'AdbWinApi.dll', 'AdbWinUsbApi.dll') {
        $entry = $archive.Entries | Where-Object FullName -eq "platform-tools/$name"
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $Tools $name), $true)
    }
    $archive.Dispose()
    Remove-Item $zip -ErrorAction SilentlyContinue
    Ok 'adb ready.'
    return $local
}

# ---------------- mitmproxy ----------------
function Find-Mitmweb {
    $cmd = Get-Command mitmweb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        (Join-Path $Tools 'mitmproxy\bin\mitmweb.exe'),
        (Join-Path $env:ProgramFiles 'mitmproxy\bin\mitmweb.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\mitmproxy\bin\mitmweb.exe')
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    $f = Get-ChildItem $Tools -Recurse -Filter mitmweb.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { return $f.FullName }
    return $null
}

function Install-Mitm {
    Say 'Downloading mitmproxy (about 50 MB, one time only)...'
    $version = '12.1.2'   # fallback if the lookup below fails
    try {
        $rel = Invoke-RestMethod 'https://api.github.com/repos/mitmproxy/mitmproxy/releases/latest' -Headers @{ 'User-Agent' = 'mitm-helper' } -ErrorAction Stop
        $version = $rel.tag_name.TrimStart('v')
    } catch { }
    $url = "https://downloads.mitmproxy.org/$version/mitmproxy-$version-windows-x86_64-installer.exe"
    $exe = Join-Path $env:TEMP 'mitmproxy-installer.exe'
    Invoke-WebRequest $url -OutFile $exe -ErrorAction Stop

    Say 'Installing mitmproxy (this can take a minute)...'
    $prefix = Join-Path $Tools 'mitmproxy'
    Start-Process $exe -ArgumentList "--mode unattended --unattendedmodeui none --prefix `"$prefix`"" -Wait
    $m = Find-Mitmweb
    if (-not $m) {
        Warn 'Quiet install did not work. An installer window will open: just keep clicking Next / Install.'
        Start-Process $exe -Wait
        $m = Find-Mitmweb
    }
    Remove-Item $exe -ErrorAction SilentlyContinue
    return $m
}

# ---------------- APK ----------------
function Get-Apk {
    foreach ($p in (Join-Path $Here 'game.apk'), (Join-Path $Data 'game.apk')) {
        if (Test-Path $p) { return $p }
    }
    if (-not $ApkUrl) { return $null }
    Say 'Downloading the game...'
    $dest = Join-Path $Data 'game.apk'
    Invoke-WebRequest $ApkUrl -OutFile $dest -ErrorAction Stop
    Ok 'Game downloaded.'
    return $dest
}

# ---------------- emulator ----------------
function Wait-Emulator([int]$maxTries = 100) {
    $tries = 0
    $bootSeen = 0
    while ($true) {
        & $script:Adb connect $script:Device 2>$null | Out-Null
        $lines = @(& $script:Adb devices 2>$null | Select-Object -Skip 1 | Where-Object { $_ -match '\S' })
        $ready = @($lines | Where-Object { $_ -match '\sdevice$' })

        # use the configured address if it is there, otherwise any emulator adb can see
        $pick = $ready | Where-Object { $_ -like "$($script:Device)*" } | Select-Object -First 1
        if (-not $pick) { $pick = $ready | Select-Object -First 1 }

        if ($pick) {
            $script:Device = ($pick -split '\s+')[0]
            $boot = (& $script:Adb -s $script:Device shell getprop sys.boot_completed 2>$null) -join ''
            $bootSeen++
            # accept after a few tries even if the boot flag is not reported
            if ($boot.Trim() -eq '1' -or $bootSeen -gt 10) { return $true }
        }

        if ($tries -eq 0) { Warn 'Waiting for the emulator... please open it now and let it fully start.' }
        if ($tries -eq 5) {
            Warn 'Restarting the connection tool...'
            & $script:Adb kill-server 2>$null | Out-Null
            & $script:Adb start-server 2>$null | Out-Null
        }
        if ($tries -gt 0 -and $tries % 10 -eq 0) {
            Warn ('adb currently sees: ' + $(if ($lines.Count) { $lines -join ' | ' } else { 'nothing' }))
        }
        $tries++
        if ($tries -gt $maxTries) { return $false }
        Start-Sleep -Seconds 3
    }
}

function Sh { & $script:Adb -s $Device shell @args 2>$null }

function Get-HostIp {
    $route = (Sh ip route) -join "`n"
    if ($route -match 'default via (\d+\.\d+\.\d+\.\d+)') { return $Matches[1] }
    return (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -ne '127.0.0.1' } |
        Select-Object -First 1 -ExpandProperty IPAddress)
}

function Clear-Proxy {
    Sh settings put global http_proxy :0 | Out-Null
}

# ===============================================================
#  FIX MODE (Fix-Internet.bat)
# ===============================================================
$script:Adb = Get-Adb
if ($Fix) {
    Say 'Fixing emulator internet...'
    if (Wait-Emulator 5) { Clear-Proxy; Ok 'Done. The emulator internet should work again.' }
    else { Fail 'Could not find the emulator. Open it first, then try again.' }
    return
}

# ===============================================================
#  NORMAL MODE
# ===============================================================
Clear-Host
# ---- SoModd rainbow banner ----
$art = @'
   _____                              _      _
  (        __.  , _ , _     __.    ___/   ___/
   `--.  .'   \ |' `|' `. .'   \  /   |  /   |
      |  |    | |   |   | |    | ,'   | ,'   |
 \___.'   `._.' /   '   /  `._.' `___,' `___,'
                                      `      `
'@

$lines  = $art -split "`r?`n"
$max    = ($lines | Measure-Object -Property Length -Maximum).Maximum
$colors = 'Red', 'DarkYellow', 'Yellow', 'Green', 'Cyan', 'Magenta'

# Column (0-based) where each NEW color begins: S->o, o->M, M->o, o->d, d->d
$cuts = 9, 16, 25, 33, 40

$showRuler = $false   # set to $true to find your cut columns

if ($showRuler) {
    Write-Host (-join (0..($max - 1) | ForEach-Object { if ($_ % 10 -eq 0) { [string]($_ / 10 % 10) } else { ' ' } })) -ForegroundColor DarkGray
    Write-Host (-join (0..($max - 1) | ForEach-Object { $_ % 10 })) -ForegroundColor DarkGray
}

Write-Host ''
foreach ($line in $lines) {
    $line = $line.PadRight($max)
    for ($c = 0; $c -lt $max; $c++) {
        $idx = @($cuts | Where-Object { $c -ge $_ }).Count
        Write-Host $line[$c] -NoNewline -ForegroundColor $colors[$idx]
    }
    Write-Host ''
}
Write-Host ''

# ---- Your original header ----
Write-Host '==============================================' -ForegroundColor Cyan
Write-Host '   Card Reader Helper'
Write-Host '==============================================' -ForegroundColor Cyan
Write-Host ' Please open your emulator first.'

$firstRun = -not (Test-Path (Join-Path $Data 'setup-done'))

# 1. tools
$mitmweb = Find-Mitmweb
if (-not $mitmweb) { $mitmweb = Install-Mitm }
if (-not $mitmweb) {
    Fail 'Could not install mitmproxy automatically. Please install it from https://mitmproxy.org and run this again.'
    return
}
$mitmdump = Join-Path (Split-Path $mitmweb) 'mitmdump.exe'
Ok 'Tools ready.'

# 2. emulator
Say 'Looking for the emulator...'
if (-not (Wait-Emulator)) {
    Fail 'The emulator was not found. Open it, wait for the Android screen, then run this again.'
    Write-Host '  If it is open, the adb address may be different. Run "adb devices" and put it at the top of Play.ps1.'
    return
}
Ok 'Emulator connected.'

# 3. first-time setup
if ($firstRun) {
    Say 'First-time setup (only happens once)...'

    $apk = Get-Apk
    if (-not $apk) {
        Fail 'No game file found. Put your APK in this folder and name it game.apk, then run this again.'
        return
    }

    # certificate
    $cert = Join-Path $env:USERPROFILE '.mitmproxy\mitmproxy-ca-cert.cer'
    if (-not (Test-Path $cert)) {
        $p = Start-Process $mitmdump -ArgumentList '--listen-port', '8099' -PassThru -WindowStyle Hidden
        Start-Sleep -Seconds 5
        Stop-Process $p -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path $cert)) { Fail 'Could not create the certificate. Run this again.'; return }
    & $script:Adb -s $Device push $cert /sdcard/Download/mitmproxy-ca-cert.cer 2>$null | Out-Null
    Ok 'Certificate copied to the emulator.'

    # install game and detect its package name
    $before = @(Sh pm list packages -3)
    Say 'Installing the game...'
    & $script:Adb -s $Device install -r $apk
    $after = @(Sh pm list packages -3)
    if (-not $GamePackage) {
        $new = Compare-Object $before $after | Where-Object SideIndicator -eq '=>' | Select-Object -First 1
        if ($new) {
            $GamePackage = ($new.InputObject -replace '^package:', '').Trim()
        }
    }
    if ($GamePackage) { Set-Content (Join-Path $Data 'package.txt') $GamePackage }

    # the one step Android makes people do themselves
    Sh am start -a android.settings.SECURITY_SETTINGS | Out-Null
    Write-Host ''
    Write-Host '  ------------------------------------------------------------' -ForegroundColor Yellow
    Write-Host '   ONE STEP YOU HAVE TO DO YOURSELF (only once):' -ForegroundColor Yellow
    Write-Host '   In the emulator, it should be on security settings'
    Write-Host '   Click: More security & privacy > Encryption and credentials'
    Write-Host '   > Install a certificate > CA certificate > install anyway'
    Write-Host '   > 3 bars in top left > downloads > only file there'
    Write-Host '  ------------------------------------------------------------' -ForegroundColor Yellow
    Read-Host '  When you have done that, press Enter here'
    Set-Content (Join-Path $Data 'setup-done') 'ok'
}

if (-not $GamePackage -and (Test-Path (Join-Path $Data 'package.txt'))) {
    $GamePackage = (Get-Content (Join-Path $Data 'package.txt') -Raw).Trim()
}

# 4. start everything
$hostIp = Get-HostIp
Sh settings put global http_proxy "${hostIp}:$ProxyPort" | Out-Null
Ok 'Emulator connected to the reader.'

$args2 = @('--listen-port', $ProxyPort, '--web-port', '8081', '--set', 'web_open_browser=false')
$addon = Join-Path $Here 'addon.py'
if (Test-Path $addon) { $args2 += @('-s', $addon) }

$reader = Join-Path $Here 'reader.html'
$readerServer = Join-Path $Here 'reader-server.ps1'
$readerServerProcess = $null
if ((Test-Path $reader) -and (Test-Path $readerServer)) {
    # Serve on loopback instead of file:// so browser email services can use a
    # stable origin. This server is bound to 127.0.0.1 only, not the LAN.
    $readerServerProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$readerServer`""
    ) -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 900
    Start-Process 'http://127.0.0.1:18765/reader.html'
} elseif (Test-Path $reader) {
    Start-Process $reader
}

if ($GamePackage) {
    Sh monkey -p $GamePackage -c android.intent.category.LAUNCHER 1 | Out-Null
    Ok 'Game started.'
} else {
    Warn 'Open the game yourself inside the emulator.'
}

Write-Host ''
Write-Host '  ------------------------------------------------------------' -ForegroundColor Green
Write-Host '   RUNNING. Play the game as normal. Your reader page is open'
Write-Host '   in your browser and updates by itself.'
Write-Host '   If Windows asks about the firewall, click ALLOW.'
Write-Host '   When you are done, press Ctrl+C in this window.'
Write-Host '  ------------------------------------------------------------' -ForegroundColor Green

try {
    & $mitmweb @args2
}
finally {
    Say 'Shutting down and restoring emulator internet...'
    Clear-Proxy
    if ($readerServerProcess -and -not $readerServerProcess.HasExited) {
        Stop-Process -Id $readerServerProcess.Id -Force -ErrorAction SilentlyContinue
    }
    Ok 'Done. You can close this window.'
}
