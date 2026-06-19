# Bedtime Lockdown

Cross-platform Python desktop service that locks your screen at three daily windows — bedtime, lunch, exercise+dinner — and keeps re-locking it every three minutes until each window ends, with a deliberately high-friction override path for genuine emergencies and an explicit "agent-mode" escape hatch so long-running background work isn't blocked. Same code, same behavior on Linux and Windows.

Built because reminders don't work when you're the kind of person who tells yourself "just five more minutes" at 1am every night — and the same brain skips meals and skips exercise the same way.

## What it does

Three daily enforcement windows, all on the same code path: lock the screen and re-lock every 3 min until the window ends. No automatic suspend — that broke overnight agent runs, and the screen-lock alone (plus the friction of typing your password every three minutes) carries enough weight in practice.

| Time            | Event                                                       |
|-----------------|-------------------------------------------------------------|
| 11:15am         | Notification: "Lunch in 15 minutes."                        |
| 11:25am         | Notification: "Lunch in 5 minutes."                         |
| 11:30am – 12:15pm | Screen re-locks every 3 min.                              |
| 4:15pm          | Notification: "Exercise + dinner in 15 minutes."            |
| 4:25pm          | Notification: "Exercise + dinner in 5 minutes."             |
| 4:30pm – 6:30pm | Screen re-locks every 3 min.                                |
| 8:45pm          | Notification: "Bedtime in 15 minutes."                      |
| 8:55pm          | Notification: "Bedtime in 5 minutes."                       |
| 9:00pm – 6:00am | Screen re-locks every 3 min.                                |

If you have a real emergency inside a **daytime** window (lunch or dinner), run `sleep-override` from any terminal. It detects which window is active, asks three deliberately uncomfortable questions, logs your answers, and grants a reprieve until the end of the current break. One override per window per 12 hours — each window's quota is independent. **Bedtime has no override**: the night lock is non-negotiable, and there is nothing to grant.

If you're stepping away during any window and want a long-running agent to keep working in the background, run `sleep-agent`. It locks the session and spawns a backgrounded inhibitor that holds idle-suspend off until the current window ends. The re-lock loop also defers while agent-mode is active, so coming back is just one password prompt. Run `sleep-agent` again any time to re-assert it — while agent-mode is already active a re-run re-locks the session and revives the inhibitor if its process died, without ever shortening the deadline. Works the same in all three windows. Logged to `agent.log`.

> **Display blank — platform note.** On **Windows**, agent-mode also turns the monitor off (and a keypress wakes it). On **Linux** it's currently **lock-only**: GNOME 50 removed the D-Bus method this tool used to power the display off on demand, and the alternatives (e.g. a DDC/CI power-off) can't be woken by a keypress — some monitors need a physical power-cycle — so the screen locks and the PC stays awake but the display stays lit. Reviving an on-demand, wake-on-input blank for KDE/sway/X11 is on the roadmap.

## Why

Most "focus" tools block websites or apps. None of them lock the screen at scheduled times — or even force you to step away from it during meals. Cold Turkey's *Frozen Turkey* mode is the closest match conceptually for the bedtime piece, and it's the inspiration for this project — a free, scriptable equivalent that works on both Linux and Windows from one Python codebase.

The override is the design's interesting part. Friction locks tend to fail in two ways: (a) too easy to override → you use it every night and it changes nothing, (b) too hard to override → you disable the whole system on the first stressful night. The daytime breaks (lunch, dinner) thread that needle with a three-question form, calibrated to be slow enough that addiction-brain takes the path of least resistance and steps away, while still giving you a way out if there's an actual fire. Bedtime takes the harder line: no override at all. After enough nights of bargaining with the old one-hour reprieve, the only honest fix was to remove the bargaining chip — the night lock is non-negotiable, and the sole remaining escape is the deliberate act of stopping the scheduler.

## Requirements

