# Bedtime Lockdown

Linux service that hard-suspends my machine at 9:30pm every night and keeps it suspended until 6:00am, with a deliberately high-friction override path for genuine emergencies.

## Why

Reminders don't work for late-night work compulsion. This is the OS-level hard wall.

## Schedule

| Time      | Event                                                |
|-----------|------------------------------------------------------|
| 9:00pm    | Notification: "Bedtime in 30 minutes."               |
| 9:25pm    | Notification: "Bedtime in 5 minutes."                |
| 9:30pm    | Lock screen + suspend.                               |
| 9:30pm – 6:00am | If machine wakes, suspend again ~3 minutes later. |
| 6:00am    | Window ends.                                         |

## Override

Run `sleep-override` from any terminal. Answer three questions. Get one hour. Limit: one override per 12 hours.

## Install

```bash
./install.sh
```

Requires a systemd-based Linux desktop with `notify-send` and a graphical session manager that responds to `loginctl lock-session`. Tested on Manjaro + GNOME on Wayland.

## Test

`bats` (Bash Automated Testing System) runs the unit test suite. It's only needed for development, not for using the system day-to-day.

```bash
sudo pacman -S bats   # one-time install on Manjaro
bats tests/
```

## Uninstall

```bash
./uninstall.sh
```

State files in `~/.config/sleep/` are preserved (logs are useful for self-review). Remove manually if desired.

## Files

- `bin/sleep-{warn,enforce,override,status}` — CLI scripts
- `lib/sleep-common.sh` — shared logic, the only thing with tests
- `systemd/sleep-*.{service,timer}` — schedules
- `tests/test_common.bats` — bats tests for the logic library

## Design

See `docs/specs/2026-05-07-bedtime-lockdown-design.md`.
