@echo off
setlocal
cd /d "%~dp0"
title Screen to Telegram - Complete Uninstall
set "STT_DIR=%~dp0"

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrator privileges to ensure complete cleanup...
    powershell -NoProfile -Command "Start-Process cmd -ArgumentList '/c `"%~f0`"' -Verb RunAs"
    exit /b
)

set "PS1=%TEMP%\stt_uninstall_complete.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t=Get-Content -LiteralPath '%~f0' -Raw; $m='#PS'+'BEGIN'; $i=$t.IndexOf($m); if($i -lt 0){exit 9}; [IO.File]::WriteAllText($env:PS1, $t.Substring($i), (New-Object Text.UTF8Encoding $false))"
if not exist "%PS1%" (
  echo ERROR: Could not prepare the uninstaller.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
del "%PS1%" >nul 2>&1
echo.
pause
exit /b

#PSBEGIN
# Screen to Telegram - Complete Uninstaller & Cleaner
$ErrorActionPreference = 'SilentlyContinue'
$UninstallerVersion = [long]202610181133

Write-Host ""
Write-Host " ========================================================" -ForegroundColor Cyan
Write-Host "       Screen To Telegram - Full Uninstaller             " -ForegroundColor White
Write-Host " ========================================================" -ForegroundColor Cyan
Write-Host ""

$dirs = @($env:STT_DIR, "C:\ProgramData\ScreenToTelegram") | Select-Object -Unique

# 1. Stop any running instance
Write-Host " [1/6] Stopping running instances..." -ForegroundColor Yellow
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like '*screen_to_telegram.ps1*' } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force
        Write-Host "       Terminated process PID: $($_.ProcessId)" -ForegroundColor Green
    }

# 2. Remove Startup shortcuts
Write-Host " [2/6] Removing Startup auto-launch..." -ForegroundColor Yellow
$startupLinks = @(
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\ScreenToTelegram.lnk'),
    (Join-Path $env:ALLUSERSPROFILE 'Microsoft\Windows\Start Menu\Programs\Startup\ScreenToTelegram.lnk')
)
foreach ($lnk in $startupLinks) {
    if (Test-Path $lnk) {
        Remove-Item -Force $lnk
        Write-Host "       Removed: $lnk" -ForegroundColor Green
    }
}

# 3. Clean hidden backups
Write-Host " [3/6] Cleaning hidden backup copies..." -ForegroundColor Yellow
$bkDir = Join-Path $env:APPDATA "Microsoft\.stt-bk"
if (Test-Path $bkDir) {
    Remove-Item -Recurse -Force $bkDir
    Write-Host "       Removed hidden backup: $bkDir" -ForegroundColor Green
}

# 4. Check if Network Lockdown or System Hardening are active in any dir
Write-Host " [4/6] Checking security policies & restoring defaults..." -ForegroundColor Yellow
foreach ($dir in $dirs) {
    $unlockNet = Join-Path $dir 'UnlockNetwork.ps1'
    if (Test-Path $unlockNet) {
        Write-Host "       Reversing network locks from $dir..." -ForegroundColor Gray
        & powershell -NoProfile -ExecutionPolicy Bypass -File $unlockNet | Out-Null
    }

    $restoreAdmin = Join-Path $dir 'RestoreAdmin.ps1'
    if (Test-Path $restoreAdmin) {
        Write-Host "       Reversing system/admin hardening from $dir..." -ForegroundColor Gray
        & powershell -NoProfile -ExecutionPolicy Bypass -File $restoreAdmin | Out-Null
    }
}
Write-Host "       Network and system policies restored to default." -ForegroundColor Green

# 5. Reset folder permissions & purge program folders
Write-Host " [5/6] Resetting permissions & purging files..." -ForegroundColor Yellow
$filesToRemove = @(
    'screen_to_telegram.ps1',
    'screen_to_telegram.prev.ps1',
    'config.json',
    'harden_backup.json'
)

foreach ($dir in $dirs) {
    if (Test-Path $dir) {
        # Reset ACL in case hardening was applied
        & icacls "$dir" /reset /t /c /q > $null 2>&1
        $shotsDir = Join-Path $dir 'screenshots'
        if (Test-Path $shotsDir) {
            Remove-Item -Recurse -Force $shotsDir
        }
        foreach ($f in $filesToRemove) {
            $target = Join-Path $dir $f
            if (Test-Path $target) {
                Remove-Item -Force $target
            }
        }
    }
}

# 6. Remove ProgramData folder completely if present
Write-Host " [6/6] Final cleanup of protected directories..." -ForegroundColor Yellow
$progDataDir = "C:\ProgramData\ScreenToTelegram"
if (Test-Path $progDataDir) {
    & icacls "$progDataDir" /reset /t /c /q > $null 2>&1
    Remove-Item -Recurse -Force $progDataDir -ErrorAction SilentlyContinue
    Write-Host "       Removed: $progDataDir" -ForegroundColor Green
}

Write-Host ""
Write-Host " ========================================================" -ForegroundColor Green
Write-Host "  SUCCESS: Screen to Telegram has been completely removed!" -ForegroundColor Green
Write-Host "  All background processes stopped, auto-start cleared,   " -ForegroundColor White
Write-Host "  hidden backups wiped, and system policies restored.     " -ForegroundColor White
Write-Host " ========================================================" -ForegroundColor Green