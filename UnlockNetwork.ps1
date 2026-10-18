<#
.SYNOPSIS
    Reverses all restrictions applied by LockNetwork.ps1
    Must be run as ADMINISTRATOR.
#>

#Requires -RunAsAdministrator
$ErrorActionPreference = 'SilentlyContinue'

function W([string]$msg, [string]$c='Cyan') { Write-Host "  [-] $msg" -ForegroundColor $c }

Write-Host ""
Write-Host "  Network UNLOCK - ScreenToTelegram" -ForegroundColor Green
Write-Host ""

# ── 1. Restore RadioManagement service ───────────────────────────
Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\RmSvc" "Start" 2 -Force  # 2 = Auto
try { Start-Service -Name "RmSvc"; W "RadioManagement service restored + started" Green }
catch { W "RmSvc: $($_.Exception.Message)" Yellow }

# ── 2. Restore Action Center Quick Settings ───────────────────────
$qaBase = "HKCU:\Control Panel\Quick Actions\Control Center"
foreach ($item in @("SystemSettings_Device_AirplaneMode_SliderButton","SystemSettings_Network_WiFi_QuickAction")) {
    Remove-ItemProperty -Path "$qaBase\$item" -Name "IsEnabled" -Force -ErrorAction SilentlyContinue
    W "Restored: $item"
}

# ── 3. Remove Settings page hiding ───────────────────────────────
foreach ($p in @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer","HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer")) {
    Remove-ItemProperty -Path $p -Name "SettingsPageVisibility" -Force -ErrorAction SilentlyContinue
}
W "Network Settings pages restored"

# ── 4. Remove Network Connections restrictions ────────────────────
foreach ($nc in @("HKCU:\Software\Policies\Microsoft\Windows\Network Connections","HKLM:\SOFTWARE\Policies\Microsoft\Windows\Network Connections")) {
    foreach ($n in @("NC_DisableNetworkType","NC_EnableAdminProhibits","NC_AllowNetBridge_NLA","NC_StatsEnabled")) {
        Remove-ItemProperty -Path $nc -Name $n -Force -ErrorAction SilentlyContinue
    }
}
Remove-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoNetworkConnections" -Force -ErrorAction SilentlyContinue
W "ncpa.cpl access restored"

# ── 5. Restore Device Manager ─────────────────────────────────────
Remove-ItemProperty "HKCU:\Software\Policies\Microsoft\MMC" -Name "RestrictToPermittedSnapins" -Force -ErrorAction SilentlyContinue
Remove-Item "HKCU:\Software\Policies\Microsoft\MMC\{74246bfc-4c96-11d0-abef-0020af6b0b7a}" -Recurse -Force -ErrorAction SilentlyContinue
W "Device Manager restored"

# ── 6. Refresh ────────────────────────────────────────────────────
try { & gpupdate.exe /force /quiet 2>$null | Out-Null; W "Group Policy refreshed" Green }
catch {}

$ans = Read-Host "  Restart Explorer? (y/n) [y]"
if ($ans -ne 'n') {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1; Start-Process explorer
    W "Explorer restarted" Green
}

Write-Host ""
Write-Host "  DONE. All network restrictions removed." -ForegroundColor Green
Write-Host ""
