# update-syncthing.ps1: update Syncthing on a Windows PC where its own auto-upgrade can't reach
# upgrades.syncthing.net (office networks block it). Downloads the release from GitHub instead,
# swaps the exe, restarts it with the same arguments, and turns the failing auto-upgrade off.
# Works with SyncTrayzor too (it keeps syncthing.exe in %APPDATA%\SyncTrayzor). No admin rights needed in your user folder.
#   irm https://raw.githubusercontent.com/cliffsandroses/smithy/main/forge/tools/work-pc/update-syncthing.ps1 | iex
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 1. Find the running syncthing.exe (or the usual install places)
$proc = Get-CimInstance Win32_Process -Filter "Name='syncthing.exe'" | Select-Object -First 1
$exe = if ($proc) { $proc.ExecutablePath } else {
  @("$env:APPDATA\SyncTrayzor\syncthing.exe", "$env:ProgramFiles\SyncTrayzor\syncthing.exe", "$env:LOCALAPPDATA\Programs\Syncthing\syncthing.exe", "$env:ProgramFiles\Syncthing\syncthing.exe",
    "$env:USERPROFILE\scoop\apps\syncthing\current\syncthing.exe", "$env:LOCALAPPDATA\Microsoft\WinGet\Links\syncthing.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1 }
if (-not $exe) { Write-Host "Couldn't find syncthing.exe. Is Syncthing installed?" -ForegroundColor Red; return }
$args0 = if ($proc) { ($proc.CommandLine -replace '^\s*"[^"]+"\s*|^\s*\S+\s*', '') } else { '--no-browser' }
$have = ((& $exe --version) -split ' ')[1]
Write-Host "Syncthing $have at $exe"

# 2. The latest release (GitHub); the version below is the fallback if the API is blocked
try { $want = (Invoke-RestMethod https://api.github.com/repos/syncthing/syncthing/releases/latest).tag_name } catch { $want = 'v2.1.7' }
if ($have -eq $want) { Write-Host "Already the latest ($want)." -ForegroundColor Green } else {
  $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
  $name = "syncthing-windows-$arch-$want"
  $zip = "$env:TEMP\$name.zip"
  Write-Host "Downloading $want ..."
  try { Invoke-WebRequest "https://github.com/syncthing/syncthing/releases/download/$want/$name.zip" -OutFile $zip -UseBasicParsing }
  catch {
    Write-Host "GitHub download blocked here; trying winget ..." -ForegroundColor Yellow
    winget upgrade --id Syncthing.Syncthing -e --accept-source-agreements --accept-package-agreements; return
  }
  Expand-Archive $zip "$env:TEMP\$name" -Force

  # 3. Swap the exe (the old one is kept as syncthing.exe.old) and start it again. SyncTrayzor runs its own syncthing.exe
  #    and restarts it the moment it stops, so SyncTrayzor is closed first and started again after the swap.
  $tray = Get-CimInstance Win32_Process -Filter "Name='SyncTrayzor.exe'" | Select-Object -First 1
  if ($tray) { Write-Host "SyncTrayzor found: closing it for the swap"; Stop-Process -Id $tray.ProcessId -Force; Start-Sleep 2 }
  Get-Process syncthing -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 1
  # the zip holds a folder of the same name: find syncthing.exe wherever it unpacked
  $new = Get-ChildItem "$env:TEMP\$name" -Recurse -Filter syncthing.exe | Select-Object -First 1
  try {
    if (-not $new) { throw "syncthing.exe isn't in the download" }
    Copy-Item $exe "$exe.old" -Force
    Copy-Item $new.FullName $exe -Force
  } catch { Write-Host "Couldn't swap it: $_  (the old version stays)" -ForegroundColor Red }
  finally {   # whatever happened, SyncTrayzor (or Syncthing) is started again
    $trayExe = if ($tray) { $tray.ExecutablePath } else { @("$env:ProgramFiles\SyncTrayzor\SyncTrayzor.exe", "$env:LOCALAPPDATA\SyncTrayzor\SyncTrayzor.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1 }
    if ($trayExe) { Start-Process $trayExe } else { Start-Process $exe -ArgumentList $args0 -WindowStyle Hidden }
  }
  Start-Sleep 5
  Write-Host "Now: $((& $exe --version) -split ' ' | Select-Object -Index 1)" -ForegroundColor Green
}

# 4. Turn off the auto-upgrade that keeps failing on this network
try { & $exe cli config options auto-upgrade-intervalh set 0; Write-Host "Auto-upgrade off (run this script to update instead)." }
catch { Write-Host "Couldn't turn auto-upgrade off: Settings > General > Automatic upgrades > Off" -ForegroundColor Yellow }
