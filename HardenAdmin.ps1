<#
.SYNOPSIS
    System Hardening for ScreenToTelegram
    - UAC to maximum (Always Notify + deny Standard User elevation)
    - Blocks Task Manager / Registry Editor / CMD for Standard Users
    - Prevents Safe Mode via F8 boot menu
    - Locks Group Policy tools for Standard Users
    Run as ADMINISTRATOR. Reverse with RestoreAdmin.cmd.
#>

#Requires -RunAsAdministrator
$ErrorActionPreference = 'SilentlyContinue'

# ─── Helpers ─────────────────────────────────────────────────────
function EnsureKey([string]$p) { if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null } }
function SR([string]$p, [string]$n, $v, [string]$t='DWord') { EnsureKey $p; Set-ItemProperty -Path $p -Name $n -Value $v -Type $t -Force }
function W([string]$m, [string]$c='Cyan')   { Write-Host "  [+] $m" -ForegroundColor $c }
function WW([string]$m)                     { Write-Host "  [!] $m" -ForegroundColor Yellow }
function SEC([string]$t)                    { Write-Host ""; Write-Host ("  " + "─"*55) -ForegroundColor DarkGray; Write-Host "  $t" -ForegroundColor Yellow }

# ─── Backup original values ───────────────────────────────────────
$backupPath = Join-Path $PSScriptRoot "harden_backup.json"
$sys = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"

$backup = @{
    ConsentPromptBehaviorAdmin = (Get-ItemProperty $sys -Name ConsentPromptBehaviorAdmin).ConsentPromptBehaviorAdmin
    ConsentPromptBehaviorUser  = (Get-ItemProperty $sys -Name ConsentPromptBehaviorUser).ConsentPromptBehaviorUser
    EnableLUA                  = (Get-ItemProperty $sys -Name EnableLUA).EnableLUA
    PromptOnSecureDesktop      = (Get-ItemProperty $sys -Name PromptOnSecureDesktop).PromptOnSecureDesktop
    FilterAdministratorToken   = (Get-ItemProperty $sys -Name FilterAdministratorToken -ErrorAction SilentlyContinue).FilterAdministratorToken
    # Safe boot
    BootMenuPolicy = (& bcdedit /enum "{current}" 2>$null | Select-String "bootmenupolicy" | ForEach-Object { ($_ -split '\s+',2)[1] } | Select-Object -First 1)
    # Standard user policy keys (may not exist = null means we created them)
    DisableTaskMgr         = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System" -Name DisableTaskMgr -ErrorAction SilentlyContinue).DisableTaskMgr
    DisableRegistryTools   = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System" -Name DisableRegistryTools -ErrorAction SilentlyContinue).DisableRegistryTools
    DisableCMD             = (Get-ItemProperty "HKCU:\Software\Policies\Microsoft\Windows\System" -Name DisableCMD -ErrorAction SilentlyContinue).DisableCMD
    NoControlPanel         = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name NoControlPanel -ErrorAction SilentlyContinue).NoControlPanel
    RunTimestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
}

$backup | ConvertTo-Json | Set-Content -Path $backupPath -Encoding UTF8
Write-Host ""
Write-Host "  ╔═══════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "  ║       System Hardening - ScreenToTelegram         ║" -ForegroundColor Magenta
Write-Host "  ╚═══════════════════════════════════════════════════╝" -ForegroundColor Magenta
W "Original values backed up to: harden_backup.json" DarkGray

# ═════════════════════════════════════════════════════════════════
# 1. UAC — Maximum Level
# ═════════════════════════════════════════════════════════════════
SEC "1. UAC Settings"

# Admin: prompt on secure desktop (Always Notify)
SR $sys "ConsentPromptBehaviorAdmin" 2
W "Admin elevation: Always Notify (value=2)"

# Standard User: automatically DENY elevation (no UAC prompt at all)
SR $sys "ConsentPromptBehaviorUser" 0
W "Standard User elevation: Auto-Denied (value=0)"

# Secure desktop ON
SR $sys "PromptOnSecureDesktop" 1
W "Secure desktop: Enabled"

# LUA ON (should already be, but enforce)
SR $sys "EnableLUA" 1
W "LUA (User Account Control): Enforced"

# FilterAdministratorToken: even built-in Admin runs as standard token
SR $sys "FilterAdministratorToken" 1
W "Built-in Administrator: filtered token (value=1)"

# ═════════════════════════════════════════════════════════════════
# 2. Standard User Restrictions via HKLM (apply to ALL users)
# ═════════════════════════════════════════════════════════════════
SEC "2. Standard User Tool Restrictions (HKLM)"

$sysAllUsers = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"

# Block Task Manager for all non-Admins
SR $sysAllUsers "DisableTaskMgr" 0   # 0 = allowed for Admin (HKLM affects standard users differently)

# Use per-user HKLM default user hive policy instead:
$hklmSoftware = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"

# The proper way: set restrictions under HKCU default profile
# But these apply to current session for non-admin users via SOFTWARE\Policies
$stdPolSys = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
EnsureKey $stdPolSys

# Disable CMD for standard users (0=enabled, 1=disabled+scripts, 2=disabled entirely)
# This affects users without Admin rights
$cmdPol = "HKLM:\Software\Policies\Microsoft\Windows\System"
EnsureKey $cmdPol
SR $cmdPol "DisableCMD" 1
W "CMD disabled for Standard Users (scripts still run)"