- **Python 3.9 or newer.** Pre-installed on most Linux distros; on Windows install from python.org or the Microsoft Store.
- **Linux:** a systemd-based desktop, `notify-send` (libnotify), a graphical session that responds to `loginctl lock-session`. `sleep-agent` is lock-only on Linux (no on-demand display blank — GNOME 50 removed the API; see the platform note above).
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
- `sleep-override` — interactive 3-question CLI for the daytime windows (lunch, dinner). Detects the active window automatically. Refuses during bedtime — the night lock has no override.
- `sleep-agent` — one-shot: lock the screen and inhibit idle-suspend until the current window ends (also turns the display off on Windows; lock-only on Linux). No questions, no cooldown — designed for routine "stepping away with an agent running" use, multiple times per day.
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
COOLDOWN_SEC          = 12 * 3600    # one override per 12h, per window
OVERRIDE_ENABLED_WINDOWS = ("lunch", "dinner")  # bedtime has no override
```

The re-lock cadence (every 3 minutes) is not in `config.py` — on Linux it lives in the systemd enforce timer, and on Windows in the Task Scheduler trigger that `install.py` writes. Change it there, then reinstall.

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
  agent.py              agent-mode: lock + inhibit until window-end (+ blank on Windows)
  status.py             read-only diagnostic
  platforms/
    base.py             abstract backend interface
    linux.py            gdbus / loginctl / notify-send / systemd-inhibit (subprocess)
    windows.py          ctypes user32/kernel32 + optional winrt for toasts
```

`sleep-enforce` is the heart. Each invocation:

1. Detect the current window (`bedtime` / `lunch` / `dinner` / `none`). If `none`, exit silently — most fires hit this branch.
2. If agent-mode is active, exit silently — `sleep-agent` has the session locked and idle-suspend inhibited.
3. If an override is active for the current window, exit silently.
4. Otherwise: log the attempt with the window name, lock the session.

All three windows share this single code path. On **Linux** the lock is `loginctl lock-session` (via subprocess); the wake-loop is systemd's monotonic `sleep-enforce.timer` (`OnUnitInactiveSec=3min`) plus three calendar timers (one per window) that phase-align the first fire to the window start. The service is `Type=oneshot`, so if calendar + monotonic both fire close together systemd silently skips the second activation. On **Windows** the lock is `user32.LockWorkStation()` (via ctypes); the wake-loop is a Task Scheduler event trigger on `Microsoft-Windows-Power-Troubleshooter` Event ID 1 (logged on every resume from low-power state) with a 3-minute delay. Task Scheduler's `MultipleInstancesPolicy=IgnoreNew` plays the role of `Type=oneshot`.

`sleep-override` is intentionally slow. It detects which window is active, asks three questions tailored to that window — what are you doing, why is *this* break the wrong time to step away, what time will you actually stop. Empty answers are rejected. Answers go into a per-window log (`overrides.log`, `overrides-lunch.log`, `overrides-dinner.log`). Lunch and dinner grant until end of the current window and write `override-until-lunch` or `override-until-dinner`; bedtime is refused before any questions (`OVERRIDE_ENABLED_WINDOWS` excludes it), so enforce honors no bedtime reprieve. Enforce reads only the file matching the current window, so skipping lunch never affects dinner. Single-writer guard is `fcntl.flock` on Linux, `msvcrt.locking` on Windows — same role: prevent two concurrent invocations from both passing the cooldown check and double-appending to the log.

`sleep-agent` is the routine-friction counterpart. Inside any active window, one command flips the machine into agent-mode: locks the session and spawns a detached backgrounded inhibitor that holds idle-sleep blocked until the window ends and then exits on its own (on Windows it also turns the display off). It writes `agent-until` (the window-end epoch) so `sleep-enforce` skips its lock loop, and `agent-inhibit.pid` so a re-run can find and revive a dead inhibitor. Re-running while agent-mode is already active doesn't start a fresh session — it re-asserts the lock and respawns the inhibitor only if its pinned process has died, leaving `agent-until` untouched (re-enabling can only strengthen enforcement, never shorten it). One line per use lands in `agent.log`. No questions, no cooldown — designed for 3x/day routine ("walking away during lunch, an agent is running"), not for justifying rule-breaks.

The inhibitor primitive differs per OS (and Windows adds a display blank Linux no longer has):

- **Linux:** lock-only — no display blank. GNOME 50 removed `org.gnome.Mutter.DisplayConfig.SetPowerSaveMode` (the only on-demand display-off method), and a DDC/CI power-off can't be woken by a keypress, so agent-mode leaves the monitor lit. Inhibitor via `systemd-inhibit --what=idle:sleep --mode=block sleep <duration>` as a detached child — systemd-logind holds the inhibitor for the lifetime of that child, and the `sleep` self-terminates at window-end.
- **Windows:** display blank via `SendMessageW(HWND_BROADCAST, WM_SYSCOMMAND, SC_MONITORPOWER, 2)` (ctypes user32). Inhibitor via a detached Python child process that holds `SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)` (ctypes kernel32) and `time.sleep`s for the duration. Same shape as the Linux model.

