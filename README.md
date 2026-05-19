# Bedtime Lockdown

Desktop service for Linux and Windows that locks your screen at bedtime and keeps re-locking it through the night, with a deliberately high-friction override path for genuine emergencies. The Linux build adds two daytime windows on the same mechanism for lunch and exercise+dinner, plus an agent-mode escape hatch that explicitly blanks the display so background agents can run on a dark machine. (Windows is bedtime-only and still suspends the machine — see TODO at end.)

Built because reminders don't work when you're the kind of person who tells yourself "just five more minutes" at 1am every night — and the same brain skips meals and skips exercise the same way.

## What it does

Three daily enforcement windows, all on the same code path: lock the screen and re-lock every 5 min until the window ends. No automatic suspend — that broke overnight agent runs, and the screen-lock alone (plus the friction of typing your password every five minutes) carries enough weight in practice.

| Time            | Event                                                       |
|-----------------|-------------------------------------------------------------|
| 11:15am         | Notification: "Lunch in 15 minutes."                        |
| 11:25am         | Notification: "Lunch in 5 minutes."                         |
| 11:30am – 12:15pm | Screen re-locks every 5 min.                              |
| 4:15pm          | Notification: "Exercise + dinner in 15 minutes."            |
| 4:25pm          | Notification: "Exercise + dinner in 5 minutes."             |
| 4:30pm – 6:30pm | Screen re-locks every 5 min.                                |
| 8:45pm          | Notification: "Bedtime in 15 minutes."                      |
| 8:55pm          | Notification: "Bedtime in 5 minutes."                       |
| 9:00pm – 6:00am | Screen re-locks every 5 min.                                |

If you have a real emergency inside any window, run `sleep-override` from any terminal. It detects which window is active, asks three deliberately uncomfortable questions, logs your answers, and grants unlock. Bedtime grants one hour; lunch and dinner grant until the end of the current break. One override per window per 12 hours — each window's quota is independent.

If you're stepping away during any window and want the screen physically off (and you want a long-running agent to keep working in the background), run `sleep-agent` (Linux only). It locks the session, blanks the display via Mutter's `DisplayConfig` D-Bus, and spawns a backgrounded `systemd-inhibit` that holds idle-suspend blocked until the current window ends. The re-lock loop also defers while agent-mode is active, so coming back is just one password prompt. Mouse or keyboard wakes the display back to the lock screen. Works the same in all three windows. Logged to `agent.log`.

## Why

Most "focus" tools block websites or apps. None of them lock the screen at scheduled times — or even force you to step away from it during meals. Cold Turkey's *Frozen Turkey* mode is the closest match conceptually for the bedtime piece, and it's the inspiration for this project — a free, scriptable equivalent that runs on Linux (bash + systemd) and Windows (PowerShell + Task Scheduler). The Linux build extends the same mechanism to two daytime "step away from the screen" windows, with an agent-mode escape hatch that explicitly turns the display off so background work isn't blocked.

The override is the design's interesting part. Pure bedtime locks tend to fail in two failure modes: (a) too easy to override → user uses it every night and it changes nothing, (b) too hard to override → user disables the whole system on the first stressful night. The three-question form is calibrated to be slow enough that addiction-brain takes the path of least resistance and goes to bed, while still giving you a way out if there's an actual fire.

## Requirements

**Linux:**

- A systemd-based Linux desktop.
- `notify-send` (libnotify) for the warning notifications.
- A graphical session that responds to `loginctl lock-session`.
- For `sleep-agent`: GNOME (Mutter) for the `DisplayConfig` D-Bus call that blanks the display, and `systemd-inhibit` (ships with systemd).

Tested on Manjaro + GNOME on Wayland. Lock and override should work on any modern systemd Linux with a desktop environment; `sleep-agent`'s display-blank step is GNOME-specific and will warn and continue on other DEs.

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

