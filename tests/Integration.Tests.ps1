# Integration smoke tests for the Windows port.
#
# Runs install.ps1 against the real user environment, asserts the installed
# state, runs uninstall.ps1, asserts the cleanup. Skips itself if Bedtime
# Lockdown is already installed on this machine (to avoid clobbering a real
# install while testing).
#
# Run with:
#   Invoke-Pester -Path tests/Integration.Tests.ps1

BeforeAll {
    $script:RepoRoot    = Split-Path -Parent $PSScriptRoot
    $script:InstallRoot = Join-Path $env:LOCALAPPDATA 'bedtime-lockdown'
    $script:BinDir      = Join-Path $script:InstallRoot 'bin'
    $script:LibDir      = Join-Path $script:InstallRoot 'lib'
    $script:StateDir    = Join-Path $script:InstallRoot 'state'
    $script:AppId       = 'BedtimeLockdown.Notifier'
    $script:AumidKey    = "HKCU:\Software\Classes\AppUserModelId\$($script:AppId)"
    $script:TaskFolder  = '\BedtimeLockdown'

    function Test-PreExistingInstall {
        if (Test-Path -LiteralPath $script:InstallRoot)  { return $true }
        if (Test-Path -LiteralPath $script:AumidKey)     { return $true }
        try {
            $existing = @(Get-ScheduledTask -TaskPath "$($script:TaskFolder)\" -ErrorAction SilentlyContinue)
            if ($existing.Count -gt 0) { return $true }
        } catch { }
        return $false
    }

    function Invoke-Install {
        & (Join-Path $script:RepoRoot 'install.ps1')
    }
    function Invoke-Uninstall {
        param([switch]$Purge)
        if ($Purge) {
            & (Join-Path $script:RepoRoot 'uninstall.ps1') -Purge
        } else {
            & (Join-Path $script:RepoRoot 'uninstall.ps1')
        }
    }

    $script:SkipAll = Test-PreExistingInstall
    if ($script:SkipAll) {
        Write-Host "SKIPPING integration tests: existing Bedtime Lockdown install detected." -ForegroundColor Yellow
        Write-Host "  Run uninstall.ps1 -Purge first if you want to run integration tests." -ForegroundColor Yellow
    }
}

Describe 'install.ps1' -Skip:($SkipAll) {
    BeforeAll {
        Invoke-Install | Out-Null
    }
    AfterAll {
        # Defensive cleanup in case any later test left state behind.
        try { Invoke-Uninstall -Purge | Out-Null } catch { }
    }

    Context 'Files and directories' {
        It 'creates the install root' {
            $script:InstallRoot | Should -Exist
        }
        It 'creates the state directory' {
            $script:StateDir | Should -Exist
        }
        It 'copies all four bin scripts' {
            foreach ($name in @('sleep-warn.ps1','sleep-enforce.ps1','sleep-override.ps1','sleep-status.ps1')) {
                Join-Path $script:BinDir $name | Should -Exist
            }
        }
        It 'copies the shared library' {
            Join-Path $script:LibDir 'sleep-common.ps1' | Should -Exist
        }
        It 'creates .cmd shims for user-callable commands' {
            Join-Path $script:BinDir 'sleep-status.cmd'   | Should -Exist
            Join-Path $script:BinDir 'sleep-override.cmd' | Should -Exist
        }
    }

    Context 'AUMID registration' {
        It 'registers the AUMID key' {
            $script:AumidKey | Should -Exist
        }
        It 'sets DisplayName on the AUMID key' {
            (Get-ItemProperty -LiteralPath $script:AumidKey).DisplayName | Should -Be 'Bedtime Lockdown'
        }
    }

    Context 'User PATH' {
        It 'adds the bin directory to user PATH' {
            $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
            ($userPath -split ';') | Should -Contain $script:BinDir
        }
    }

    Context 'Scheduled tasks' {
        It 'registers all four tasks under the BedtimeLockdown folder' {
            $tasks = @(Get-ScheduledTask -TaskPath "$($script:TaskFolder)\" -ErrorAction SilentlyContinue)
            $names = $tasks | ForEach-Object { $_.TaskName }
            $names | Should -Contain 'warn-15'
            $names | Should -Contain 'warn-5'
            $names | Should -Contain 'enforce-bedtime'
            $names | Should -Contain 'enforce-wakeloop'
        }

        It 'gives warn-15 a daily trigger at 20:45' {
            $task = Get-ScheduledTask -TaskPath "$($script:TaskFolder)\" -TaskName 'warn-15'
            $trigger = $task.Triggers[0]
            ([DateTime]$trigger.StartBoundary).ToString('HH:mm') | Should -Be '20:45'
            $trigger.CimClass.CimClassName | Should -Be 'MSFT_TaskDailyTrigger'
        }

        It 'gives warn-5 a daily trigger at 20:55' {
            $task = Get-ScheduledTask -TaskPath "$($script:TaskFolder)\" -TaskName 'warn-5'
            $trigger = $task.Triggers[0]
            ([DateTime]$trigger.StartBoundary).ToString('HH:mm') | Should -Be '20:55'
        }

        It 'gives enforce-bedtime a daily trigger at 21:00' {
            $task = Get-ScheduledTask -TaskPath "$($script:TaskFolder)\" -TaskName 'enforce-bedtime'
            $trigger = $task.Triggers[0]
            ([DateTime]$trigger.StartBoundary).ToString('HH:mm') | Should -Be '21:00'
        }

        It 'gives enforce-wakeloop an event trigger with 5-minute delay on power-resume' {
            $task = Get-ScheduledTask -TaskPath "$($script:TaskFolder)\" -TaskName 'enforce-wakeloop'
            $trigger = $task.Triggers[0]
            $trigger.CimClass.CimClassName | Should -Be 'MSFT_TaskEventTrigger'
            $trigger.Delay                  | Should -Be 'PT5M'
            $trigger.Subscription           | Should -Match 'Power-Troubleshooter'
            $trigger.Subscription           | Should -Match 'EventID=1'
        }

        It 'runs all tasks as the current user with Limited run level' {
            foreach ($name in @('warn-15','warn-5','enforce-bedtime','enforce-wakeloop')) {
                $task = Get-ScheduledTask -TaskPath "$($script:TaskFolder)\" -TaskName $name
                $task.Principal.UserId    | Should -Be $env:USERNAME
                $task.Principal.RunLevel  | Should -Be 'Limited'
                $task.Principal.LogonType | Should -Be 'Interactive'
            }
        }
    }

    Context 'sleep-status against installed paths' {
        It 'runs end-to-end via PowerShell directly' {
            $output = & (Join-Path $script:BinDir 'sleep-status.ps1')
            ($output -join "`n") | Should -Match 'Lockdown:'
            ($output -join "`n") | Should -Match 'Override:'
            ($output -join "`n") | Should -Match 'Cooldown:'
        }

        It 'runs via the .cmd shim' {
            $cmdShim = Join-Path $script:BinDir 'sleep-status.cmd'
            $output = & $env:ComSpec '/c' $cmdShim 2>&1
            ($output -join "`n") | Should -Match 'Lockdown:'
        }

        It 'reflects manually-written override state' {
            # Write a fresh override-until with epoch=now+600 so it's "active".
            $now      = [DateTimeOffset]::Now.ToUnixTimeSeconds()
            $expires  = $now + 600
            $untilPath = Join-Path $script:StateDir 'override-until'
            Set-Content -LiteralPath $untilPath -Value $expires -NoNewline

            $output = (& (Join-Path $script:BinDir 'sleep-status.ps1')) -join "`n"
            $output | Should -Match 'Override:\s+active until'

            Remove-Item -LiteralPath $untilPath -Force
        }
    }
}

Describe 'uninstall.ps1' -Skip:($SkipAll) {
    Context 'Without -Purge: removes everything except state' {
        BeforeAll {
            # Ensure a fresh install before running the uninstall test.
            try { Invoke-Uninstall -Purge | Out-Null } catch { }
            Invoke-Install | Out-Null
            # Touch a file in state so we can assert it's preserved.
            $script:StateMarker = Join-Path $script:StateDir 'integration-test-marker.txt'
            Set-Content -LiteralPath $script:StateMarker -Value 'preserve me' -NoNewline

            Invoke-Uninstall | Out-Null
        }
        AfterAll {
            # Ensure full cleanup regardless of test outcome.
            try { Invoke-Uninstall -Purge | Out-Null } catch { }
        }

        It 'removes the bin directory' {
            (Test-Path -LiteralPath $script:BinDir) | Should -BeFalse
        }
        It 'removes the lib directory' {
            (Test-Path -LiteralPath $script:LibDir) | Should -BeFalse
        }
        It 'preserves the state directory' {
            (Test-Path -LiteralPath $script:StateDir) | Should -BeTrue
        }
        It 'preserves files inside the state directory' {
            (Test-Path -LiteralPath $script:StateMarker) | Should -BeTrue
        }
        It 'unregisters all scheduled tasks' {
            $tasks = @(Get-ScheduledTask -TaskPath "$($script:TaskFolder)\" -ErrorAction SilentlyContinue)
            $tasks.Count | Should -Be 0
        }
        It 'removes the AUMID registration' {
            (Test-Path -LiteralPath $script:AumidKey) | Should -BeFalse
        }
        It 'drops the bin directory from user PATH' {
            $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
            ($userPath -split ';') | Should -Not -Contain $script:BinDir
        }
    }

    Context 'With -Purge: also removes the state directory' {
        BeforeAll {
            try { Invoke-Uninstall -Purge | Out-Null } catch { }
            Invoke-Install | Out-Null
            Set-Content -LiteralPath (Join-Path $script:StateDir 'marker.txt') -Value 'x' -NoNewline
            Invoke-Uninstall -Purge | Out-Null
        }
        AfterAll {
            try { Invoke-Uninstall -Purge | Out-Null } catch { }
        }

        It 'removes the state directory' {
            (Test-Path -LiteralPath $script:StateDir) | Should -BeFalse
        }
        It 'removes the entire install root' {
            (Test-Path -LiteralPath $script:InstallRoot) | Should -BeFalse
        }
    }
}