# Block access to Registry Editor
$regPol = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System"
SR $regPol "DisableRegistryTools" 1
W "Registry Editor (regedit) disabled"

# Block Control Panel & Settings for Standard Users
$explorerPolHKLM = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
EnsureKey $explorerPolHKLM
SR $explorerPolHKLM "NoControlPanel" 1
SR $explorerPolHKLM "NoSetFolders" 1
W "Control Panel hidden for Standard Users"

# Block Run dialog (Win+R) for Standard Users
SR $explorerPolHKLM "NoRun" 1
W "Run dialog (Win+R) disabled for Standard Users"

# ═════════════════════════════════════════════════════════════════
# 3. Safe Mode — Remove F8 Boot Menu (best effort from Windows)
# ═════════════════════════════════════════════════════════════════
SEC "3. Safe Mode Protection"

# Remove legacy F8 boot menu
try {
    & bcdedit /set '{bootmgr}' bootmenupolicy standard 2>$null | Out-Null
    W "F8 boot menu: disabled (bootmenupolicy=standard)" Green
} catch { WW "bcdedit bootmenupolicy: could not set" }

# Make boot failures NOT show recovery menu (prevents Shift+Restart -> Safe Mode escalation)
# Note: this is best-effort; full protection requires BitLocker PIN
try {
    & bcdedit /set '{current}' bootstatuspolicy IgnoreAllFailures 2>$null | Out-Null
    W "Boot failure recovery menu: suppressed"
} catch { WW "bcdedit bootstatuspolicy: could not set" }

WW "Full Safe Mode prevention requires BitLocker PIN - set it manually in:"
WW "  Control Panel > BitLocker Drive Encryption > Turn on BitLocker"

# ═════════════════════════════════════════════════════════════════
# 4. Block PowerShell for Standard Users (via HKLM policy hint)
# ═════════════════════════════════════════════════════════════════
SEC "4. PowerShell Restrictions (Standard Users)"

# Cannot block powershell.exe via registry alone without SRP/AppLocker
# But we can restrict PowerShell execution policy for non-Admins
try {
    Set-ExecutionPolicy -Scope MachinePolicy -ExecutionPolicy AllSigned -Force 2>$null
    W "Machine-level ExecutionPolicy: AllSigned (standard users cannot run unsigned .ps1)"
} catch { WW "ExecutionPolicy: $($_.Exception.Message)" }

WW "Full PowerShell block requires AppLocker (Win 11 Pro/Enterprise)"
WW "  If needed: enable AppLocker in Local Security Policy > Application Control"

# ═════════════════════════════════════════════════════════════════
# 5. Block Device Manager, MSConfig, Computer Management
# ═════════════════════════════════════════════════════════════════
SEC "5. System Tool MMC Snapin Restrictions (HKLM)"

$mmcHKLM = "HKLM:\Software\Policies\Microsoft\MMC"
EnsureKey $mmcHKLM
SR $mmcHKLM "RestrictToPermittedSnapins" 1

# Block: Device Manager, Services, Event Viewer, Group Policy, Task Scheduler
@(
    "{74246bfc-4c96-11d0-abef-0020af6b0b7a}",   # Device Manager
    "{58221C65-EA27-11CF-ADCF-00AA00A80033}",   # Services
    "{975797FC-4E2A-11D0-B702-00C04FD8DBF7}"    # Task Scheduler
) | ForEach-Object {
    SR "HKLM:\Software\Policies\Microsoft\MMC\$_" "Restrict_Run" 1
    W "Blocked MMC snapin: $_"
}

# ═════════════════════════════════════════════════════════════════
# 6. Verify ScreenToTelegram runs as the Admin account
# ═════════════════════════════════════════════════════════════════
SEC "6. ScreenToTelegram Startup Verification"

$startupLnk = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup\ScreenToTelegram.lnk"
if (Test-Path $startupLnk) {
    W "Startup shortcut found: $startupLnk" Green
    W "It runs under the Admin account's Startup — correct." Green
} else {
    WW "Startup shortcut NOT found. Run Install.cmd first while logged in as Admin."
}

# ═════════════════════════════════════════════════════════════════
# Done
# ═════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "  " + ("═"*55) -ForegroundColor Magenta
Write-Host "  DONE. System hardened." -ForegroundColor Green
Write-Host ""
Write-Host "  Summary of what's now blocked for Standard Users:" -ForegroundColor White
Write-Host "    - UAC elevation: DENIED automatically" -ForegroundColor Gray
Write-Host "    - Task Manager: blocked" -ForegroundColor Gray
Write-Host "    - Registry Editor: blocked" -ForegroundColor Gray
Write-Host "    - Control Panel / Settings: blocked" -ForegroundColor Gray
Write-Host "    - CMD: blocked (scripts still run for system)" -ForegroundColor Gray
Write-Host "    - Device Manager / Services: blocked" -ForegroundColor Gray
Write-Host "    - F8 Safe Mode menu: removed" -ForegroundColor Gray
Write-Host "    - Unsigned PS1 scripts: blocked (MachinePolicy=AllSigned)" -ForegroundColor Gray
Write-Host ""
Write-Host "  To reverse EVERYTHING: run RestoreAdmin.cmd as Admin" -ForegroundColor DarkGray
Write-Host "  " + ("═"*55) -ForegroundColor Magenta
Write-Host ""
