[CmdletBinding()]
param([string]$Message = 'Bedtime warning')

$ErrorActionPreference = 'Stop'

# AUMID registered by install.ps1 via HKCU\Software\Classes\AppUserModelId\<id>.
# Without this registration, ToastNotificationManager.CreateToastNotifier
# would fail. The fallback path below covers that case.
$AppId = 'BedtimeLockdown.Notifier'

function Show-NativeToast {
    param([string]$AppId, [string]$Message)
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
    [void][Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType=WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType=WindowsRuntime]

    $escaped = [System.Security.SecurityElement]::Escape($Message)
    $xmlString = @"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>Bedtime Lockdown</text>
      <text>$escaped</text>
    </binding>
  </visual>
</toast>
"@
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml($xmlString)
    $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId).Show($toast)
}

function Show-BalloonFallback {
    param([string]$Message)
    # On Windows 10/11, NotifyIcon balloon tips are routed through Action Center
    # as toast notifications. Works without any AUMID registration. Kept as
    # a fallback in case the native toast path fails (e.g. AUMID not registered
    # because the user is running the script before install.ps1).
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $notify = New-Object System.Windows.Forms.NotifyIcon
    try {
        $notify.Icon             = [System.Drawing.SystemIcons]::Warning
        $notify.BalloonTipIcon   = 'Warning'
        $notify.BalloonTipTitle  = 'Bedtime Lockdown'
        $notify.BalloonTipText   = $Message
        $notify.Visible          = $true
        $notify.ShowBalloonTip(20000)
        # Give Windows a moment to route the balloon to Action Center
        # before disposing — otherwise the toast can disappear immediately.
        Start-Sleep -Seconds 2
    } finally {
        $notify.Dispose()
    }
}

try {
    Show-NativeToast -AppId $AppId -Message $Message
} catch {
    Show-BalloonFallback -Message $Message
}
