# Bedtime Lockdown

Desktop service for Linux and Windows that hard-suspends your machine at bedtime and keeps it suspended through the night, with a deliberately high-friction override path for genuine emergencies.

Built because reminders don't work when you're the kind of person who tells yourself "just five more minutes" at 1am every night.

## What it does

At 8:45pm and 8:55pm, you get notifications. At 9:00pm, the screen locks and the machine suspends. Wake it any time before 6am and it suspends again 5 minutes later. Wake again, suspend again. This continues until 6:00am.

If you have a real emergency, run `sleep-override` from any terminal. It asks three deliberately uncomfortable questions, logs your answers, and grants exactly one hour of unlock. Once per 12 hours, max.

| Time         | Event                                                |
|--------------|------------------------------------------------------|
| 8:45pm       | Notification: "Bedtime in 15 minutes."               |
| 8:55pm       | Notification: "Bedtime in 5 minutes."                |
| 9:00pm       | Lock screen + suspend.                               |
| 9pm – 6am    | If machine wakes, suspend again 5 minutes later.     |
| 6:00am       | Window ends.                                         |

## Why

Most "focus" tools block websites or apps. None of them turn the computer off. Cold Turkey's *Frozen Turkey* mode is the closest match conceptually, and it's the inspiration for this project — a free, scriptable equivalent that runs on Linux (bash + systemd) and Windows (PowerShell + Task Scheduler).

The override is the design's interesting part. Pure bedtime locks tend to fail in two failure modes: (a) too easy to override → user uses it every night and it changes nothing, (b) too hard to override → user disables the whole system on the first stressful night. The three-question form is calibrated to be slow enough that addiction-brain takes the path of least resistance and goes to bed, while still giving you a way out if there's an actual fire.

## Requirements

**Linux:**

- A systemd-based Linux desktop.
- `notify-send` (libnotify) for the warning notifications.
- A graphical session that responds to `loginctl lock-session`.
- Polkit configured to let the user run `systemctl suspend` without a password (default on most distros, including Manjaro).

Tested on Manjaro + GNOME on Wayland. Should work on any modern systemd Linux with a desktop environment.

**Windows:**

- Windows 10 or 11.
- Windows PowerShell 5.1 (ships by default on every supported Windows).
- Sleep enabled in your power plan. If you've replaced sleep with "modern standby" or have hibernation set as the primary low-power state, the wake-loop still works but the suspend itself behaves slightly differently.

Tested on Windows 11. The install script registers per-user scheduled tasks under `\BedtimeLockdown\` and does not require admin elevation for typical setups.

## Install — Linux

```bash
git clone https://github.com/Nordup/bedtime-lockdown
cd bedtime-lockdown
./install.sh
```

This copies four scripts to `~/.local/bin/`, the shared library to `~/.local/share/sleep/`, seven systemd user units to `~/.config/systemd/user/`, and enables the timers. Runtime state (logs, override flag) lives in `~/.config/sleep/`.

After install, three new commands are on your PATH:

- `sleep-status` — show current state, last 5 enforce events, last 5 overrides.
- `sleep-override` — interactive 3-question CLI to grant a 1-hour unlock.
- `sleep-warn` and `sleep-enforce` exist but you don't run them manually; systemd does.

## Install — Windows

```powershell
git clone https://github.com/Nordup/bedtime-lockdown
cd bedtime-lockdown
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

