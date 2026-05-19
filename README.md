# Bedtime Lockdown

Cross-platform Python desktop service that locks your screen at three daily windows — bedtime, lunch, exercise+dinner — and keeps re-locking it every five minutes until each window ends, with a deliberately high-friction override path for genuine emergencies and an explicit "agent-mode" escape hatch that blanks the display so long-running background work isn't blocked. Same code, same behavior on Linux and Windows.

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

If you're stepping away during any window and want the screen physically off (and you want a long-running agent to keep working in the background), run `sleep-agent`. It locks the session, blanks the display, and spawns a backgrounded inhibitor that holds idle-suspend off until the current window ends. The re-lock loop also defers while agent-mode is active, so coming back is just one password prompt. Mouse or keyboard wakes the display back to the lock screen. Works the same in all three windows. Logged to `agent.log`.

## Why

Most "focus" tools block websites or apps. None of them lock the screen at scheduled times — or even force you to step away from it during meals. Cold Turkey's *Frozen Turkey* mode is the closest match conceptually for the bedtime piece, and it's the inspiration for this project — a free, scriptable equivalent that works on both Linux and Windows from one Python codebase.

The override is the design's interesting part. Pure bedtime locks tend to fail in two failure modes: (a) too easy to override → user uses it every night and it changes nothing, (b) too hard to override → user disables the whole system on the first stressful night. The three-question form is calibrated to be slow enough that addiction-brain takes the path of least resistance and goes to bed, while still giving you a way out if there's an actual fire.

## Requirements

- **Python 3.9 or newer.** Pre-installed on most Linux distros; on Windows install from python.org or the Microsoft Store.
- **Linux:** a systemd-based desktop, `notify-send` (libnotify), a graphical session that responds to `loginctl lock-session`. For `sleep-agent`'s display-blank step: GNOME (Mutter) — other DEs warn and continue.
- **Windows:** Windows 10 or 11. PowerShell 5.1 (ships by default) for the toast notification fallback. Optional: `pip install sleep-lockdown[windows]` pulls `winrt-Windows.UI.Notifications` for native toasts instead of subprocess-to-PowerShell.

Tested on Manjaro + GNOME on Wayland and on Windows 11. No third-party Python dependencies on Linux. ctypes-only on Windows for the lock/blank/inhibit primitives.

## Install

Same command on both OSes:

**Linux:**

```bash
git clone https://github.com/Nordup/bedtime-lockdown
cd bedtime-lockdown
./install.sh
```

This copies the Python package to `~/.local/share/sleep-lockdown/`, writes five shell shims to `~/.local/bin/`, installs seventeen systemd user units to `~/.config/systemd/user/`, and enables ten timers. Runtime state (logs, override flags) lives in `~/.config/sleep/`.

**Windows:**