- `sleep-status` — show all three windows, agent-mode state, last 5 enforce events, last 5 overrides.
- `sleep-override` — interactive 3-question CLI. Detects the active window automatically.
- `sleep-agent` — one-shot: lock, blank the display, inhibit idle-suspend until the current window ends. No questions, no cooldown — designed for routine "stepping away with an agent running" use, multiple times per day.
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
  sleep-enforce     the locker, run by systemd timers
  sleep-override    the friction CLI (window-aware)
  sleep-status      read-only diagnostic
  sleep-agent       agent-mode: lock + blank + idle-suspend inhibitor, until end of current window

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
2. If agent-mode is active, exit silently — `sleep-agent` has the screen blanked and idle-suspend inhibited.
3. If an override is active for the current window, exit silently.
4. Otherwise: log the attempt with the window name, lock the session.

All three windows share this single code path — bedtime used to also call `systemctl suspend`, but suspend killed in-flight background agents, so the project now relies on the lock-loop + agent-mode escape hatch instead. Three calendar timers (one per window) phase-align the first enforce to the window start. The single monotonic timer (`sleep-enforce.timer`) drives the wake-loop: `OnUnitInactiveSec=5min` schedules each subsequent fire for 5 minutes after the previous service ended. The service is `Type=oneshot`, so if calendar + monotonic both fire close together systemd silently skips the second activation.

On **Windows** (bedtime-only):

1. If outside the lockdown window, exit silently.
2. If an override is currently active, exit silently.
3. Otherwise: log the attempt, lock the session, suspend the machine.

The wake-loop uses a Task Scheduler event trigger on Event ID 1 from `Microsoft-Windows-Power-Troubleshooter` (logged on every return from a low-power state), with a 5-minute delay. Same property as the Linux side: every wake yields one suspend attempt 5 minutes later. `SetSuspendState(Suspend, force=false, disableWakeEvent=false)` blocks until resume, and Task Scheduler's `MultipleInstances=IgnoreNew` plays the role of `Type=oneshot` — if a second trigger fires while the first invocation is still suspended, it's dropped on the floor.

`sleep-override` is intentionally slow. On Linux it's window-aware: it detects which window is active, asks three questions tailored to that window — what are you doing, why is *this* break the wrong time to step away (or, for bedtime, why tonight and not tomorrow morning), what time will you actually stop. Empty answers are rejected. Answers go into a per-window log (`overrides.log`, `overrides-lunch.log`, `overrides-dinner.log`). Bedtime grants `now+1h` and writes `override-until`; breaks grant until end of the current window and write `override-until-lunch` or `override-until-dinner`. Enforce reads only the file matching the current window, so skipping lunch never affects bedtime. On Windows, the override is bedtime-only: three questions, grants `now+1h`, writes `override-until`. Single-writer guard is `flock` on Linux, a named `System.Threading.Mutex` on Windows — same role: prevent two concurrent invocations from both passing the cooldown check and double-appending to the log.

`sleep-agent` is the routine-friction counterpart. Inside any active window, one command flips the machine into agent-mode: locks the session, blanks the display via `gdbus call ... org.gnome.Mutter.DisplayConfig.SetPowerSaveMode 3`, and spawns a detached `setsid systemd-inhibit --what=idle:sleep ... sleep $duration` that lives until the window ends and then exits on its own (releasing the inhibitor). It writes `agent-until` (the window-end epoch) so `sleep-enforce` skips its lock loop, and `agent-inhibit.pid` so a re-run can clean up any leftover inhibitor. One line per use lands in `agent.log`. No questions, no cooldown — designed for 3x/day routine ("walking away during lunch, an agent is running"), not for justifying rule-breaks.

## Anti-cheat philosophy

This is not tamper-proof. You are root on your own machine. If you really want to disable it at 8:55pm, `systemctl --user stop sleep-enforce.timer` works. The system relies on the override being faster and lower-shame than disabling — addiction-brain takes the path of least resistance, and the override path is paved while the disable path requires a deliberate moral act. Calibrate the override friction up if you find yourself bypassing too easily; calibrate it down if you find yourself disabling.

## Caveats

**Linux:**

