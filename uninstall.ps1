#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Purge
)

$ErrorActionPreference = 'Continue'

$InstallRoot = Join-Path $env:LOCALAPPDATA 'bedtime-lockdown'
$BinDir      = Join-Path $InstallRoot 'bin'
$LibDir      = Join-Path $InstallRoot 'lib'
$StateDir    = Join-Path $InstallRoot 'state'
$AppId       = 'BedtimeLockdown.Notifier'
$TaskFolder  = '\BedtimeLockdown'

# --- Unregister scheduled tasks
foreach ($name in @('warn-15', 'warn-5', 'enforce-bedtime', 'enforce-wakeloop')) {
    try {
        Unregister-ScheduledTask -TaskName $name -TaskPath "$TaskFolder\" -Confirm:$false -ErrorAction Stop
    } catch { }
}

# --- Delete the empty task folder (best effort)
try {
    $sched = New-Object -ComObject Schedule.Service
    $sched.Connect()
    $root = $sched.GetFolder('\')
    try { $root.DeleteFolder('BedtimeLockdown', 0) } catch { }
} catch { }

# --- Remove AUMID registration
$aumidKey = "HKCU:\Software\Classes\AppUserModelId\$AppId"
if (Test-Path -LiteralPath $aumidKey) {
    Remove-Item -LiteralPath $aumidKey -Force -Recurse
}

# --- Remove bin and lib (preserve state)
foreach ($dir in @($BinDir, $LibDir)) {
    if (Test-Path -LiteralPath $dir) {
        Remove-Item -LiteralPath $dir -Recurse -Force
    }
}

# --- Drop bin from user PATH
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath) {
    $parts = @($userPath -split ';' | Where-Object { $_ -ne $BinDir -and $_ -ne '' })
    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
}

if ($Purge) {
    if (Test-Path -LiteralPath $InstallRoot) {
        Remove-Item -LiteralPath $InstallRoot -Recurse -Force
    }
    Write-Host "Uninstalled. State directory was also removed (-Purge)."
} else {
    Write-Host "Uninstalled. State directory $StateDir was left intact (logs preserved)."
    Write-Host "Run uninstall.ps1 -Purge to remove it too."
}
