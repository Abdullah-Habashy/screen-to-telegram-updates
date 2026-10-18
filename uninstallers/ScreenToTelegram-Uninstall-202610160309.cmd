@echo off
setlocal
cd /d "%~dp0"
title Screen to Telegram - Uninstall
set "STT_DIR=%~dp0"

rem ============================================================================
rem  This uninstaller removes the install sitting next to it. It removes only an
rem  install whose version is THIS or older; a newer install (for example one
rem  pulled in by auto-update) is refused, so an out-of-date uninstaller can
rem  never strip a newer install. publish.ps1 stamps the version for each release.
rem ============================================================================

set "PS1=%TEMP%\stt_uninstall.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t=Get-Content -LiteralPath '%~f0' -Raw; $m='#PS'+'BEGIN'; $i=$t.IndexOf($m); if($i -lt 0){exit 9}; [IO.File]::WriteAllText($env:PS1, $t.Substring($i), (New-Object Text.UTF8Encoding $false))"
if not exist "%PS1%" (
  echo ERROR: could not prepare the uninstaller.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
del "%PS1%" >nul 2>&1
echo.
pause
exit /b

#PSBEGIN
# Screen to Telegram uninstaller (embedded PowerShell).
$ErrorActionPreference = 'SilentlyContinue'

# This uninstaller may remove ONLY an install whose version is this or older.
# publish.ps1 stamps the real version here for each release.
$UninstallerVersion = [long]202610160309

$dir = $env:STT_DIR
$script = Join-Path $dir 'screen_to_telegram.ps1'

# Read the installed version straight from the script.
$installed = $null
if (Test-Path $script) {
    $text = Get-Content -Raw $script
    if ($text -match '(?m)^\$ScriptVersion = (\d+)\s*$') { $installed = [long]$Matches[1] }
}

if ($null -ne $installed -and $installed -gt $UninstallerVersion) {
    Write-Host "REFUSED: the installed version ($installed) is newer than this uninstaller ($UninstallerVersion)." -ForegroundColor Yellow
    Write-Host "Use the Uninstall file that shipped with the newer version."
    exit 3
}

# Stop any running copy (powershell running our script).
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like '*screen_to_telegram.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

# Remove the auto-start shortcut.
$startupLink = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\ScreenToTelegram.lnk'
Remove-Item -Force $startupLink

# Remove this version's program files (config holds the bot token, so it goes too).
Remove-Item -Force (Join-Path $dir 'screen_to_telegram.ps1')
Remove-Item -Force (Join-Path $dir 'screen_to_telegram.prev.ps1')
Remove-Item -Force (Join-Path $dir 'config.json')
Remove-Item -Recurse -Force (Join-Path $dir 'screenshots')

$removed = if ($null -ne $installed) { $installed } else { $UninstallerVersion }
Write-Host "Removed Screen to Telegram (version $removed)." -ForegroundColor Green
Write-Host "Auto-start entry removed and the running copy was stopped."