- **Screen locking depends on your DE** correctly handling `loginctl lock-session`. Tested on GNOME Wayland. Should work on KDE, XFCE, etc., but verify on your setup.
- **`sleep-agent`'s display blank is GNOME-specific.** It calls Mutter's `DisplayConfig.SetPowerSaveMode` over D-Bus. On other DEs the script warns and continues — lock + inhibitor still apply, but the screen won't go dark explicitly. Equivalent calls for KDE/XFCE/sway are TODO.
- **`sleep-enforce` no longer suspends.** Earlier versions hard-suspended at bedtime; that broke overnight agent runs. The lock loop carries the weight now, with `sleep-agent` as the explicit "step away" command. The Windows port still suspends because its three-window port is unfinished — see TODO.

**Windows:**

- **Toast notifications use an AUMID** registered under `HKCU\Software\Classes\AppUserModelId\BedtimeLockdown.Notifier`. If you've disabled toast notifications globally, or your "Focus assist" / "Do not disturb" is set to suppress non-priority apps, you won't see the warnings. The 21:00 lock+suspend still fires.
- **Resume event source:** the wake-loop uses `Microsoft-Windows-Power-Troubleshooter` Event ID 1, which logs on every return from any low-power state. If you've disabled the Power-Troubleshooter event channel, the wake-loop won't fire — verify with `Get-WinEvent -LogName System -ProviderName Microsoft-Windows-Power-Troubleshooter -MaxEvents 1`.
- **Task Scheduler "Limited" run level:** tasks run as the current user without elevation. If the user account doesn't have rights to lock the workstation (very unusual), the lock step is best-effort and the suspend still proceeds.

## Tests

**Linux** — 68 unit tests in `bats`:

```bash
sudo pacman -S bats   # or your distro's equivalent
bats tests/
```

68 unit tests covering the pure logic helpers: window detection across all three windows, per-window override and cooldown isolation, `agent_mode_active` semantics, `window_end_epoch` resolution including the bedtime midnight roll, and the original bedtime edge cases (malformed input, empty file, garbage content, exact 12-hour boundary, multi-line log last-entry-wins, corrupted timestamp fails closed via stderr).

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

If you want website/app blocking rather than scheduled screen lock + step-away enforcement, one of these will fit better.

**Opposite direction, will confuse a search:**

- [bulletmark/sleep-inhibitor](https://github.com/bulletmark/sleep-inhibitor), [mrmekon/circadian](https://github.com/mrmekon/circadian) — these *prevent* suspend or suspend-on-idle. Useful tools, opposite trigger condition.

The specific combination of *scheduled multi-window screen lock + friction override + wake-loop + agent-mode escape hatch*, free and scriptable, doesn't seem to exist anywhere else, which is why this repo exists. (The Windows port is older and still hard-suspends at bedtime — see TODO.)

## TODO

- **Windows three-window port + drop-suspend port.** The Linux build has lunch and exercise+dinner windows with per-window override isolation, and no longer suspends at bedtime (relying on the lock loop + `sleep-agent` instead). The Windows build is still bedtime-only and still hard-suspends. Bringing parity requires porting the window detection and per-window override files from `lib/sleep-common.sh` to `lib/sleep-common.ps1`, adding lunch/dinner triggers to `install.ps1`, making `sleep-enforce.ps1` and `sleep-override.ps1` window-aware, removing the `SetSuspendState` call, and porting `sleep-agent` (Windows equivalent of the GNOME `DisplayConfig` blank is `SetThreadExecutionState(ES_DISPLAY_REQUIRED)` toggled off, plus monitor-off via `SendMessage(WM_SYSCOMMAND, SC_MONITORPOWER, 2)`).
- **Non-GNOME `sleep-agent` display blank.** The current implementation calls Mutter's `DisplayConfig` D-Bus interface, so only GNOME blanks the display explicitly. KDE has a similar interface (`org.kde.KWin`), sway/Wayland compositors expose `wlr-output-power-management`, and X11 supports `xset dpms force off`. Detect and dispatch.

## Origin

Built in a single late-night session because I couldn't stop working past 9pm and reminders weren't cutting it. Design and plan docs are preserved in `docs/specs/` and `docs/plans/` for anyone curious about how it came together — they're frozen at the original 21:30 schedule, so trust this README and the code for current behavior.

## License

MIT. See [LICENSE](LICENSE).