This copies four PowerShell scripts and the shared library to `%LOCALAPPDATA%\bedtime-lockdown\`, registers four Task Scheduler tasks under `\BedtimeLockdown\`, registers an AUMID so toast notifications display correctly, and adds the bin directory to your user PATH. Runtime state (logs, override flag) lives in `%LOCALAPPDATA%\bedtime-lockdown\state\`.

After install, open a new terminal and the same two commands are available:

- `sleep-status` — same diagnostic as the Linux version.
- `sleep-override` — same 3-question CLI.
- `sleep-warn.ps1` and `sleep-enforce.ps1` exist but Task Scheduler runs them, not you.

## Customize the schedule

**Linux** — edit `~/.local/share/sleep/sleep-common.sh`:

```bash
LOCKDOWN_START_HHMM=2100              # bedtime, 24h, no colon
LOCKDOWN_END_HHMM=600                 # window end (0600 = 6am)
OVERRIDE_DURATION_SEC=3600            # 1h unlock per override
COOLDOWN_SEC=$((12 * 3600))           # one override per 12h
```

If you change `LOCKDOWN_START_HHMM`, also update the three calendar-aligned timer files so they stay in lockstep:

- `~/.config/systemd/user/sleep-warn-15.timer` — `OnCalendar=` 15 min before bedtime
- `~/.config/systemd/user/sleep-warn-5.timer` — `OnCalendar=` 5 min before bedtime
- `~/.config/systemd/user/sleep-enforce-bedtime.timer` — `OnCalendar=` at bedtime sharp

Then reload: `systemctl --user daemon-reload && systemctl --user restart sleep-enforce.timer sleep-enforce-bedtime.timer`.

**Windows** — edit `%LOCALAPPDATA%\bedtime-lockdown\lib\sleep-common.ps1`:

```powershell
$Script:LockdownStartHHMM    = 2100            # bedtime: lock + suspend at 21:00
$Script:LockdownEndHHMM      = 600             # window end (06:00)
$Script:OverrideDurationSec  = 3600            # 1h reprieve per override
$Script:CooldownSec          = 12 * 3600       # one override per 12h
```

If you change `LockdownStartHHMM`, also update the three matching scheduled task triggers (in the Task Scheduler UI under `\BedtimeLockdown\`, or by re-running `install.ps1` after editing the times in it):

- `warn-15` — daily trigger 15 min before bedtime
- `warn-5` — daily trigger 5 min before bedtime
- `enforce-bedtime` — daily trigger at bedtime sharp

The `enforce-wakeloop` task triggers on system resume and doesn't refer to the bedtime; you don't need to touch it.

## Uninstall — Linux

```bash
./uninstall.sh
```

Disables the timers, removes the binaries and unit files. Your state directory `~/.config/sleep/` is preserved so the override log survives uninstall — useful for self-review. Delete it manually with `rm -rf ~/.config/sleep` if you don't want to keep it.

## Uninstall — Windows

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Unregisters the scheduled tasks, removes the AUMID, drops the bin directory from your user PATH, and removes the bin/lib directories. Your state directory `%LOCALAPPDATA%\bedtime-lockdown\state\` is preserved. Pass `-Purge` to remove it too.

## How it works

Same design on both platforms: four scripts, a shared logic library, four scheduler entries that drive the warnings and the wake-loop. No daemon, no language runtime, no third-party deps.

**Linux layout** — bash + seven systemd user units:

```
~/.local/bin/
  sleep-warn        3-line wrapper around `notify-send`
  sleep-enforce     the suspender, run by a systemd timer
  sleep-override    the friction CLI
  sleep-status      read-only diagnostic

~/.local/share/sleep/
  sleep-common.sh   pure logic helpers (window check, override check, cooldown calc)

~/.config/systemd/user/
  sleep-warn-15.{service,timer}    "Bedtime in 15 min" at 20:45
  sleep-warn-5.{service,timer}     "Bedtime in 5 min" at 20:55
  sleep-enforce.service            the suspender (shared by both enforce timers)
  sleep-enforce.timer              monotonic wake-loop: 5 min after each resume
  sleep-enforce-bedtime.timer      calendar kickoff: first suspend at 21:00 sharp
```

**Windows layout** — PowerShell + four Task Scheduler tasks:

```
%LOCALAPPDATA%\bedtime-lockdown\
  bin\
    sleep-warn.ps1       toast via Windows.UI.Notifications (with AUMID)
    sleep-enforce.ps1    the suspender, LockWorkStation + SetSuspendState
    sleep-override.ps1   the friction CLI (named mutex for single-writer)
    sleep-status.ps1     read-only diagnostic
    sleep-status.cmd     .cmd shim so `sleep-status` works from any terminal
    sleep-override.cmd   ditto
  lib\
    sleep-common.ps1     pure logic helpers (same semantics as the bash lib)
  state\                 logs and override-until