```powershell
git clone https://github.com/Nordup/bedtime-lockdown
cd bedtime-lockdown
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Same shape: copies the package to `%LOCALAPPDATA%\sleep-lockdown\lib\`, writes five `.cmd` shims to `%LOCALAPPDATA%\sleep-lockdown\bin\`, registers ten Task Scheduler tasks under `\BedtimeLockdown\`, adds the bin directory to your user PATH. Runtime state lives in `%LOCALAPPDATA%\sleep-lockdown\state\`.

Both bootstrappers just exec `python3 install.py` / `python install.py` — the real installer is cross-platform Python. You can also run it directly if you prefer.

After install, open a new terminal and five commands are available on either OS:

- `sleep-status` — show all three windows, agent-mode state, last 5 enforce events, last 5 overrides.
- `sleep-override` — interactive 3-question CLI. Detects the active window automatically.
- `sleep-agent` — one-shot: lock, blank the display, inhibit idle-suspend until the current window ends. No questions, no cooldown — designed for routine "stepping away with an agent running" use, multiple times per day.
- `sleep-warn` and `sleep-enforce` exist but you don't run them manually; the scheduler does.

## Customize the schedule

Edit `sleep_lockdown/config.py`:

```python
LOCKDOWN_START_HHMM = 2100          # bedtime: lock at 21:00
LOCKDOWN_END_HHMM   = 600           # window end (06:00)
LUNCH_START_HHMM    = 1130          # lunch break starts
LUNCH_END_HHMM      = 1215          # lunch break ends
DINNER_START_HHMM   = 1630          # exercise+dinner starts
DINNER_END_HHMM     = 1830          # exercise+dinner ends
OVERRIDE_DURATION_SEC = 3600         # bedtime override: 1 hour reprieve
COOLDOWN_SEC          = 12 * 3600    # one override per 12h, per window
```

Then re-run `install.sh` / `install.ps1`. On Linux, the systemd calendar timers' `OnCalendar=` lines are hardcoded — if you change a `*_START_HHMM`, edit the matching three units by hand (see comments in `config.py`) and run `systemctl --user daemon-reload`. On Windows, the Task Scheduler triggers are regenerated from `config.py` automatically on every `install.py` run.

## Uninstall

```bash
./uninstall.sh        # Linux
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1   # Windows
```

State directories are preserved by default. On Linux remove with `rm -rf ~/.config/sleep`; on Windows pass `--purge` to the uninstaller.

## How it works

One Python package (`sleep_lockdown`) with five command entry points. Pure logic — window detection, override state, agent-mode state, cooldown calculation — lives in `common.py` and has no platform knowledge. Side effects (lock the session, blank the display, send a notification, hold an idle-suspend inhibitor) live in `platforms/linux.py` and `platforms/windows.py`, dispatched at import time based on `sys.platform`.

```
sleep_lockdown/
  config.py             constants + state dir resolution
  common.py             pure logic (window detection, override + agent state)
  enforce.py            the locker; main() invoked by systemd / Task Scheduler
  warn.py               notification wrapper
  override.py           interactive friction CLI (window-aware)
  agent.py              agent-mode: lock + blank + inhibit until window-end
  status.py             read-only diagnostic
  platforms/
    base.py             abstract backend interface
    linux.py            gdbus / loginctl / notify-send / systemd-inhibit (subprocess)
    windows.py          ctypes user32/kernel32 + optional winrt for toasts
