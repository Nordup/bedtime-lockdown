# Bedtime Lockdown

Linux service that hard-suspends your machine at bedtime and keeps it suspended through the night, with a deliberately high-friction override path for genuine emergencies.

Built because reminders don't work when you're the kind of person who tells yourself "just five more minutes" at 1am every night.

## What it does

At 8:45pm and 8:55pm, you get notifications. At 9:00pm, the screen locks and the machine suspends. Wake it any time before 6am and it suspends again 10 minutes later. Wake again, suspend again. This continues until 6:00am.

If you have a real emergency, run `sleep-override` from any terminal. It asks three deliberately uncomfortable questions, logs your answers, and grants exactly one hour of unlock. Once per 12 hours, max.

| Time         | Event                                                |
|--------------|------------------------------------------------------|
| 8:45pm       | Notification: "Bedtime in 15 minutes."               |
| 8:55pm       | Notification: "Bedtime in 5 minutes."                |
| 9:00pm       | Lock screen + suspend.                               |
| 9pm – 6am    | If machine wakes, suspend again 10 minutes later.    |
| 6:00am       | Window ends.                                         |

## Why

Most "focus" tools for Linux block websites or apps. None of them turn the computer off. Cold Turkey's *Frozen Turkey* mode is the closest match conceptually but it's Windows/Mac only. So this is essentially a small Linux clone — about 200 lines of bash and six systemd unit files.

The override is the design's interesting part. Pure bedtime locks tend to fail in two failure modes: (a) too easy to override → user uses it every night and it changes nothing, (b) too hard to override → user disables the whole system on the first stressful night. The three-question form is calibrated to be slow enough that addiction-brain takes the path of least resistance and goes to bed, while still giving you a way out if there's an actual fire.

## Requirements

- A systemd-based Linux desktop.
- `notify-send` (libnotify) for the warning notifications.
- A graphical session that responds to `loginctl lock-session`.
- Polkit configured to let the user run `systemctl suspend` without a password (default on most distros, including Manjaro).

Tested on Manjaro + GNOME on Wayland. Should work on any modern systemd Linux with a desktop environment.

## Install

```bash
git clone https://github.com/Nordup/bedtime-lockdown
cd bedtime-lockdown
./install.sh
```

This copies four scripts to `~/.local/bin/`, the shared library to `~/.local/share/sleep/`, six systemd user units to `~/.config/systemd/user/`, and enables the timers. Runtime state (logs, override flag) lives in `~/.config/sleep/`.

After install, three new commands are on your PATH:

- `sleep-status` — show current state, last 5 enforce events, last 5 overrides.
- `sleep-override` — interactive 3-question CLI to grant a 1-hour unlock.
- `sleep-warn` and `sleep-enforce` exist but you don't run them manually; systemd does.

## Customize the schedule

Edit `~/.local/share/sleep/sleep-common.sh`:

```bash
LOCKDOWN_START_HHMM=2100              # bedtime, 24h, no colon
LOCKDOWN_END_HHMM=600                 # window end (0600 = 6am)
OVERRIDE_DURATION_SEC=3600            # 1h unlock per override
COOLDOWN_SEC=$((12 * 3600))           # one override per 12h
```

If you change `LOCKDOWN_START_HHMM`, also update the warning timer files so the notifications still land in lockstep:

- `~/.config/systemd/user/sleep-warn-15.timer` — `OnCalendar=` 15 min before bedtime
- `~/.config/systemd/user/sleep-warn-5.timer` — `OnCalendar=` 5 min before bedtime

Then reload: `systemctl --user daemon-reload && systemctl --user restart sleep-enforce.timer`.

## Uninstall

```bash
./uninstall.sh
```

Disables the timers, removes the binaries and unit files. Your state directory `~/.config/sleep/` is preserved so the override log survives uninstall — useful for self-review. Delete it manually with `rm -rf ~/.config/sleep` if you don't want to keep it.

## How it works

Four bash scripts and six systemd user units. No daemon, no language runtime, no third-party deps.

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
  sleep-enforce.{service,timer}    fires every 10 min; suspends if in window