Task Scheduler \BedtimeLockdown\
  warn-15           daily 20:45
  warn-5            daily 20:55
  enforce-bedtime   daily 21:00 (calendar kickoff)
  enforce-wakeloop  event trigger on Power-Troubleshooter EventID 1 (system resumed), 5 min delay
```

`sleep-enforce` is the heart. Each invocation:

1. If outside the lockdown window, exit silently (this is what happens 144 of 144 daytime fires).
2. If an override is currently active, exit silently.
3. Otherwise: log the attempt, lock the session, suspend the machine.

Two scheduler entries drive the service on each platform. The calendar entry fires once at 21:00 sharp so the first suspend of the night lands at the bedtime hour, not up to 5 minutes late. The wake-loop entry self-paces from each resume, not from absolute clock marks.

On **Linux**, the wake-loop uses systemd's `OnUnitInactiveSec=5min` on a monotonic timer. Because `systemctl suspend` blocks until the kernel resumes, "service ended" coincides with "user just woke the machine," so the 5-minute clock self-paces from each wake. The service is `Type=oneshot`, so if both timers fire close together systemd silently skips the second activation while the first invocation is still suspended.

On **Windows**, the wake-loop uses a Task Scheduler event trigger on Event ID 1 from `Microsoft-Windows-Power-Troubleshooter` (logged on every return from a low-power state), with a 5-minute delay. Same property as the Linux side: every wake yields one suspend attempt 5 minutes later. `SetSuspendState(Suspend, force=false, disableWakeEvent=false)` blocks until resume, and Task Scheduler's `MultipleInstances=IgnoreNew` plays the role of `Type=oneshot` — if a second trigger fires while the first invocation is still suspended, it's dropped on the floor.

`sleep-override` is intentionally slow. It asks three questions: what are you doing, why tonight specifically and not tomorrow morning, what time will you actually stop. Empty answers are rejected. The answers go into `overrides.log` so you can read them back later when you wonder why you keep losing sleep. Then it writes `now+1h` into `override-until`. Enforce reads that file on every fire and skips suspending while the override is live. Single-writer guard is `flock` on Linux, a named `System.Threading.Mutex` on Windows — same role: prevent two concurrent invocations from both passing the cooldown check and double-appending to the log.

## Anti-cheat philosophy

This is not tamper-proof. You are root on your own machine. If you really want to disable it at 8:55pm, `systemctl --user stop sleep-enforce.timer` works. The system relies on the override being faster and lower-shame than disabling — addiction-brain takes the path of least resistance, and the override path is paved while the disable path requires a deliberate moral act. Calibrate the override friction up if you find yourself bypassing too easily; calibrate it down if you find yourself disabling.

## Caveats

**Linux:**

- **Wifi resume on MediaTek chipsets:** some `mt7921e` cards throw `error -110` on resume. The driver re-initializes itself successfully most of the time. If yours doesn't, `sudo modprobe -r mt7921e && sudo modprobe mt7921e` reloads it.
- **Screen locking depends on your DE** correctly handling `loginctl lock-session`. Tested on GNOME Wayland. Should work on KDE, XFCE, etc., but verify on your setup.
- **Service stays "active" during suspend** in systemd's view, because `systemctl suspend` blocks until resume. This is intentional — it's what lets the wake-loop self-pace from each resume rather than from absolute clock marks.

**Windows:**

- **Toast notifications use an AUMID** registered under `HKCU\Software\Classes\AppUserModelId\BedtimeLockdown.Notifier`. If you've disabled toast notifications globally, or your "Focus assist" / "Do not disturb" is set to suppress non-priority apps, you won't see the warnings. The 21:00 lock+suspend still fires.
- **Resume event source:** the wake-loop uses `Microsoft-Windows-Power-Troubleshooter` Event ID 1, which logs on every return from any low-power state. If you've disabled the Power-Troubleshooter event channel, the wake-loop won't fire — verify with `Get-WinEvent -LogName System -ProviderName Microsoft-Windows-Power-Troubleshooter -MaxEvents 1`.
- **Task Scheduler "Limited" run level:** tasks run as the current user without elevation. If the user account doesn't have rights to lock the workstation (very unusual), the lock step is best-effort and the suspend still proceeds.

## Tests

**Linux** — 27 unit tests in `bats`:

```bash
sudo pacman -S bats   # or your distro's equivalent
bats tests/
```

Covers the pure logic helpers. Edge cases: malformed input, empty file, garbage content, exact 12-hour boundary, multi-line log (last entry wins), corrupted timestamp fails closed.

**Windows** — 27 unit tests + 26 integration tests in Pester 5:

```powershell
# One-time setup (current user, no admin needed)
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser

