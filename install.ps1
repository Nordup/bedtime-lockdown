#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$RepoRoot    = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallRoot = Join-Path $env:LOCALAPPDATA 'bedtime-lockdown'
$BinDir      = Join-Path $InstallRoot 'bin'
$LibDir      = Join-Path $InstallRoot 'lib'
$StateDir    = Join-Path $InstallRoot 'state'
$AppId       = 'BedtimeLockdown.Notifier'
$TaskFolder  = '\BedtimeLockdown'
$PsExe       = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

# --- Directories
foreach ($dir in @($BinDir, $LibDir, $StateDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# --- Copy scripts and library
Copy-Item -LiteralPath (Join-Path $RepoRoot 'bin\sleep-warn.ps1')     -Destination (Join-Path $BinDir 'sleep-warn.ps1')     -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot 'bin\sleep-enforce.ps1')  -Destination (Join-Path $BinDir 'sleep-enforce.ps1')  -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot 'bin\sleep-override.ps1') -Destination (Join-Path $BinDir 'sleep-override.ps1') -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot 'bin\sleep-status.ps1')   -Destination (Join-Path $BinDir 'sleep-status.ps1')   -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot 'lib\sleep-common.ps1')   -Destination (Join-Path $LibDir 'sleep-common.ps1')   -Force

# --- .cmd shims so users can type `sleep-status` / `sleep-override` from any terminal
foreach ($name in @('sleep-status', 'sleep-override')) {
    $cmdPath = Join-Path $BinDir "$name.cmd"
    $cmdContent = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0$name.ps1`" %*`r`n"
    [System.IO.File]::WriteAllText($cmdPath, $cmdContent, [System.Text.Encoding]::ASCII)
}

# --- Add bin dir to user PATH (idempotent)
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$pathParts = @()
if ($userPath) { $pathParts = $userPath -split ';' | Where-Object { $_ -ne '' } }
if (-not ($pathParts -contains $BinDir)) {
    $newPath = ($pathParts + $BinDir) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
}

# --- AUMID registration for toast notifications.
# Without this, Windows.UI.Notifications.ToastNotificationManager.CreateToastNotifier
# rejects our AppId. The DisplayName shows in Action Center next to the toast.
$aumidKey = "HKCU:\Software\Classes\AppUserModelId\$AppId"
if (-not (Test-Path -LiteralPath $aumidKey)) {
    New-Item -Path $aumidKey -Force | Out-Null
}
New-ItemProperty -Path $aumidKey -Name 'DisplayName' -Value 'Bedtime Lockdown' -PropertyType String -Force | Out-Null

# --- Helpers for the four scheduled tasks
function New-CommonSettings {
    New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Hours 12)
}
function New-CommonPrincipal {
    # Interactive logon, no elevation — matches the Linux user-scope model.
    New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
}
function New-EnforceAction {
    New-ScheduledTaskAction -Execute $PsExe -Argument (
        "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$BinDir\sleep-enforce.ps1`""
    )
}
function New-WarnAction {
    param([string]$Message)
    New-ScheduledTaskAction -Execute $PsExe -Argument (
        "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$BinDir\sleep-warn.ps1`" `"$Message`""
    )
}

# --- warn-15 (daily at 20:45)
Register-ScheduledTask -TaskName 'warn-15' -TaskPath $TaskFolder -Force `
    -Action    (New-WarnAction 'Bedtime in 15 minutes. Save your work.') `
    -Trigger   (New-ScheduledTaskTrigger -Daily -At '20:45') `
    -Settings  (New-CommonSettings) `
    -Principal (New-CommonPrincipal) `
    -Description 'Bedtime warning (15 min)' | Out-Null

# --- warn-5 (daily at 20:55)
Register-ScheduledTask -TaskName 'warn-5' -TaskPath $TaskFolder -Force `
    -Action    (New-WarnAction 'Bedtime in 5 minutes. Wrap up.') `
    -Trigger   (New-ScheduledTaskTrigger -Daily -At '20:55') `
    -Settings  (New-CommonSettings) `
    -Principal (New-CommonPrincipal) `
    -Description 'Bedtime warning (5 min)' | Out-Null

# --- enforce-bedtime (daily at 21:00 — calendar trigger, matches sleep-enforce-bedtime.timer)
Register-ScheduledTask -TaskName 'enforce-bedtime' -TaskPath $TaskFolder -Force `
    -Action    (New-EnforceAction) `
    -Trigger   (New-ScheduledTaskTrigger -Daily -At '21:00') `
    -Settings  (New-CommonSettings) `
    -Principal (New-CommonPrincipal) `
    -Description 'Bedtime enforce (calendar kickoff at 21:00 sharp)' | Out-Null

# --- enforce-wakeloop (resume event + 5 min delay — matches sleep-enforce.timer's OnUnitInactiveSec=5min)
# The Linux monotonic timer schedules each next fire for "5 min after the
# service ended"; because `systemctl suspend` blocks until resume, that's
# effectively "5 min after the kernel wakes." We replicate this by triggering
# on Power-Troubleshooter EventID 1 (Returned from low power state) with a
# 5 minute delay. Same self-pacing semantics: every wake yields one suspend
# attempt 5 minutes later. enforce.ps1 is window-gated, so wakes outside
# 21:00-06:00 result in a silent no-op.
$eventSubscription = "<QueryList><Query Id='0' Path='System'><Select Path='System'>*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]</Select></Query></QueryList>"
$triggerCimClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
$wakeloopTrigger = New-CimInstance -CimClass $triggerCimClass -Property @{
    Enabled      = $true
    Subscription = $eventSubscription
    Delay        = 'PT5M'
} -ClientOnly
Register-ScheduledTask -TaskName 'enforce-wakeloop' -TaskPath $TaskFolder -Force `
    -Action    (New-EnforceAction) `
    -Trigger   $wakeloopTrigger `
    -Settings  (New-CommonSettings) `
    -Principal (New-CommonPrincipal) `
    -Description 'Bedtime enforce (wake-loop: 5 min after each resume from sleep)' | Out-Null

Write-Host ''
Write-Host 'Installed.'
Write-Host "  Bin:    $BinDir"
Write-Host "  Lib:    $LibDir"
Write-Host "  State:  $StateDir"
Write-Host ''
Write-Host "Scheduled tasks under $TaskFolder\ :"
Get-ScheduledTask -TaskPath "$TaskFolder\" | Format-Table TaskName, State -AutoSize | Out-String | Write-Host
Write-Host "Open a new terminal and run 'sleep-status' to inspect state."
