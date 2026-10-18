<#
.SYNOPSIS
    Reverses ALL changes made by HardenAdmin.ps1
    Reads harden_backup.json and restores every original value.
    Must be run as ADMINISTRATOR.
#>

#Requires -RunAsAdministrator
$ErrorActionPreference = 'SilentlyContinue'

function EnsureKey([string]$p) { if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null } }
function SR([string]$p,[string]$n,$v,[string]$t='DWord') { EnsureKey $p; Set-ItemProperty -Path $p -Name $n -Value $v -Type $t -Force }
function RM_Prop([string]$p,[string]$n) { Remove-ItemProperty -Path $p -Name $n -Force -ErrorAction SilentlyContinue }
function W([string]$m,[string]$c='Green') { Write-Host "  [-] $m" -ForegroundColor $c }
function WW([string]$m) { Write-Host "  [!] $m" -ForegroundColor Yellow }
function SEC([string]$t) { Write-Host ""; Write-Host "  $t" -ForegroundColor Yellow }

$backupPath = Join-Path $PSScriptRoot "harden_backup.json"

Write-Host ""
Write-Host "  ╔═══════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║     RestoreAdmin - ScreenToTelegram               ║" -ForegroundColor Green
Write-Host "  ╚═══════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

# ─── Load backup ─────────────────────────────────────────────────
if (Test-Path $backupPath) {
    $backup = Get-Content $backupPath -Raw | ConvertFrom-Json
    W "Backup loaded from: harden_backup.json (taken $($backup.RunTimestamp))" Cyan
} else {
    WW "harden_backup.json not found! Will use safe defaults."
    $backup = $null
}

$sys = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"

# ═════════════════════════════════════════════════════════════════
# 1. Restore UAC settings
# ═════════════════════════════════════════════════════════════════
SEC "1. Restoring UAC"

$adminVal  = if ($backup -and $null -ne $backup.ConsentPromptBehaviorAdmin)  { [int]$backup.ConsentPromptBehaviorAdmin }  else { 5 }
$userVal   = if ($backup -and $null -ne $backup.ConsentPromptBehaviorUser)   { [int]$backup.ConsentPromptBehaviorUser }   else { 3 }
$luaVal    = if ($backup -and $null -ne $backup.EnableLUA)                   { [int]$backup.EnableLUA }                   else { 1 }
$secDesk   = if ($backup -and $null -ne $backup.PromptOnSecureDesktop)       { [int]$backup.PromptOnSecureDesktop }       else { 1 }

SR $sys "ConsentPromptBehaviorAdmin" $adminVal
W "ConsentPromptBehaviorAdmin = $adminVal"

SR $sys "ConsentPromptBehaviorUser" $userVal
W "ConsentPromptBehaviorUser = $userVal"

SR $sys "EnableLUA" $luaVal
W "EnableLUA = $luaVal"

SR $sys "PromptOnSecureDesktop" $secDesk
W "PromptOnSecureDesktop = $secDesk"

# FilterAdministratorToken: if it was missing, remove it; else restore
if ($backup -and $null -ne $backup.FilterAdministratorToken) {
    SR $sys "FilterAdministratorToken" ([int]$backup.FilterAdministratorToken)
    W "FilterAdministratorToken = $($backup.FilterAdministratorToken)"
} else {
    RM_Prop $sys "FilterAdministratorToken"
    W "FilterAdministratorToken: removed (was not set originally)"
}

# ═════════════════════════════════════════════════════════════════
# 2. Remove Standard User tool restrictions (HKLM)
# ═════════════════════════════════════════════════════════════════
SEC "2. Removing Standard User Restrictions"

# CMD
RM_Prop "HKLM:\Software\Policies\Microsoft\Windows\System" "DisableCMD"
W "CMD: restored (DisableCMD removed)"

# Registry Editor
RM_Prop "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System" "DisableRegistryTools"
W "Registry Editor: restored"

# Control Panel / Explorer policies
foreach ($n in @("NoControlPanel","NoSetFolders","NoRun")) {
    RM_Prop "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" $n
    W "$n removed"
}

# ═════════════════════════════════════════════════════════════════
# 3. Restore Safe Mode boot menu
# ═════════════════════════════════════════════════════════════════
SEC "3. Restoring Safe Mode / Boot Menu"

$originalPolicy = if ($backup -and $backup.BootMenuPolicy) { $backup.BootMenuPolicy.Trim() } else { "standard" }
if ($originalPolicy -and $originalPolicy -ne "standard") {
    try { & bcdedit /set '{bootmgr}' bootmenupolicy $originalPolicy 2>$null | Out-Null; W "bootmenupolicy restored to: $originalPolicy" }
    catch { WW "bcdedit: could not restore" }
} else {
    # Original was standard OR unknown: delete the override (returns to Windows default)
    try { & bcdedit /deletevalue '{bootmgr}' bootmenupolicy 2>$null | Out-Null; W "bootmenupolicy: reset to Windows default" }
    catch { WW "bcdedit deletevalue: could not reset" }
}

try {
    & bcdedit /deletevalue '{current}' bootstatuspolicy 2>$null | Out-Null
    W "bootstatuspolicy: reset to default"
} catch { WW "bootstatuspolicy reset: $($_.Exception.Message)" }

# ═════════════════════════════════════════════════════════════════
# 4. Restore PowerShell ExecutionPolicy
# ═════════════════════════════════════════════════════════════════
SEC "4. Restoring PowerShell ExecutionPolicy"

try {
    Set-ExecutionPolicy -Scope MachinePolicy -ExecutionPolicy Unrestricted -Force 2>$null
    W "MachinePolicy ExecutionPolicy: Unrestricted"
} catch { WW "ExecutionPolicy: $($_.Exception.Message)" }

# ═════════════════════════════════════════════════════════════════
# 5. Remove MMC snapin restrictions (HKLM)
# ═════════════════════════════════════════════════════════════════
SEC "5. Restoring MMC Snapins"

RM_Prop "HKLM:\Software\Policies\Microsoft\MMC" "RestrictToPermittedSnapins"
W "MMC RestrictToPermittedSnapins: removed"

foreach ($guid in @(
    "{74246bfc-4c96-11d0-abef-0020af6b0b7a}",
    "{58221C65-EA27-11CF-ADCF-00AA00A80033}",
    "{975797FC-4E2A-11D0-B702-00C04FD8DBF7}"
)) {
    Remove-Item "HKLM:\Software\Policies\Microsoft\MMC\$guid" -Recurse -Force -ErrorAction SilentlyContinue
    W "Restored MMC snapin: $guid"
}

# ═════════════════════════════════════════════════════════════════
# Refresh GP + Explorer
# ═════════════════════════════════════════════════════════════════
try { & gpupdate.exe /force /quiet 2>$null | Out-Null; W "Group Policy refreshed" }
catch {}

Write-Host ""
$ans = Read-Host "  Restart Explorer to apply changes? (y/n) [y]"
if ($ans -ne 'n') {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1; Start-Process explorer
    W "Explorer restarted"
}

# Archive the backup so accidental re-run doesn't use stale data
if (Test-Path $backupPath) {
    $arch = $backupPath -replace '\.json$', ("_used_" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".json")
    Rename-Item -Path $backupPath -NewName $arch -Force
    W "Backup archived as: $(Split-Path -Leaf $arch)" DarkGray
}

Write-Host ""
Write-Host "  DONE. All hardening reversed. System is back to original state." -ForegroundColor Green
Write-Host ""