# Unit tests against the pure logic library (fast, no side effects)
Invoke-Pester -Path tests/sleep-common.Tests.ps1

# Integration tests: actually install, verify, uninstall.
# Refuses to run if Bedtime Lockdown is already installed on this machine.
Invoke-Pester -Path tests/Integration.Tests.ps1
```

The integration tests exercise the full install/uninstall cycle: file layout, AUMID registration, user PATH, all four scheduled tasks with their triggers, and the `.cmd` shims. They leave the system clean.

## Related projects

If this isn't quite what you want, here's the landscape — all checked at the time of writing.

**Direct conceptual match, paid:** Cold Turkey's *Frozen Turkey* mode (Windows/Mac) schedules a computer-level lockout with bypass-prevention. This project is a free, scriptable clone of that idea for both Linux and Windows. If you'd rather pay for a polished GUI and don't need anything custom, Cold Turkey is a reasonable buy.

**Same mechanism (schedule a system action), no addiction-aware design:**

- [jhasse/sleeptimer](https://github.com/jhasse/sleeptimer) — generic shutdown timer for Linux/Windows.
- [Shingyx/schedule-shutdown](https://github.com/Shingyx/schedule-shutdown) — cross-platform scheduled shutdowns.
- [lukaslangrock/ShutdownTimerClassic](https://github.com/lukaslangrock/ShutdownTimerClassic) — Windows-only.
- Autopoweroff, qshutdown — Linux scheduled-shutdown utilities.

These are general-purpose tools — no friction override, no wake-loop, no concept of bedtime as a self-discipline product. If you want "shutdown at X" with no behavioral mechanic, one of these is simpler than this project.

**Same motivation (anti-procrastination), different mechanism (blocks apps/sites instead of suspending):**

- [Chomper](https://github.com/parkerlreed/chomper) — Linux internet blocker, built specifically because Cold Turkey doesn't run on Linux. Blocks domains via iptables.
- [zengargoyle/selfcontrol](https://github.com/zengargoyle/selfcontrol) — port of Mac SelfControl. Old (GTK2), "most likely broken" per its own readme.
- LeechBlock, Pluckeye, DigitalZen — content blockers, mostly browser-based or commercial.

If you want website/app blocking rather than full machine suspend, one of these will fit better.

**Opposite direction, will confuse a search:**

- [bulletmark/sleep-inhibitor](https://github.com/bulletmark/sleep-inhibitor), [mrmekon/circadian](https://github.com/mrmekon/circadian) — these *prevent* suspend or suspend-on-idle. Useful tools, opposite trigger condition.

The specific combination of *scheduled hard suspend + friction override + wake-loop*, free and scriptable on both Linux and Windows, doesn't seem to exist anywhere else, which is why this repo exists.

## Origin

Built in a single late-night session because I couldn't stop working past 9pm and reminders weren't cutting it. Design and plan docs are preserved in `docs/specs/` and `docs/plans/` for anyone curious about how it came together — they're frozen at the original 21:30 schedule, so trust this README and the code for current behavior.

## License

MIT. See [LICENSE](LICENSE).