Wake-on-input is free on both OSes: the OS routes keyboard/mouse events to the compositor / window manager, which immediately powers the display back on. No extra code.

## Anti-cheat philosophy

This is not tamper-proof. You are root / administrator on your own machine. If you really want to disable it at 8:55pm, `systemctl --user stop sleep-enforce.timer` (Linux) or `schtasks /Change /TN \BedtimeLockdown\enforce-bedtime /DISABLE` (Windows) works. For the daytime breaks the system relies on the override being faster and lower-shame than disabling — addiction-brain takes the path of least resistance, and the override path is paved while the disable path requires a deliberate moral act. Bedtime removes even that paved path: with no override, the only ways through the night are agent-mode (a deliberate, logged step-away that keeps the screen locked) or stopping the scheduler outright (the moral act). Calibrate the daytime override friction up if you find yourself bypassing too easily; calibrate it down if you find yourself disabling.

## Caveats

- **Screen locking depends on your DE / WM** correctly handling `loginctl lock-session` (Linux) or `LockWorkStation` (Windows). Both are widely supported.
- **`sleep-agent` is lock-only on Linux.** GNOME 50 removed the `DisplayConfig.SetPowerSaveMode` method it used to turn the display off, so the screen locks and the PC stays awake but the monitor stays lit. (A DDC/CI power-off via `ddcutil` does darken the screen, but on real panels it can't be woken by a keypress — some need a physical power-cycle — so it's unsuitable.) KDE/sway/X11 display-off paths that also wake on input are TODO. Windows still blanks the display normally.
- **`sleep-enforce` does not suspend the machine.** Earlier versions hard-suspended at bedtime; that broke overnight agent runs. The lock loop carries the weight now, with `sleep-agent` as the explicit "step away" command.
- **Toast notifications on Windows** use `Windows.UI.Notifications` via either the `winrt` Python package (if installed) or a subprocess to PowerShell as fallback. If you've disabled toasts globally or set Focus Assist to suppress non-priority apps, you won't see the warnings — the lock loop still fires.
- **PowerShell PATH update on Windows** is via `setx`-style write of the user environment, which only affects new processes. Open a new terminal after install.

## Tests

Pytest, runs on both OSes. Pure-logic only — no platform side effects in CI.

```bash
pip install pytest        # or pip install -e .[test]
pytest tests/
```

76 tests covering window detection across all three windows, the override policy (bedtime disabled, lunch/dinner enabled), per-window override and cooldown isolation, `agent_mode_active` semantics, agent-mode re-assert (re-lock, dead-inhibitor revival, deadline never shortened, lock-only messaging), `window_end_epoch` resolution including the bedtime midnight roll, malformed input, empty file, garbage content, exact 12-hour boundary, multi-line log last-entry-wins, and corrupted-timestamp fail-closed behavior.

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

- **Linux display blank (any DE).** GNOME 50 removed the `DisplayConfig.SetPowerSaveMode` method the tool relied on, so Linux is currently lock-only. KDE exposes `org.kde.KWin`, sway/Wayland compositors expose `wlr-output-power-management`, and X11 supports `xset dpms force off`. Whichever path is chosen must pair power-off with wake-on-input — a raw DDC/CI power-off does not (the monitor can't be woken by a keypress). Detect and dispatch in `platforms/linux.py`.
- **Toast on Windows without PowerShell fallback.** The `winrt-Windows.UI.Notifications` package is optional; if missing we subprocess to PowerShell. Make it install-by-default on the `[windows]` extra, or switch to a smaller alternative.

## Origin

Built in a single late-night session because I couldn't stop working past 9pm and reminders weren't cutting it, then rewritten in Python months later to unify the Linux bash and Windows PowerShell ports under one codebase. Design and plan docs from the original bash era are preserved in `docs/specs/` and `docs/plans/` for anyone curious — they're frozen at earlier schedules, so trust this README and `sleep_lockdown/config.py` for current behavior.

## License

MIT. See [LICENSE](LICENSE).
