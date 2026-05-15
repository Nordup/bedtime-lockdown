[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$SleepLib  = if ($env:SLEEP_LIB)  { $env:SLEEP_LIB }  else { Join-Path $env:LOCALAPPDATA 'bedtime-lockdown\lib' }
$SleepHome = if ($env:SLEEP_HOME) { $env:SLEEP_HOME } else { Join-Path $env:LOCALAPPDATA 'bedtime-lockdown\state' }
. (Join-Path $SleepLib 'sleep-common.ps1')

$now  = [DateTimeOffset]::Now.ToUnixTimeSeconds()
$hhmm = (Get-Date).ToString('HHmm')
$windowLabel = '{0} - {1}' -f (Format-HhmmAsClock $Script:LockdownStartHHMM), (Format-HhmmAsClock $Script:LockdownEndHHMM)

Write-Output ("Now:           {0}" -f (Get-Date))
if ((Test-InLockdownWindow $hhmm) -eq 0) {
    Write-Output "Lockdown:      ACTIVE (window $windowLabel)"
} else {
    Write-Output "Lockdown:      inactive (window $windowLabel)"
}

$overrideUntilFile = Join-Path $SleepHome 'override-until'
if (Test-OverrideActive -Now $now -SleepHome $SleepHome) {
    $untilEpoch = [long]((Get-Content -LiteralPath $overrideUntilFile -Raw).Trim())
    $until = [DateTimeOffset]::FromUnixTimeSeconds($untilEpoch).LocalDateTime.ToString('HH:mm')
    Write-Output "Override:      active until $until"
} else {
    Write-Output "Override:      none"
}

$remaining = Get-CooldownRemaining -Now $now -SleepHome $SleepHome
if ($remaining -gt 0) {
    Write-Output ("Cooldown:      {0} remaining" -f (Format-Hm $remaining))
} else {
    Write-Output "Cooldown:      ready (no override on cooldown)"
}

$today = (Get-Date).ToString('yyyy-MM-dd')
$overridesLog = Join-Path $SleepHome 'overrides.log'
$count = 0
if ((Test-Path -LiteralPath $overridesLog -PathType Leaf) -and ((Get-Item -LiteralPath $overridesLog).Length -gt 0)) {
    $count = @(Select-String -LiteralPath $overridesLog -Pattern "^$today").Count
}
Write-Output "Overrides today: $count"

Write-Output ''
Write-Output 'Last 5 enforce events:'
$enforceLog = Join-Path $SleepHome 'enforce.log'
if ((Test-Path -LiteralPath $enforceLog -PathType Leaf) -and ((Get-Item -LiteralPath $enforceLog).Length -gt 0)) {
    Get-Content -LiteralPath $enforceLog -Tail 5
} else {
    Write-Output '  (none)'
}

Write-Output ''
Write-Output 'Last 5 overrides:'
if ((Test-Path -LiteralPath $overridesLog -PathType Leaf) -and ((Get-Item -LiteralPath $overridesLog).Length -gt 0)) {
    Get-Content -LiteralPath $overridesLog -Tail 5
} else {
    Write-Output '  (none)'
}
