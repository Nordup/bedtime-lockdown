# Pure logic helpers for the bedtime-lockdown PowerShell port.
# Dot-sourced by bin/sleep-*.ps1 and by tests.
#
# CONFIG NOTE: $LockdownStartHHMM is the bedtime — when the script
# locks and suspends. Three scheduled-task triggers hard-code this value
# and must be kept in lockstep with it by hand (Task Scheduler triggers
# can't read script variables):
#
#   bedtime-warn-15        -> trigger at LockdownStart - 15 min
#   bedtime-warn-5         -> trigger at LockdownStart -  5 min
#   bedtime-enforce-bedtime-> trigger at LockdownStart (sharp)
#
# $LockdownEndHHMM only affects this script's window check; no scheduled
# task refers to it.

$Script:LockdownStartHHMM    = 2100            # bedtime: lock + suspend at 21:00
$Script:LockdownEndHHMM      = 600             # wake-up: window ends at 06:00
$Script:OverrideDurationSec  = 3600            # 1 hour reprieve per override
$Script:CooldownSec          = 12 * 3600       # one override per 12 hours

# Test-InLockdownWindow <HHMM>
#   Returns 0 if the given 4-digit time is in [LockdownStart, LockdownEnd).
#   The window crosses midnight, e.g. 21:00 .. 06:00 next morning.
#   Returns 1 if out of window.
#   Returns 2 on malformed input (caller-visible distinction from "not in window").
function Test-InLockdownWindow {
    param([string]$Hhmm)
    if ($Hhmm -notmatch '^\d{4}$') { return 2 }
    # [int] parses with leading zeros as decimal in PowerShell — no octal trap.
    $n = [int]$Hhmm
    if ($n -ge $Script:LockdownStartHHMM -or $n -lt $Script:LockdownEndHHMM) { return 0 }
    return 1
}

# Test-OverrideActive -Now <epoch_seconds> -SleepHome <path>
#   Returns $true iff $SleepHome\override-until exists, contains a numeric
#   epoch, and that epoch is strictly greater than now. Returns $false in
#   any other case (missing, empty, non-numeric, expired). Always fails closed.
function Test-OverrideActive {
    param(
        [Parameter(Mandatory=$true)][long]$Now,
        [Parameter(Mandatory=$true)][string]$SleepHome
    )
    $f = Join-Path $SleepHome 'override-until'
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return $false }
    $raw = Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue
    if ($null -eq $raw) { return $false }
    $trimmed = $raw.Trim()
    if ($trimmed -notmatch '^\d+$') { return $false }
    return ([long]$trimmed -gt $Now)
}

# Get-CooldownRemaining -Now <epoch_seconds> -SleepHome <path>
#   Returns the seconds remaining in the override cooldown.
#   Returns 0 if the cooldown is over (or no overrides exist yet).
#   Returns $CooldownSec and warns to stderr if the most recent log
#   entry has a malformed timestamp — fail closed, never grant a free
#   override because of a corrupted file.
function Get-CooldownRemaining {
    param(
        [Parameter(Mandatory=$true)][long]$Now,
        [Parameter(Mandatory=$true)][string]$SleepHome
    )
    $f = Join-Path $SleepHome 'overrides.log'
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return [long]0 }
    if ((Get-Item -LiteralPath $f).Length -eq 0) { return [long]0 }

    # Read non-empty lines; take the last one's first tab-delimited field.
    $lines = @(Get-Content -LiteralPath $f -ErrorAction SilentlyContinue | Where-Object { $_ -ne '' })
    if ($lines.Count -eq 0) { return [long]0 }
    $lastIso = ($lines[-1] -split "`t")[0]

    try {
        $parsed = [DateTimeOffset]::Parse(
            $lastIso,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        )
    } catch {
        [Console]::Error.WriteLine('warning: corrupted timestamp in overrides.log; failing closed')
        return [long]$Script:CooldownSec
    }
    $lastEpoch = $parsed.ToUnixTimeSeconds()
    $elapsed = $Now - $lastEpoch
    $remaining = $Script:CooldownSec - $elapsed
    if ($remaining -le 0) { return [long]0 }
    return [long]$remaining
}

# Format-Hm <seconds>
#   Returns HH:MM with the seconds component truncated. Used for
#   user-facing cooldown messages.
function Format-Hm {
    param([Parameter(Mandatory=$true)][long]$Seconds)
    $h = [int][Math]::Floor($Seconds / 3600)
    $m = [int][Math]::Floor(($Seconds % 3600) / 60)
    return ('{0:D2}:{1:D2}' -f $h, $m)
}

# Format-HhmmAsClock <HHMM>
#   Renders e.g. 2130 -> "21:30", 600 -> "06:00". Used for user-facing
#   window labels in sleep-status.
function Format-HhmmAsClock {
    param([Parameter(Mandatory=$true)]$Hhmm)
    $padded = '{0:D4}' -f [int]$Hhmm
    return ('{0}:{1}' -f $padded.Substring(0,2), $padded.Substring(2,2))
}
