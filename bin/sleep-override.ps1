[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$SleepLib  = if ($env:SLEEP_LIB)  { $env:SLEEP_LIB }  else { Join-Path $env:LOCALAPPDATA 'bedtime-lockdown\lib' }
$SleepHome = if ($env:SLEEP_HOME) { $env:SLEEP_HOME } else { Join-Path $env:LOCALAPPDATA 'bedtime-lockdown\state' }
. (Join-Path $SleepLib 'sleep-common.ps1')

if (-not (Test-Path -LiteralPath $SleepHome -PathType Container)) {
    New-Item -ItemType Directory -Path $SleepHome -Force | Out-Null
}

# Single-writer guard via named mutex (cross-process). Equivalent of the
# bash version's flock-on-fd-9 — prevents two concurrent invocations from
# both passing the cooldown check and double-appending to overrides.log.
$mutexName  = 'Local\BedtimeLockdown.OverrideMutex'
$createdNew = $false
$mutex      = New-Object System.Threading.Mutex($false, $mutexName, [ref]$createdNew)
$haveLock   = $false

try {
    $haveLock = $mutex.WaitOne(0)
    if (-not $haveLock) {
        [Console]::Error.WriteLine('Another sleep-override is running. Try again.')
        exit 1
    }

    $now       = [DateTimeOffset]::Now.ToUnixTimeSeconds()
    $remaining = Get-CooldownRemaining -Now $now -SleepHome $SleepHome
    if ($remaining -gt 0) {
        [Console]::Error.WriteLine(
            ("Override already used. Cooldown remaining: {0}" -f (Format-Hm $remaining))
        )
        exit 1
    }

    function Read-Answer {
        param([string]$Question)
        while ($true) {
            $answer = Read-Host -Prompt $Question
            if ($null -ne $answer -and $answer.Trim() -ne '') {
                return $answer
            }
            [Console]::Error.WriteLine('  (answer cannot be empty)')
        }
    }

    $a1 = Read-Answer 'What are you doing right now?'
    $a2 = Read-Answer 'Why tonight specifically, and not tomorrow morning?'
    $a3 = Read-Answer 'What time will you actually stop?'

    $expires = $now + $Script:OverrideDurationSec
    $ts      = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')

    $line = "{0}`t{1}`t{2}`t{3}" -f $ts, $a1, $a2, $a3
    Add-Content -LiteralPath (Join-Path $SleepHome 'overrides.log') -Value $line
    Set-Content -LiteralPath (Join-Path $SleepHome 'override-until') -Value $expires -NoNewline

    $untilLocal = [DateTimeOffset]::FromUnixTimeSeconds($expires).LocalDateTime.ToString('HH:mm')
    Write-Host "Override granted until $untilLocal. Sleep well."
}
finally {
    if ($haveLock) { [void]$mutex.ReleaseMutex() }
    $mutex.Dispose()
}
