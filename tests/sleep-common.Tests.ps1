# Pester tests for lib/sleep-common.ps1 — pure logic helpers.
# Mirrors tests/test_common.bats one-for-one. Run with:
#   Invoke-Pester -Path tests/sleep-common.Tests.ps1

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'lib\sleep-common.ps1')

    function Format-IsoFromEpoch {
        param([long]$Epoch)
        ([DateTimeOffset]::FromUnixTimeSeconds($Epoch)).ToString(
            'yyyy-MM-ddTHH:mm:sszzz',
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    }
}

Describe 'Test-InLockdownWindow' {
    BeforeEach {
        $script:SleepHome = Join-Path $TestDrive ([Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:SleepHome | Out-Null
    }

    It '21:30 is IN window' {
        Test-InLockdownWindow '2130' | Should -Be 0
    }

    It '23:59 is IN window' {
        Test-InLockdownWindow '2359' | Should -Be 0
    }

    It '00:00 is IN window (across midnight)' {
        Test-InLockdownWindow '0000' | Should -Be 0
    }

    It '05:59 is IN window' {
        Test-InLockdownWindow '0559' | Should -Be 0
    }

    It '06:00 is OUT (end, exclusive)' {
        Test-InLockdownWindow '0600' | Should -Be 1
    }

    It '20:59 is OUT (just before start, exclusive boundary on the low side)' {
        Test-InLockdownWindow '2059' | Should -Be 1
    }

    It '21:00 is IN (start, inclusive)' {
        Test-InLockdownWindow '2100' | Should -Be 0
    }

    It '12:00 is OUT' {
        Test-InLockdownWindow '1200' | Should -Be 1
    }

    It 'malformed input returns 2 (distinct from "not in window")' {
        Test-InLockdownWindow '99'   | Should -Be 2
        Test-InLockdownWindow 'abcd' | Should -Be 2
        Test-InLockdownWindow ''     | Should -Be 2
    }
}

Describe 'Test-OverrideActive' {
    BeforeEach {
        $script:SleepHome = Join-Path $TestDrive ([Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:SleepHome | Out-Null
    }

    It 'returns $false when file is missing' {
        Test-OverrideActive -Now 1700000000 -SleepHome $script:SleepHome | Should -BeFalse
    }

    It 'returns $true when override-until > now' {
        Set-Content -LiteralPath (Join-Path $script:SleepHome 'override-until') -Value '1700000060' -NoNewline
        Test-OverrideActive -Now 1700000000 -SleepHome $script:SleepHome | Should -BeTrue
    }

    It 'returns $false when override-until == now (strict >)' {
        Set-Content -LiteralPath (Join-Path $script:SleepHome 'override-until') -Value '1700000000' -NoNewline
        Test-OverrideActive -Now 1700000000 -SleepHome $script:SleepHome | Should -BeFalse
    }

    It 'returns $false when file is empty' {
        Set-Content -LiteralPath (Join-Path $script:SleepHome 'override-until') -Value '' -NoNewline
        Test-OverrideActive -Now 1700000000 -SleepHome $script:SleepHome | Should -BeFalse
    }

    It 'returns $false when file contains non-numeric garbage' {
        Set-Content -LiteralPath (Join-Path $script:SleepHome 'override-until') -Value 'not-a-number' -NoNewline
        Test-OverrideActive -Now 1700000000 -SleepHome $script:SleepHome | Should -BeFalse
    }
}

Describe 'Get-CooldownRemaining' {
    BeforeEach {
        $script:SleepHome = Join-Path $TestDrive ([Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:SleepHome | Out-Null
    }

    It 'returns 0 when log is missing' {
        Get-CooldownRemaining -Now 1700000000 -SleepHome $script:SleepHome | Should -Be 0
    }

    It 'returns seconds remaining when last override < 12h ago' {
        $iso = Format-IsoFromEpoch 1699999000
        Set-Content -LiteralPath (Join-Path $script:SleepHome 'overrides.log') -Value "$iso`ta`tb`tc"
        Get-CooldownRemaining -Now 1700000000 -SleepHome $script:SleepHome | Should -Be 42200
    }

    It 'returns 0 when last override > 12h ago' {
        $iso = Format-IsoFromEpoch 1699956000
        Set-Content -LiteralPath (Join-Path $script:SleepHome 'overrides.log') -Value "$iso`ta`tb`tc"
        Get-CooldownRemaining -Now 1700000000 -SleepHome $script:SleepHome | Should -Be 0
    }

    It 'returns 0 at exact 12h boundary' {
        $iso = Format-IsoFromEpoch 1699956800  # 12h before 1700000000
        Set-Content -LiteralPath (Join-Path $script:SleepHome 'overrides.log') -Value "$iso`ta`tb`tc"
        Get-CooldownRemaining -Now 1700000000 -SleepHome $script:SleepHome | Should -Be 0
    }

    It 'reads the LAST log entry, not the first' {
        $oldIso = Format-IsoFromEpoch 1699000000
        $newIso = Format-IsoFromEpoch 1699999000
        $logPath = Join-Path $script:SleepHome 'overrides.log'
        Set-Content -LiteralPath $logPath -Value "$oldIso`told`told`told"
        Add-Content -LiteralPath $logPath -Value "$newIso`tnew`tnew`tnew"
        Get-CooldownRemaining -Now 1700000000 -SleepHome $script:SleepHome | Should -Be 42200
    }

    It 'corrupted timestamp fails closed (returns full cooldown)' {
        Set-Content -LiteralPath (Join-Path $script:SleepHome 'overrides.log') -Value "garbage-not-a-timestamp`ta`tb`tc"
        Get-CooldownRemaining -Now 1700000000 -SleepHome $script:SleepHome | Should -Be (12 * 3600)
    }
}

Describe 'Format-Hm' {
    It '0 seconds -> 00:00' {
        Format-Hm 0 | Should -Be '00:00'
    }
    It '1 hour -> 01:00' {
        Format-Hm 3600 | Should -Be '01:00'
    }
    It '12h - 1s -> 11:59 (truncates seconds)' {
        Format-Hm ((12 * 3600) - 1) | Should -Be '11:59'
    }
    It '90 minutes 30 seconds -> 01:30 (truncates)' {
        Format-Hm 5430 | Should -Be '01:30'
    }
}

Describe 'Format-HhmmAsClock' {
    It '2130 -> 21:30' {
        Format-HhmmAsClock 2130 | Should -Be '21:30'
    }
    It '600 (no leading zero) -> 06:00' {
        Format-HhmmAsClock 600 | Should -Be '06:00'
    }
    It '0 -> 00:00' {
        Format-HhmmAsClock 0 | Should -Be '00:00'
    }
}