```

`sleep-enforce` is the heart. Each invocation:

1. If outside the lockdown window, exit silently (this is what happens 144 of 144 daytime fires).
2. If an override is currently active, exit silently.
3. Otherwise: log the attempt, lock the session, call `systemctl suspend`.

The wake-loop emerges naturally from the `sleep-enforce.timer` config: `OnUnitInactiveSec=10min` schedules each subsequent fire for 10 minutes after the previous service ended. Because `systemctl suspend` blocks until the kernel resumes, "service ends" coincides with "user just woke the machine." So the 10-minute clock self-paces from each wake.

`sleep-override` is intentionally slow. It asks three questions: what are you doing, why tonight specifically and not tomorrow morning, what time will you actually stop. Empty answers are rejected. The answers go into `~/.config/sleep/overrides.log` so you can read them back later when you wonder why you keep losing sleep. Then it writes `now+1h` into `~/.config/sleep/override-until`. Enforce reads that file on every fire and skips suspending while the override is live.

## Anti-cheat philosophy

This is not tamper-proof. You are root on your own machine. If you really want to disable it at 8:55pm, `systemctl --user stop sleep-enforce.timer` works. The system relies on the override being faster and lower-shame than disabling — addiction-brain takes the path of least resistance, and the override path is paved while the disable path requires a deliberate moral act. Calibrate the override friction up if you find yourself bypassing too easily; calibrate it down if you find yourself disabling.

## Caveats

- **Wifi resume on MediaTek chipsets:** some `mt7921e` cards throw `error -110` on resume. The driver re-initializes itself successfully most of the time. If yours doesn't, `sudo modprobe -r mt7921e && sudo modprobe mt7921e` reloads it.
- **Screen locking depends on your DE** correctly handling `loginctl lock-session`. Tested on GNOME Wayland. Should work on KDE, XFCE, etc., but verify on your setup.
- **Service stays "active" during suspend** in systemd's view, because `systemctl suspend` blocks until resume. This is intentional — it's what lets the wake-loop self-pace from each resume rather than from absolute clock marks.

## Tests

```bash
sudo pacman -S bats   # or your distro's equivalent
bats tests/
```

28 unit tests covering the pure logic helpers. Edge cases: malformed input, empty file, garbage content, exact 12-hour boundary, multi-line log (last entry wins), corrupted timestamp fails closed.

## Related projects

If this isn't quite what you want, here's the landscape — all checked at the time of writing.

**Direct conceptual match, different OS:** Cold Turkey's *Frozen Turkey* mode (Windows/Mac) schedules a computer-level lockout with bypass-prevention. This project is consciously a small Linux clone of that idea. If you're on Windows or macOS and don't need anything custom, just buy Cold Turkey.

**Same mechanism (schedule a system action), no addiction-aware design:**

- [jhasse/sleeptimer](https://github.com/jhasse/sleeptimer) — generic shutdown timer for Linux/Windows.
- [Shingyx/schedule-shutdown](https://github.com/Shingyx/schedule-shutdown) — cross-platform scheduled shutdowns.
- [lukaslangrock/ShutdownTimerClassic](https://github.com/lukaslangrock/ShutdownTimerClassic) — Windows-only.
- Autopoweroff, qshutdown — Linux scheduled-shutdown utilities.

These are general-purpose tools — no friction override, no wake-loop, no concept of bedtime as a self-discipline product. If you want "shutdown at X" with no behavioral mechanic, one of these is simpler than this project.

**Same motivation (Linux anti-procrastination), different mechanism (blocks apps/sites instead of suspending):**

- [Chomper](https://github.com/parkerlreed/chomper) — Linux internet blocker, built specifically because Cold Turkey doesn't run on Linux. Blocks domains via iptables.
- [zengargoyle/selfcontrol](https://github.com/zengargoyle/selfcontrol) — port of Mac SelfControl. Old (GTK2), "most likely broken" per its own readme.
- LeechBlock, Pluckeye, DigitalZen — content blockers, mostly browser-based or commercial.

If you want website/app blocking rather than full machine suspend, one of these will fit better.

**Opposite direction, will confuse a search:**

- [bulletmark/sleep-inhibitor](https://github.com/bulletmark/sleep-inhibitor), [mrmekon/circadian](https://github.com/mrmekon/circadian) — these *prevent* suspend or suspend-on-idle. Useful tools, opposite trigger condition.

The specific combination of *Linux + scheduled hard suspend + friction override + wake-loop* doesn't seem to exist anywhere else, which is why this repo exists.

## Origin

Built in a single late-night session because I couldn't stop working past 9pm and reminders weren't cutting it. Design and plan docs are preserved in `docs/specs/` and `docs/plans/` for anyone curious about how it came together — they're frozen at the original 21:30 schedule, so trust this README and the code for current behavior.

## License

MIT. See [LICENSE](LICENSE).
