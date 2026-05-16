# Bedtime Lockdown

Desktop service for Linux and Windows that hard-suspends your machine at bedtime and keeps it suspended through the night, with a deliberately high-friction override path for genuine emergencies. The Linux build adds two gentler daytime windows that re-lock the screen for lunch and exercise+dinner, with per-window override isolation. (Windows is bedtime-only for now — see TODO at end.)

Built because reminders don't work when you're the kind of person who tells yourself "just five more minutes" at 1am every night — and the same brain skips meals and skips exercise the same way.

## What it does

Three daily enforcement windows. Bedtime hard-suspends the machine; lunch and exercise+dinner just re-lock the screen every five minutes (you're awake and at the machine — the lock is enough).

| Time            | Event                                                       |
|-----------------|-------------------------------------------------------------|
| 11:15am         | Notification: "Lunch in 15 minutes."                        |
| 11:25am         | Notification: "Lunch in 5 minutes."                         |
| 11:30am – 12:15pm | Screen re-locks every 5 min. No suspend.                  |
| 4:15pm          | Notification: "Exercise + dinner in 15 minutes."            |
| 4:25pm          | Notification: "Exercise + dinner in 5 minutes."             |
| 4:30pm – 6:30pm | Screen re-locks every 5 min. No suspend.                    |
| 8:45pm          | Notification: "Bedtime in 15 minutes."                      |
| 8:55pm          | Notification: "Bedtime in 5 minutes."                       |
| 9:00pm          | Lock screen + suspend.                                      |
| 9pm – 6am       | If machine wakes, suspend again 5 minutes later.            |
| 6:00am          | Window ends.                                                |

If you have a real emergency inside any window, run `sleep-override` from any terminal. It detects which window is active, asks three deliberately uncomfortable questions, logs your answers, and grants unlock. Bedtime grants one hour; lunch and dinner grant until the end of the current break. One override per window per 12 hours — each window's quota is independent.

## Why

Most "focus" tools block websites or apps. None of them turn the computer off — or even force you to step away from it during meals. Cold Turkey's *Frozen Turkey* mode is the closest match conceptually for the bedtime piece, and it's the inspiration for this project — a free, scriptable equivalent that runs on Linux (bash + systemd) and Windows (PowerShell + Task Scheduler). The Linux build extends the same mechanism to two daytime "step away from the screen" windows.

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

This copies four scripts to `~/.local/bin/`, the shared library to `~/.local/share/sleep/`, seventeen systemd user units to `~/.config/systemd/user/`, and enables ten timers. Runtime state (logs, override flags) lives in `~/.config/sleep/`.

After install, three new commands are on your PATH:

- `sleep-status` — show all three windows, last 5 enforce events, last 5 overrides.
- `sleep-override` — interactive 3-question CLI. Detects the active window automatically.
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
LUNCH_START_HHMM=1130                 # lunch break start
LUNCH_END_HHMM=1215                   # lunch break end (re-lock stops)
DINNER_START_HHMM=1630                # exercise+dinner start
DINNER_END_HHMM=1830                  # exercise+dinner end (re-lock stops)
OVERRIDE_DURATION_SEC=3600            # bedtime override length: 1h
COOLDOWN_SEC=$((12 * 3600))           # one override per 12h, per window
```

The `*_END_HHMM` values are only used by the in-script window check. The `*_START_HHMM` values are duplicated in calendar timer files (systemd timers can't read shell variables) and must be kept in lockstep. If you change a start, update the matching three units:

- bedtime → `sleep-warn-15.timer`, `sleep-warn-5.timer`, `sleep-enforce-bedtime.timer`
- lunch → `sleep-warn-lunch-15.timer`, `sleep-warn-lunch-5.timer`, `sleep-enforce-lunch.timer`
- dinner → `sleep-warn-dinner-15.timer`, `sleep-warn-dinner-5.timer`, `sleep-enforce-dinner.timer`

Then reload: `systemctl --user daemon-reload && systemctl --user restart sleep-enforce.timer sleep-enforce-bedtime.timer sleep-enforce-lunch.timer sleep-enforce-dinner.timer`.

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

Same overall design on both platforms: four scripts, a shared logic library, scheduler entries that drive the warnings and the wake-loop. No daemon, no language runtime, no third-party deps. The Linux build expands this into three windows with seven services and ten timers; the Windows build is bedtime-only with four scheduled tasks.

**Linux layout** — bash + seventeen systemd user units (seven services, ten timers):

```
~/.local/bin/
  sleep-warn        3-line wrapper around `notify-send` (takes title + body)
  sleep-enforce     the locker/suspender, run by systemd timers
  sleep-override    the friction CLI (window-aware)
  sleep-status      read-only diagnostic

~/.local/share/sleep/
  sleep-common.sh   pure logic helpers (window detection, override check, cooldown calc)

~/.config/systemd/user/
  sleep-warn-15.{service,timer}              "Bedtime in 15 min" at 20:45
  sleep-warn-5.{service,timer}               "Bedtime in 5 min" at 20:55
  sleep-warn-lunch-15.{service,timer}        "Lunch in 15 min" at 11:15
  sleep-warn-lunch-5.{service,timer}         "Lunch in 5 min" at 11:25
  sleep-warn-dinner-15.{service,timer}       "Exercise+dinner in 15 min" at 16:15
  sleep-warn-dinner-5.{service,timer}        "Exercise+dinner in 5 min" at 16:25
  sleep-enforce.service                      the locker/suspender (shared by all kickoff timers)
  sleep-enforce.timer                        monotonic wake-loop: 5 min after each service end
  sleep-enforce-bedtime.timer                calendar kickoff: first suspend at 21:00 sharp
  sleep-enforce-lunch.timer                  calendar kickoff: first lock at 11:30 sharp
  sleep-enforce-dinner.timer                 calendar kickoff: first lock at 16:30 sharp
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

On **Linux**:

1. Detect the current window (`bedtime` / `lunch` / `dinner` / `none`). If `none`, exit silently — most fires hit this branch.
2. If an override is active for the current window, exit silently.
3. Otherwise: log the attempt with the window name, lock the session. For bedtime only, also call `systemctl suspend`.

Three calendar timers (one per window) phase-align the first enforce to the window start. The single monotonic timer (`sleep-enforce.timer`) drives the wake-loop: `OnUnitInactiveSec=5min` schedules each subsequent fire for 5 minutes after the previous service ended. Inside lunch/dinner the service ends immediately (lock returns at once), so re-lock cadence is ~5 min from clock. Inside bedtime, `systemctl suspend` blocks until resume, so the 5-minute clock self-paces from each wake. The service is `Type=oneshot`, so if calendar + monotonic both fire close together systemd silently skips the second activation.

On **Windows** (bedtime-only):

1. If outside the lockdown window, exit silently.
2. If an override is currently active, exit silently.
3. Otherwise: log the attempt, lock the session, suspend the machine.

The wake-loop uses a Task Scheduler event trigger on Event ID 1 from `Microsoft-Windows-Power-Troubleshooter` (logged on every return from a low-power state), with a 5-minute delay. Same property as the Linux side: every wake yields one suspend attempt 5 minutes later. `SetSuspendState(Suspend, force=false, disableWakeEvent=false)` blocks until resume, and Task Scheduler's `MultipleInstances=IgnoreNew` plays the role of `Type=oneshot` — if a second trigger fires while the first invocation is still suspended, it's dropped on the floor.

`sleep-override` is intentionally slow. On Linux it's window-aware: it detects which window is active, asks three questions tailored to that window — what are you doing, why is *this* break the wrong time to step away (or, for bedtime, why tonight and not tomorrow morning), what time will you actually stop. Empty answers are rejected. Answers go into a per-window log (`overrides.log`, `overrides-lunch.log`, `overrides-dinner.log`). Bedtime grants `now+1h` and writes `override-until`; breaks grant until end of the current window and write `override-until-lunch` or `override-until-dinner`. Enforce reads only the file matching the current window, so skipping lunch never affects bedtime. On Windows, the override is bedtime-only: three questions, grants `now+1h`, writes `override-until`. Single-writer guard is `flock` on Linux, a named `System.Threading.Mutex` on Windows — same role: prevent two concurrent invocations from both passing the cooldown check and double-appending to the log.

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

62 unit tests covering the pure logic helpers: window detection across all three windows, per-window override and cooldown isolation, window_end_epoch resolution including the bedtime midnight roll, and the original bedtime edge cases (malformed input, empty file, garbage content, exact 12-hour boundary, multi-line log last-entry-wins, corrupted timestamp fails closed via stderr).

**Windows** — 27 unit tests + 26 integration tests in Pester 5 (bedtime-only — see TODO):

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

## TODO

- **Windows three-window port.** The Linux build has lunch and exercise+dinner windows with per-window override isolation; the Windows build is still bedtime-only. Bringing parity requires porting the window detection and per-window override files from `lib/sleep-common.sh` to `lib/sleep-common.ps1`, adding lunch/dinner triggers to `install.ps1`, making `sleep-enforce.ps1` and `sleep-override.ps1` window-aware, and expanding the Pester unit tests to match the bats suite.

## Origin

Built in a single late-night session because I couldn't stop working past 9pm and reminders weren't cutting it. Design and plan docs are preserved in `docs/specs/` and `docs/plans/` for anyone curious about how it came together — they're frozen at the original 21:30 schedule, so trust this README and the code for current behavior.

## License

MIT. See [LICENSE](LICENSE).
