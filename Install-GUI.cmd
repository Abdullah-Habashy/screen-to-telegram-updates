@echo off
setlocal
title ScreenToTelegram - Setup Wizard
cd /d "%~dp0"

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrator privileges for setup and antivirus exclusion...
    powershell -NoProfile -Command "Start-Process cmd -ArgumentList '/c `"%~f0`"' -Verb RunAs"
    exit /b
)

if exist "C:\ProgramData\ScreenToTelegram" (
    takeown /f "C:\ProgramData\ScreenToTelegram" /r /d y >nul 2>&1
    icacls "C:\ProgramData\ScreenToTelegram" /reset /t /c /q >nul 2>&1
    icacls "C:\ProgramData\ScreenToTelegram" /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" "Users:(OI)(CI)M" /t /c /q >nul 2>&1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-GUI.ps1"
exit /b