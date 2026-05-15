[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$SleepLib  = if ($env:SLEEP_LIB)  { $env:SLEEP_LIB }  else { Join-Path $env:LOCALAPPDATA 'bedtime-lockdown\lib' }
$SleepHome = if ($env:SLEEP_HOME) { $env:SLEEP_HOME } else { Join-Path $env:LOCALAPPDATA 'bedtime-lockdown\state' }
. (Join-Path $SleepLib 'sleep-common.ps1')

if (-not (Test-Path -LiteralPath $SleepHome -PathType Container)) {
    New-Item -ItemType Directory -Path $SleepHome -Force | Out-Null
}

$now  = [DateTimeOffset]::Now.ToUnixTimeSeconds()
$hhmm = (Get-Date).ToString('HHmm')

if ((Test-InLockdownWindow $hhmm) -ne 0) { exit 0 }
if (Test-OverrideActive -Now $now -SleepHome $SleepHome) { exit 0 }

$ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
Add-Content -LiteralPath (Join-Path $SleepHome 'enforce.log') -Value "$ts suspending"

# Best-effort lock. The Linux script calls `loginctl lock-session`. Here we
# call LockWorkStation, which sends the workstation to the Winlogon secure
# desktop (same effect as Win+L). If it fails, continue to suspend anyway.
try {
    if (-not ('BedtimeLockdown.User32Lock' -as [type])) {
        Add-Type -Name 'User32Lock' -Namespace 'BedtimeLockdown' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool LockWorkStation();
'@
    }
    [void][BedtimeLockdown.User32Lock]::LockWorkStation()
} catch { }

# Suspend. SetSuspendState(Suspend, force=false, disableWakeEvent=false)
# blocks the caller until the kernel resumes — the same self-pacing
# property systemd's wake-loop relies on. With the resume-event scheduled
# task trigger (configured in install.ps1), the next enforce fires 5 min
# after the user wakes the machine.
Add-Type -AssemblyName System.Windows.Forms
[void][System.Windows.Forms.Application]::SetSuspendState(
    [System.Windows.Forms.PowerState]::Suspend,
    $false,
    $false
)
