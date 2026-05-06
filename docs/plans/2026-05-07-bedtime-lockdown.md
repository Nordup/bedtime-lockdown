# Bedtime Lockdown Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Linux service that hard-suspends the machine at 9:30pm every night, keeps it suspended (via 3-min wake polling) until 6:00am, and provides a deliberately high-friction override CLI.

**Architecture:** Four bash scripts in `bin/` plus a shared logic library in `lib/`, deployed to `~/.local/bin/` and `~/.local/share/sleep/` respectively. Scheduling via systemd user timers in `systemd/`, deployed to `~/.config/systemd/user/`. State files (override flag, override log, enforce log) live in `~/.config/sleep/`. Tests via bats over the pure logic in the shared library.

**Tech Stack:** bash, GNU coreutils (`date`), systemd user units, libnotify (`notify-send`), bats (test runner).

---

## Source layout

```
sleep/
├── docs/
│   ├── specs/2026-05-07-bedtime-lockdown-design.md
│   └── plans/2026-05-07-bedtime-lockdown.md       # this file
├── bin/
│   ├── sleep-warn
│   ├── sleep-enforce
│   ├── sleep-override
│   └── sleep-status
├── lib/
│   └── sleep-common.sh
├── systemd/
│   ├── sleep-warn-2100.service
│   ├── sleep-warn-2100.timer
│   ├── sleep-warn-2125.service
│   ├── sleep-warn-2125.timer
│   ├── sleep-enforce.service
│   └── sleep-enforce.timer
├── tests/
│   └── test_common.bats
├── install.sh
├── uninstall.sh
└── README.md
```

## Install destinations

- `bin/*` → `~/.local/bin/`
- `lib/sleep-common.sh` → `~/.local/share/sleep/sleep-common.sh`
- `systemd/*` → `~/.config/systemd/user/`
- State at runtime: `~/.config/sleep/{override-until, overrides.log, enforce.log}`

## Convention used by every script

Every script in `bin/` starts with:

```bash
#!/usr/bin/env bash
set -euo pipefail
SLEEP_LIB="${SLEEP_LIB:-$HOME/.local/share/sleep}"
SLEEP_HOME="${SLEEP_HOME:-$HOME/.config/sleep}"
. "$SLEEP_LIB/sleep-common.sh"
```

The two env vars allow tests to redirect to a temp directory.

---

## Task 0: Test framework prerequisite

**Files:** none

- [ ] **Step 1: Install bats**

```bash
sudo pacman -S --needed bats
bats --version
```

Expected: prints `Bats 1.13.0` (or similar).

---

## Task 1: Shared library + tests

**Files:**
- Create: `lib/sleep-common.sh`
- Create: `tests/test_common.bats`

The library exposes three pure functions used by the scripts. All take explicit inputs (no implicit reads of `date` etc.) so they're trivially testable.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_common.bats`:

```bash
#!/usr/bin/env bats

setup() {
    SLEEP_HOME="$(mktemp -d)"
    export SLEEP_HOME
    SLEEP_LIB="$BATS_TEST_DIRNAME/../lib"
    . "$SLEEP_LIB/sleep-common.sh"
}

teardown() {
    rm -rf "$SLEEP_HOME"
}

@test "in-window: 21:30 is in lockdown window" {
    run is_in_lockdown_window 2130
    [ "$status" -eq 0 ]
}

@test "in-window: 23:59 is in lockdown window" {
    run is_in_lockdown_window 2359
    [ "$status" -eq 0 ]
}

@test "in-window: 00:00 is in lockdown window" {
    run is_in_lockdown_window 0000
    [ "$status" -eq 0 ]
}

@test "in-window: 05:59 is in lockdown window" {
    run is_in_lockdown_window 0559
    [ "$status" -eq 0 ]
}

@test "in-window: 06:00 is OUT of lockdown window (endpoint excluded)" {
    run is_in_lockdown_window 0600
    [ "$status" -ne 0 ]
}

@test "in-window: 21:29 is OUT of lockdown window" {
    run is_in_lockdown_window 2129
    [ "$status" -ne 0 ]
}

@test "in-window: 12:00 is OUT of lockdown window" {
    run is_in_lockdown_window 1200
    [ "$status" -ne 0 ]
}

@test "override_active: returns 1 when no file exists" {
    run override_active 1700000000
    [ "$status" -ne 0 ]
}

@test "override_active: returns 0 when override-until > now" {
    echo "1700000060" > "$SLEEP_HOME/override-until"
    run override_active 1700000000
    [ "$status" -eq 0 ]
}

@test "override_active: returns 1 when override-until <= now" {
    echo "1700000000" > "$SLEEP_HOME/override-until"
    run override_active 1700000000
    [ "$status" -ne 0 ]
}

@test "cooldown_remaining: prints 0 when no log exists" {
    run cooldown_remaining 1700000000
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "cooldown_remaining: prints seconds remaining when last override < 12h ago" {
    # last override at 1699999000, now is 1700000000 -> 1000s elapsed, 12*3600-1000 remaining
    printf "2025-01-01T00:00:00\ta\tb\tc\n" > "$SLEEP_HOME/overrides.log"
    # we can't set ISO timestamp easily — use the helper that reads epoch from line 2 column
    # Instead, write a line with an explicit epoch in column 1
    # Use ISO format that bash 'date -d' can parse
    last_iso=$(date -u -Iseconds -d @1699999000)
    printf "%s\ta\tb\tc\n" "$last_iso" > "$SLEEP_HOME/overrides.log"
    run cooldown_remaining 1700000000
    [ "$status" -eq 0 ]
    [ "$output" = "42200" ]   # 12*3600 - 1000
}

@test "cooldown_remaining: prints 0 when last override > 12h ago" {
    last_iso=$(date -u -Iseconds -d @1699956000)   # 12h+1000s before 1700000000
    printf "%s\ta\tb\tc\n" "$last_iso" > "$SLEEP_HOME/overrides.log"
    run cooldown_remaining 1700000000
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
bats tests/test_common.bats
```

