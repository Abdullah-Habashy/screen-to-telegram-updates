@echo off
title Fix Permissions - ScreenToTelegram
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrator privileges to fix permissions...
    powershell -NoProfile -Command "Start-Process cmd -ArgumentList '/c `"%~f0`"' -Verb RunAs"
    exit /b
)
echo Resetting permissions on C:\ProgramData\ScreenToTelegram...
takeown /f "C:\ProgramData\ScreenToTelegram" /r /d y >nul 2>&1
icacls "C:\ProgramData\ScreenToTelegram" /reset /t /c /q >nul 2>&1
icacls "C:\ProgramData\ScreenToTelegram" /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" "Users:(OI)(CI)M" /t /c /q >nul 2>&1
echo Permissions fixed successfully! The program can now run and send screenshots.
echo.
pause