```

`sleep-enforce` is the heart. Each invocation:

1. Detect the current window (`bedtime` / `lunch` / `dinner` / `none`). If `none`, exit silently — most fires hit this branch.
2. If agent-mode is active, exit silently — `sleep-agent` has the screen blanked and idle-suspend inhibited.
3. If an override is active for the current window, exit silently.
4. Otherwise: log the attempt with the window name, lock the session.

All three windows share this single code path. On **Linux** the lock is `loginctl lock-session` (via subprocess); the wake-loop is systemd's monotonic `sleep-enforce.timer` (`OnUnitInactiveSec=5min`) plus three calendar timers (one per window) that phase-align the first fire to the window start. The service is `Type=oneshot`, so if calendar + monotonic both fire close together systemd silently skips the second activation. On **Windows** the lock is `user32.LockWorkStation()` (via ctypes); the wake-loop is a Task Scheduler event trigger on `Microsoft-Windows-Power-Troubleshooter` Event ID 1 (logged on every resume from low-power state) with a 5-minute delay. Task Scheduler's `MultipleInstancesPolicy=IgnoreNew` plays the role of `Type=oneshot`.

`sleep-override` is intentionally slow. It detects which window is active, asks three questions tailored to that window — what are you doing, why is *this* break the wrong time to step away (or, for bedtime, why tonight and not tomorrow morning), what time will you actually stop. Empty answers are rejected. Answers go into a per-window log (`overrides.log`, `overrides-lunch.log`, `overrides-dinner.log`). Bedtime grants `now+1h` and writes `override-until`; breaks grant until end of the current window and write `override-until-lunch` or `override-until-dinner`. Enforce reads only the file matching the current window, so skipping lunch never affects bedtime. Single-writer guard is `fcntl.flock` on Linux, `msvcrt.locking` on Windows — same role: prevent two concurrent invocations from both passing the cooldown check and double-appending to the log.

`sleep-agent` is the routine-friction counterpart. Inside any active window, one command flips the machine into agent-mode: locks the session, blanks the display, spawns a detached backgrounded inhibitor that holds idle-sleep blocked until the window ends and then exits on its own. It writes `agent-until` (the window-end epoch) so `sleep-enforce` skips its lock loop, and `agent-inhibit.pid` so a re-run can clean up any leftover inhibitor. One line per use lands in `agent.log`. No questions, no cooldown — designed for 3x/day routine ("walking away during lunch, an agent is running"), not for justifying rule-breaks.

The display-blank and inhibitor primitives differ per OS:

- **Linux:** display blank via Mutter's `org.gnome.Mutter.DisplayConfig.SetPowerSaveMode` D-Bus method (level 3 = off), invoked via `gdbus` subprocess. Inhibitor via `systemd-inhibit --what=idle:sleep --mode=block sleep <duration>` as a detached child — systemd-logind holds the inhibitor for the lifetime of that child, and the `sleep` self-terminates at window-end.
- **Windows:** display blank via `SendMessageW(HWND_BROADCAST, WM_SYSCOMMAND, SC_MONITORPOWER, 2)` (ctypes user32). Inhibitor via a detached Python child process that holds `SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)` (ctypes kernel32) and `time.sleep`s for the duration. Same shape as the Linux model.

Wake-on-input is free on both OSes: the OS routes keyboard/mouse events to the compositor / window manager, which immediately powers the display back on. No extra code.

## Anti-cheat philosophy

This is not tamper-proof. You are root / administrator on your own machine. If you really want to disable it at 8:55pm, `systemctl --user stop sleep-enforce.timer` (Linux) or `schtasks /Change /TN \BedtimeLockdown\enforce-bedtime /DISABLE` (Windows) works. The system relies on the override being faster and lower-shame than disabling — addiction-brain takes the path of least resistance, and the override path is paved while the disable path requires a deliberate moral act. Calibrate the override friction up if you find yourself bypassing too easily; calibrate it down if you find yourself disabling.

## Caveats

- **Screen locking depends on your DE / WM** correctly handling `loginctl lock-session` (Linux) or `LockWorkStation` (Windows). Both are widely supported.
- **`sleep-agent`'s display blank is GNOME-specific on Linux.** It calls Mutter's `DisplayConfig` D-Bus interface. On other DEs the script warns and continues — lock + inhibitor still apply, but the screen won't go dark explicitly. Equivalent calls for KDE/XFCE/sway are TODO.
- **`sleep-enforce` does not suspend the machine.** Earlier versions hard-suspended at bedtime; that broke overnight agent runs. The lock loop carries the weight now, with `sleep-agent` as the explicit "step away" command.
- **Toast notifications on Windows** use `Windows.UI.Notifications` via either the `winrt` Python package (if installed) or a subprocess to PowerShell as fallback. If you've disabled toasts globally or set Focus Assist to suppress non-priority apps, you won't see the warnings — the lock loop still fires.
- **PowerShell PATH update on Windows** is via `setx`-style write of the user environment, which only affects new processes. Open a new terminal after install.

## Tests

Pytest, runs on both OSes. Pure-logic only — no platform side effects in CI.

```bash
pip install pytest        # or pip install -e .[test]
pytest tests/
```

60 tests covering window detection across all three windows, per-window override and cooldown isolation, `agent_mode_active` semantics, `window_end_epoch` resolution including the bedtime midnight roll, malformed input, empty file, garbage content, exact 12-hour boundary, multi-line log last-entry-wins, and corrupted-timestamp fail-closed behavior.

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

The specific combination of *scheduled multi-window screen lock + friction override + wake-loop + agent-mode escape hatch*, free and scriptable on both Linux and Windows from one codebase, doesn't seem to exist anywhere else, which is why this repo exists.

## TODO

- **Non-GNOME `sleep-agent` display blank on Linux.** The current implementation calls Mutter's `DisplayConfig` D-Bus interface, so only GNOME blanks the display explicitly. KDE has a similar interface (`org.kde.KWin`), sway/Wayland compositors expose `wlr-output-power-management`, and X11 supports `xset dpms force off`. Detect and dispatch in `platforms/linux.py`.
- **Toast on Windows without PowerShell fallback.** The `winrt-Windows.UI.Notifications` package is optional; if missing we subprocess to PowerShell. Make it install-by-default on the `[windows]` extra, or switch to a smaller alternative.

## Origin

Built in a single late-night session because I couldn't stop working past 9pm and reminders weren't cutting it, then rewritten in Python months later to unify the Linux bash and Windows PowerShell ports under one codebase. Design and plan docs from the original bash era are preserved in `docs/specs/` and `docs/plans/` for anyone curious — they're frozen at earlier schedules, so trust this README and `sleep_lockdown/config.py` for current behavior.

## License

MIT. See [LICENSE](LICENSE).
