<#
Publishes screen_to_telegram.ps1 as an auto-update to every installed copy.

    publish.ps1 -Message "what changed"

1. Bumps $ScriptVersion in screen_to_telegram.ps1 (yyyyMMddHHmm), so installed copies see a newer version.
2. Checks the script parses and holds no Telegram bot token (the updates repo is public).
3. Stamps this version into Uninstall.cmd and emits uninstallers\ScreenToTelegram-Uninstall-<version>.cmd.
4. Signs the exact bytes with the private key in %USERPROFILE%\.screen-to-telegram\update_signing_key.xml.
5. Commits update.json (script + signature) to the public updates repo and pushes.

Installed copies pick it up at their next check and restart on the new version.
The private key never goes into any repo - without it no update can be published, so back it up.
#>
param(
    [Parameter(Mandatory = $true)][string]$Message
)

$ErrorActionPreference = 'Stop'

$KeyFile = Join-Path $env:USERPROFILE '.screen-to-telegram\update_signing_key.xml'
if (-not (Test-Path $KeyFile)) { $KeyFile = Join-Path $PSScriptRoot 'keys\update_signing_key.xml' }
$UpdatesRepo = 'https://github.com/Abdullah-Habashy/screen-to-telegram-updates.git'
$UpdatesDir  = Join-Path $env:USERPROFILE '.screen-to-telegram\updates-repo'
$Script      = Join-Path $PSScriptRoot 'screen_to_telegram.ps1'

function Stop-Publish([string]$Why) {
    Write-Host "ERROR: $Why" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $KeyFile)) {
    Stop-Publish "signing key not found in $env:USERPROFILE\.screen-to-telegram\ nor in $KeyFile. Restore it - a new key would not be accepted by installed copies."
}

# 1) version bump
$text = [IO.File]::ReadAllText($Script)
if ($text -notmatch '(?m)^\$ScriptVersion = \d+') { Stop-Publish "no `$ScriptVersion line in $Script." }
$version = (Get-Date).ToString('yyyyMMddHHmm')
$text = [regex]::Replace($text, '(?m)^\$ScriptVersion = \d+', "`$ScriptVersion = $version")
[IO.File]::WriteAllText($Script, $text, (New-Object System.Text.UTF8Encoding $false))

# 2) safety checks
$errors = $null
[void][Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$errors)
if ($errors.Count -gt 0) {
    Stop-Publish "$Script has $($errors.Count) syntax error(s), first: $($errors[0].Message) (line $($errors[0].Extent.StartLineNumber)). Nothing was published."
}
if ($text -match '\d{8,10}:[A-Za-z0-9_-]{35}') {
    Stop-Publish "$Script contains something that looks like a Telegram bot token - the updates repo is public. Nothing was published."
}

# 3) version-stamped uninstaller
$UninstallerTemplate = Join-Path $PSScriptRoot 'Uninstall.cmd'
if (Test-Path $UninstallerTemplate) {
    $ut = [IO.File]::ReadAllText($UninstallerTemplate)
    if ($ut -notmatch '\$UninstallerVersion = \[long\]\d+') { Stop-Publish "no `$UninstallerVersion line in $UninstallerTemplate." }
    $ut = [regex]::Replace($ut, '\$UninstallerVersion = \[long\]\d+', "`$UninstallerVersion = [long]$version")
    [IO.File]::WriteAllText($UninstallerTemplate, $ut, (New-Object System.Text.UTF8Encoding $false))
    $distDir = Join-Path $PSScriptRoot 'uninstallers'
    New-Item -ItemType Directory -Force -Path $distDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $distDir "ScreenToTelegram-Uninstall-$version.cmd"), $ut, (New-Object System.Text.UTF8Encoding $false))
} else {
    Write-Host "WARNING: $UninstallerTemplate not found - no uninstaller was generated." -ForegroundColor Yellow
}

# 4) sign the exact bytes that will be served
$bytes = [IO.File]::ReadAllBytes($Script)
$rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
$rsa.FromXmlString([IO.File]::ReadAllText($KeyFile))
$sig = [Convert]::ToBase64String($rsa.SignData($bytes, 'SHA256'))

# 5) push to the public repo. Script and signature go in one update.json (base64), so a cache
#    can't serve a new script with an old signature.
if (-not (Test-Path $UpdatesDir)) {
    git clone $UpdatesRepo $UpdatesDir
    if ($LASTEXITCODE -ne 0) { Stop-Publish "could not clone $UpdatesRepo. Create the public repo first, then retry." }
}
Push-Location $UpdatesDir
try {
    git pull --quiet
    $package = [ordered]@{
        version   = [long]$version
        script    = [Convert]::ToBase64String($bytes)
        signature = $sig
    }
    # No BOM - the installed copy reads this with ConvertFrom-Json over the raw text.
    [IO.File]::WriteAllText((Join-Path $UpdatesDir 'update.json'), ($package | ConvertTo-Json), (New-Object System.Text.UTF8Encoding $false))
    git add update.json
    git commit -m "Update to ${version}: $Message" --quiet
    git push --quiet
    if ($LASTEXITCODE -ne 0) { Stop-Publish "git push failed; the update was not published." }
} finally {
    Pop-Location
}

Write-Host "Published version $version." -ForegroundColor Green
Write-Host "Installed copies will update at their next check (every update.check_every_minutes)."