Expected: every test fails with "command not found: is_in_lockdown_window" (or similar; `sleep-common.sh` doesn't exist yet).

- [ ] **Step 3: Implement the library**

Create `lib/sleep-common.sh`:

```bash
# Pure logic helpers for the bedtime-lockdown scripts.
# Sourced by bin/sleep-* and by tests.

# is_in_lockdown_window <HHMM>
# Returns 0 if the given 4-digit time is in [21:30, 06:00). Returns 1 otherwise.
is_in_lockdown_window() {
    local hhmm=$1
    # Strip leading zeros without triggering octal interpretation
    local n=$((10#$hhmm))
    if (( n >= 2130 || n < 600 )); then
        return 0
    fi
    return 1
}

# override_active <epoch_now>
# Returns 0 if $SLEEP_HOME/override-until exists and contains an epoch > now.
override_active() {
    local now=$1
    local f="$SLEEP_HOME/override-until"
    [[ -f "$f" ]] || return 1
    local until
    until=$(<"$f")
    [[ -n "$until" ]] || return 1
    (( until > now ))
}

# cooldown_remaining <epoch_now>
# Prints the number of seconds remaining in the 12h override cooldown,
# or 0 if no override is on cooldown. Always returns 0.
cooldown_remaining() {
    local now=$1
    local f="$SLEEP_HOME/overrides.log"
    if [[ ! -s "$f" ]]; then
        echo 0
        return 0
    fi
    local last_iso last_epoch elapsed remaining
    last_iso=$(tail -n 1 "$f" | cut -f1)
    last_epoch=$(date -d "$last_iso" +%s 2>/dev/null || echo 0)
    elapsed=$((now - last_epoch))
    remaining=$((12 * 3600 - elapsed))
    if (( remaining <= 0 )); then
        echo 0
    else
        echo "$remaining"
    fi
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
bats tests/test_common.bats
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/sleep-common.sh tests/test_common.bats
git commit -m "Add shared logic library with bats tests"
```

---

## Task 2: bin/sleep-warn

**Files:**
- Create: `bin/sleep-warn`

Trivial wrapper around `notify-send`. No tests — too thin to be worth mocking libnotify.

- [ ] **Step 1: Implement**

Create `bin/sleep-warn`:

```bash
#!/usr/bin/env bash
set -euo pipefail
exec notify-send --urgency=critical "Bedtime Lockdown" "${1:-Bedtime warning}"
```

- [ ] **Step 2: Mark executable**

```bash
chmod +x bin/sleep-warn
```

- [ ] **Step 3: Smoke test**

```bash
./bin/sleep-warn "test message"
```

Expected: a desktop notification titled "Bedtime Lockdown" with body "test message".

- [ ] **Step 4: Commit**

```bash
git add bin/sleep-warn
git commit -m "Add sleep-warn notification script"
```

---

## Task 3: bin/sleep-enforce

**Files:**
- Create: `bin/sleep-enforce`

Uses the library from Task 1. Decision logic is already tested at the library level; this script is the wiring + side effects (lock + suspend).

- [ ] **Step 1: Implement**

Create `bin/sleep-enforce`:

```bash
#!/usr/bin/env bash
set -euo pipefail
SLEEP_LIB="${SLEEP_LIB:-$HOME/.local/share/sleep}"
SLEEP_HOME="${SLEEP_HOME:-$HOME/.config/sleep}"
. "$SLEEP_LIB/sleep-common.sh"

mkdir -p "$SLEEP_HOME"

now=$(date +%s)
hhmm=$(date +%H%M)

if ! is_in_lockdown_window "$hhmm"; then
    exit 0
fi

if override_active "$now"; then
    exit 0
fi

echo "$(date -Iseconds) suspending" >> "$SLEEP_HOME/enforce.log"

# Best-effort lock; ignore failures (e.g. no graphical session active yet).
loginctl lock-session 2>/dev/null || true

systemctl suspend
```

- [ ] **Step 2: Mark executable**

```bash
chmod +x bin/sleep-enforce
```

- [ ] **Step 3: Dry-run test (window check, no override)**

```bash
SLEEP_HOME=$(mktemp -d) SLEEP_LIB="$PWD/lib" \
    bash -c '
        # Mock systemctl and loginctl so the script does not actually suspend.
        export PATH="$PWD/.test-mocks:$PATH"
        mkdir -p .test-mocks
        cat > .test-mocks/systemctl <<EOF
#!/bin/sh
echo "MOCK systemctl \$@"
EOF
        cat > .test-mocks/loginctl <<EOF
#!/bin/sh
echo "MOCK loginctl \$@"
EOF
        chmod +x .test-mocks/systemctl .test-mocks/loginctl
        # Force the script to think we are inside the lockdown window by
        # patching `date +%H%M` via a wrapper:
        cat > .test-mocks/date <<EOF
#!/bin/sh
if [ "\$1" = "+%H%M" ]; then echo 2200; else exec /usr/bin/date "\$@"; fi
EOF
        chmod +x .test-mocks/date
        ./bin/sleep-enforce
        rm -rf .test-mocks
    '
```

Expected: prints `MOCK loginctl lock-session` then `MOCK systemctl suspend`. Removes test mocks.

(If this test feels brittle, skip it — the library tests cover the decision logic and the install + manual smoke test in Task 7 will exercise the integrated path.)

- [ ] **Step 4: Commit**

```bash
git add bin/sleep-enforce
git commit -m "Add sleep-enforce suspend script"
```

---

## Task 4: bin/sleep-override

**Files:**
- Create: `bin/sleep-override`

Three-question prompt with validation, log append, override-until write, cooldown check.

- [ ] **Step 1: Implement**

Create `bin/sleep-override`:

```bash
#!/usr/bin/env bash
set -euo pipefail
SLEEP_LIB="${SLEEP_LIB:-$HOME/.local/share/sleep}"
SLEEP_HOME="${SLEEP_HOME:-$HOME/.config/sleep}"
. "$SLEEP_LIB/sleep-common.sh"

mkdir -p "$SLEEP_HOME"

now=$(date +%s)
remaining=$(cooldown_remaining "$now")

if (( remaining > 0 )); then
    h=$((remaining / 3600))
    m=$(( (remaining % 3600) / 60 ))
    printf 'Override already used. Cooldown remaining: %02d:%02d\n' "$h" "$m" >&2
    exit 1
fi

prompt() {
    local question=$1 answer
    while true; do
        read -r -p "$question " answer
        # reject empty / whitespace-only
        if [[ -n "${answer//[[:space:]]/}" ]]; then
            echo "$answer"
            return 0
        fi
        echo "  (answer cannot be empty)" >&2
    done
}

a1=$(prompt "What are you doing right now?")
a2=$(prompt "Why tonight specifically, and not tomorrow morning?")
a3=$(prompt "What time will you actually stop?")

ts=$(date -Iseconds)
printf '%s\t%s\t%s\t%s\n' "$ts" "$a1" "$a2" "$a3" >> "$SLEEP_HOME/overrides.log"
echo $((now + 3600)) > "$SLEEP_HOME/override-until"

end=$(date -d "@$((now + 3600))" "+%H:%M")
echo "Override granted until $end. Sleep well."
```

- [ ] **Step 2: Mark executable**

```bash
chmod +x bin/sleep-override
```

- [ ] **Step 3: Manual smoke test (cooldown empty, full path)**

```bash
SLEEP_HOME=$(mktemp -d) SLEEP_LIB="$PWD/lib" ./bin/sleep-override <<'EOF'
fixing a prod incident
the alert paged me 5 minutes ago
midnight
EOF
```

Expected: prints "Override granted until HH:MM. Sleep well." Verifies a `overrides.log` and `override-until` file in the temp `SLEEP_HOME`.

- [ ] **Step 4: Manual smoke test (cooldown blocks second override)**

```bash
TMP=$(mktemp -d)
SLEEP_HOME=$TMP SLEEP_LIB="$PWD/lib" ./bin/sleep-override <<'EOF'
first
first
midnight
EOF
SLEEP_HOME=$TMP SLEEP_LIB="$PWD/lib" ./bin/sleep-override <<'EOF'
second
second
midnight
EOF
echo "exit code: $?"
rm -rf "$TMP"
```

Expected: first call succeeds, second call prints "Override already used. Cooldown remaining: 11:59" (or similar) and exits 1.

- [ ] **Step 5: Commit**

```bash
git add bin/sleep-override
git commit -m "Add sleep-override CLI with three-question friction"
```

---

## Task 5: bin/sleep-status

**Files:**
- Create: `bin/sleep-status`

Read-only diagnostics.

- [ ] **Step 1: Implement**

Create `bin/sleep-status`:

```bash
#!/usr/bin/env bash
set -euo pipefail
SLEEP_LIB="${SLEEP_LIB:-$HOME/.local/share/sleep}"
SLEEP_HOME="${SLEEP_HOME:-$HOME/.config/sleep}"
. "$SLEEP_LIB/sleep-common.sh"

now=$(date +%s)
hhmm=$(date +%H%M)

echo "Now:           $(date)"
if is_in_lockdown_window "$hhmm"; then
    echo "Lockdown:      ACTIVE (window 21:30 - 06:00)"
else
    echo "Lockdown:      inactive"
fi

if override_active "$now"; then
    until=$(<"$SLEEP_HOME/override-until")
    echo "Override:      active until $(date -d "@$until" "+%H:%M")"
else
    echo "Override:      none"
fi

remaining=$(cooldown_remaining "$now")
if (( remaining > 0 )); then
    h=$((remaining / 3600))
    m=$(( (remaining % 3600) / 60 ))
    printf 'Cooldown:      %02d:%02d remaining\n' "$h" "$m"
else
    echo "Cooldown:      ready (no override on cooldown)"
fi

echo
echo "Last 5 enforce events:"
[[ -s "$SLEEP_HOME/enforce.log" ]] && tail -n 5 "$SLEEP_HOME/enforce.log" || echo "  (none)"

echo
echo "Last 5 overrides:"
[[ -s "$SLEEP_HOME/overrides.log" ]] && tail -n 5 "$SLEEP_HOME/overrides.log" || echo "  (none)"
```

- [ ] **Step 2: Mark executable**

```bash
chmod +x bin/sleep-status
```

- [ ] **Step 3: Smoke test**

```bash
SLEEP_HOME=$(mktemp -d) SLEEP_LIB="$PWD/lib" ./bin/sleep-status
```

Expected: prints the current time, "Lockdown: inactive" or "ACTIVE" depending on what time you run it, "Override: none", "Cooldown: ready", and "(none)" for both log sections.

- [ ] **Step 4: Commit**

```bash
git add bin/sleep-status
git commit -m "Add sleep-status diagnostic script"
```

---

## Task 6: systemd unit files

**Files:**
- Create: `systemd/sleep-warn-2100.service`
- Create: `systemd/sleep-warn-2100.timer`
- Create: `systemd/sleep-warn-2125.service`
- Create: `systemd/sleep-warn-2125.timer`
- Create: `systemd/sleep-enforce.service`
- Create: `systemd/sleep-enforce.timer`

- [ ] **Step 1: Write `systemd/sleep-warn-2100.service`**

```ini
[Unit]
Description=Bedtime warning (30 min)

[Service]
Type=oneshot
ExecStart=%h/.local/bin/sleep-warn "Bedtime in 30 minutes. Save your work."
```

- [ ] **Step 2: Write `systemd/sleep-warn-2100.timer`**

```ini
[Unit]
Description=Bedtime warning (30 min) timer

[Timer]
OnCalendar=*-*-* 21:00:00
Persistent=false
Unit=sleep-warn-2100.service

[Install]
WantedBy=timers.target
```

- [ ] **Step 3: Write `systemd/sleep-warn-2125.service`**

```ini
[Unit]
Description=Bedtime warning (5 min)

[Service]
Type=oneshot
ExecStart=%h/.local/bin/sleep-warn "Bedtime in 5 minutes. Wrap up."
```

- [ ] **Step 4: Write `systemd/sleep-warn-2125.timer`**

```ini
[Unit]
Description=Bedtime warning (5 min) timer

[Timer]
OnCalendar=*-*-* 21:25:00
Persistent=false
Unit=sleep-warn-2125.service

[Install]
WantedBy=timers.target
```

- [ ] **Step 5: Write `systemd/sleep-enforce.service`**

```ini
[Unit]
Description=Bedtime enforce (lock + suspend if in window)

[Service]
Type=oneshot
ExecStart=%h/.local/bin/sleep-enforce
```

- [ ] **Step 6: Write `systemd/sleep-enforce.timer`**

```ini
[Unit]
Description=Bedtime enforce timer (every 3 minutes during lockdown window)

[Timer]
# Fire every 3 minutes, all day. The script is a no-op outside the
# 21:30..06:00 lockdown window, so the simpler always-on schedule is
# fine and easier to read than a windowed OnCalendar expression.
OnCalendar=*-*-* *:*/3
Persistent=false
Unit=sleep-enforce.service

[Install]
WantedBy=timers.target
```

- [ ] **Step 7: Verify the unit files**

```bash
systemd-analyze --user verify systemd/*.service systemd/*.timer
```

Expected: no output. Any output is an error and must be fixed before continuing. Note that `%h` substitution will warn about being unresolved during verify-only mode — that's expected, it resolves correctly when the units are installed under `~/.config/systemd/user/`. If `systemd-analyze` complains specifically about `%h`, treat it as a non-issue.

- [ ] **Step 8: Commit**

```bash
git add systemd/
git commit -m "Add systemd user units for warn + enforce timers"
```

---

## Task 7: install.sh / uninstall.sh

**Files:**
- Create: `install.sh`
- Create: `uninstall.sh`

- [ ] **Step 1: Write `install.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.local/bin"
LIB_DIR="$HOME/.local/share/sleep"
UNIT_DIR="$HOME/.config/systemd/user"
STATE_DIR="$HOME/.config/sleep"

mkdir -p "$BIN_DIR" "$LIB_DIR" "$UNIT_DIR" "$STATE_DIR"

install -m 755 "$REPO_ROOT/bin/sleep-warn"      "$BIN_DIR/sleep-warn"
install -m 755 "$REPO_ROOT/bin/sleep-enforce"   "$BIN_DIR/sleep-enforce"
install -m 755 "$REPO_ROOT/bin/sleep-override"  "$BIN_DIR/sleep-override"
install -m 755 "$REPO_ROOT/bin/sleep-status"    "$BIN_DIR/sleep-status"

install -m 644 "$REPO_ROOT/lib/sleep-common.sh" "$LIB_DIR/sleep-common.sh"

install -m 644 "$REPO_ROOT/systemd/sleep-warn-2100.service"  "$UNIT_DIR/sleep-warn-2100.service"
install -m 644 "$REPO_ROOT/systemd/sleep-warn-2100.timer"    "$UNIT_DIR/sleep-warn-2100.timer"
install -m 644 "$REPO_ROOT/systemd/sleep-warn-2125.service"  "$UNIT_DIR/sleep-warn-2125.service"
install -m 644 "$REPO_ROOT/systemd/sleep-warn-2125.timer"    "$UNIT_DIR/sleep-warn-2125.timer"
install -m 644 "$REPO_ROOT/systemd/sleep-enforce.service"    "$UNIT_DIR/sleep-enforce.service"
install -m 644 "$REPO_ROOT/systemd/sleep-enforce.timer"      "$UNIT_DIR/sleep-enforce.timer"

systemctl --user daemon-reload
systemctl --user enable --now \
    sleep-warn-2100.timer \
    sleep-warn-2125.timer \
    sleep-enforce.timer

echo
echo "Installed. Active timers:"
systemctl --user list-timers --all | grep -E 'sleep-' || true
echo
echo "Run sleep-status to inspect state any time."
```

- [ ] **Step 2: Write `uninstall.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

BIN_DIR="$HOME/.local/bin"
LIB_DIR="$HOME/.local/share/sleep"
UNIT_DIR="$HOME/.config/systemd/user"

systemctl --user disable --now \
    sleep-warn-2100.timer \
    sleep-warn-2125.timer \
    sleep-enforce.timer 2>/dev/null || true

rm -f \
    "$UNIT_DIR/sleep-warn-2100.service" \
    "$UNIT_DIR/sleep-warn-2100.timer" \
    "$UNIT_DIR/sleep-warn-2125.service" \
    "$UNIT_DIR/sleep-warn-2125.timer" \
    "$UNIT_DIR/sleep-enforce.service" \
    "$UNIT_DIR/sleep-enforce.timer"

rm -f \
    "$BIN_DIR/sleep-warn" \
    "$BIN_DIR/sleep-enforce" \
    "$BIN_DIR/sleep-override" \
    "$BIN_DIR/sleep-status" \
    "$LIB_DIR/sleep-common.sh"

rmdir "$LIB_DIR" 2>/dev/null || true

systemctl --user daemon-reload

echo "Uninstalled. State directory ~/.config/sleep was left intact (logs preserved)."
echo "Remove manually with: rm -rf ~/.config/sleep"
```

- [ ] **Step 3: Mark executable**

```bash
chmod +x install.sh uninstall.sh
```

- [ ] **Step 4: Commit**

```bash
git add install.sh uninstall.sh
git commit -m "Add install/uninstall scripts"
```

---

## Task 8: README

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write README**

Create `README.md`:

````markdown
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

Requires: `bats` (build-time, for running tests), and a systemd-based Linux desktop with `notify-send` and a graphical session manager that responds to `loginctl lock-session`. Tested on Manjaro + GNOME on Wayland.

## Test

```bash
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
````

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "Add README"
```

---

## Task 9: End-to-end smoke test

**Files:** none

This is a manual verification task on the actual user machine. Each step is a single observation.

- [ ] **Step 1: Run install**

```bash
./install.sh
```

Expected: exits 0, prints three active timers ending in `.timer` for sleep-warn-2100, sleep-warn-2125, sleep-enforce.

- [ ] **Step 2: Confirm timers are scheduled**

```bash
systemctl --user list-timers | grep sleep-
```

Expected: three rows. Next-fire times for `sleep-warn-2100` and `sleep-warn-2125` are tonight at 21:00 and 21:25; next-fire for `sleep-enforce` is the next 3-minute mark within the 21..05 hour window.

- [ ] **Step 3: Manually trigger the warning notification**

```bash
systemctl --user start sleep-warn-2100.service
```

Expected: a desktop notification appears titled "Bedtime Lockdown" with body "Bedtime in 30 minutes. Save your work."

- [ ] **Step 4: Inspect status**

```bash
sleep-status
```

Expected: lockdown ACTIVE if running between 21:30 and 06:00, otherwise inactive; override none; cooldown ready.

- [ ] **Step 5: Verify suspend behavior dry-run**

Without actually suspending, confirm `sleep-enforce` exits cleanly outside the window:

```bash
sleep-enforce; echo "exit=$?"
```

If run during the day (outside 21:30 – 06:00): expected `exit=0` immediately, no suspend.

If run during the lockdown window: it WILL suspend. Don't run it then unless that's what you want to test. To verify the in-window path safely, temporarily wrap it via the test mock approach from Task 3 step 3.

- [ ] **Step 6: End-to-end override verification**

```bash
sleep-override
```

Answer the three questions truthfully (e.g., "smoke testing the install", "verifying override path works", "in 5 minutes"). Expected: prints "Override granted until HH:MM. Sleep well." Then:

```bash
sleep-status
```

Expected: shows "Override: active until HH:MM" and "Cooldown: 11:59 remaining" (or similar).

Try a second override:

```bash
sleep-override
```

Expected: prints "Override already used. Cooldown remaining: 11:59" and exits 1.

- [ ] **Step 7: Tear down test override**

```bash
rm ~/.config/sleep/override-until ~/.config/sleep/overrides.log
```

This clears the test override so the system enforces normally tonight.

- [ ] **Step 8: Commit (no code change, but mark plan as run)**

No commit needed — Task 9 is verification. If anything failed, file fixes as new tasks and commit them.

---

## Done criteria

- All bats tests pass.
- All systemd unit files pass `systemd-analyze --user verify` (modulo the expected `%h` warning).
- `install.sh` runs cleanly and lists three active timers afterward.
- `sleep-warn-2100.service` produces a visible notification when manually started.
- `sleep-override` prompts for three answers, writes the log, and refuses a second override within 12 hours.
- `sleep-status` prints sane output.
