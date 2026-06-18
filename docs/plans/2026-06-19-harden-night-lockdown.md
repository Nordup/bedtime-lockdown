# Harden Night Lockdown Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the override at night (the bedtime lock becomes non-negotiable) and tighten the re-lock cadence from 5 minutes to 3 minutes in every window, on Linux and Windows.

**Architecture:** A single config setting, `OVERRIDE_ENABLED_WINDOWS = ("lunch", "dinner")`, is the one source of truth for which windows permit an override. The pure-logic layer exposes a predicate `override_enabled(window)`; the reprieve check short-circuits to `False` for non-enabled windows (so the lock loop ignores any bedtime reprieve file), and the override CLI refuses at night before asking any questions. The cadence change is two interval values in the Linux systemd timer plus one delay value in the Windows Task Scheduler trigger — there is no central constant because systemd cannot read one.

**Tech Stack:** Python 3.9+ (stdlib only on Linux; ctypes + optional winrt on Windows), systemd user timers (Linux), Task Scheduler (Windows), pytest.

## Global Constraints

- **Python 3.9 or newer.** No third-party Python dependencies on Linux; ctypes-only (plus optional `winrt`) on Windows. Do not add dependencies.
- **Pure logic stays in `common.py`** (no platform calls, no side effects); platform side effects stay in `platforms/`. Tests are pure-logic only — no platform side effects in CI.
- **Linux + Windows kept at 1:1 behavioral parity.**
- **Agent mode is intentionally preserved in every window, including bedtime.** Do not disable or alter it.
- **Window start/end times and the 15-/5-minute pre-window warnings are unchanged.** Only the re-lock cadence and the night override change.
- **Fail-safe toward locking:** any ambiguity in reprieve state resolves to "locked."

## Setup (before Task 1)

Create a working branch off `main`:

```bash
git checkout -b harden-night-lockdown
```

All task commits land on this branch. Merge to `main` once the full suite is green.

---

### Task 1: Override policy in pure logic

Adds the policy setting and the predicate, and makes the reprieve check honor it. This is the testable core; the lock loop already calls `override_active(now, window)`, so once that returns `False` for bedtime, the night lock automatically stops honoring reprieves — no change to the lock loop itself.

**Files:**
- Modify: `sleep_lockdown/config.py` (add `OVERRIDE_ENABLED_WINDOWS`)
- Modify: `sleep_lockdown/common.py` (import the setting; add `override_enabled`; short-circuit `override_active`)
- Test: `tests/test_common.py`

**Interfaces:**
- Produces: `config.OVERRIDE_ENABLED_WINDOWS: tuple[str, ...] = ("lunch", "dinner")`
- Produces: `common.override_enabled(window: str) -> bool` — `True` iff `window in OVERRIDE_ENABLED_WINDOWS`
- Produces: `common.override_active(now_epoch: Optional[int] = None, window: str = "bedtime") -> bool` — unchanged signature; now returns `False` for any window where `override_enabled(window)` is `False`, before reading any file.

- [ ] **Step 1: Write the failing tests**

In `tests/test_common.py`, add two new tests in the `# ---- override_active` section:

```python
def test_override_enabled():
    assert common.override_enabled("lunch")
    assert common.override_enabled("dinner")
    assert not common.override_enabled("bedtime")


def test_override_active_bedtime_disabled_even_with_fresh_file(state_home):
    # Night is non-negotiable: a valid, future-dated reprieve file is ignored.
    (state_home / "override-until").write_text("1700000060")
    assert not common.override_active(1700000000, "bedtime")
```

And repoint the existing "future until-file activates an override" test to a day window (bedtime can no longer activate). Replace:

```python
def test_override_active_until_greater_than_now(state_home):
    (state_home / "override-until").write_text("1700000060")
    assert common.override_active(1700000000, "bedtime")
```

with:

```python
def test_override_active_until_greater_than_now(state_home):
    # Repointed to lunch: bedtime no longer honors any reprieve, so the
    # "future until-file activates an override" path is tested on a window
    # that still permits overrides.
    (state_home / "override-until-lunch").write_text("1700000060")
    assert common.override_active(1700000000, "lunch")
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pytest tests/test_common.py::test_override_enabled tests/test_common.py::test_override_active_bedtime_disabled_even_with_fresh_file -v`
Expected: both FAIL — `test_override_enabled` with `AttributeError: module 'sleep_lockdown.common' has no attribute 'override_enabled'`; `test_override_active_bedtime_disabled_even_with_fresh_file` with `assert not True` (today bedtime honors the file).

- [ ] **Step 3: Add the config setting**

In `sleep_lockdown/config.py`, immediately after the `COOLDOWN_SEC` line, add:

```python

# Windows that permit an override. Bedtime is deliberately excluded — the
# night lock is non-negotiable. Single source of truth for the override
# policy; consumed by common.override_enabled().
OVERRIDE_ENABLED_WINDOWS = ("lunch", "dinner")
```

- [ ] **Step 4: Implement the predicate and short-circuit**

In `sleep_lockdown/common.py`, add `OVERRIDE_ENABLED_WINDOWS` to the `from .config import (...)` block (between `LUNCH_START_HHMM,` and `state_dir,`):

```python
    LUNCH_START_HHMM,
    OVERRIDE_ENABLED_WINDOWS,
    state_dir,
```

Then add the predicate directly above `override_active`, and short-circuit `override_active`. Replace:

```python
def override_active(now_epoch: Optional[int] = None, window: str = "bedtime") -> bool:
    """Per-window override active iff override-until file exists and contains
    a numeric epoch strictly greater than now."""
    if now_epoch is None:
        now_epoch = int(time.time())
    until = read_until_epoch(override_until_path(window))
    return until is not None and until > now_epoch
```

with:

```python
def override_enabled(window: str) -> bool:
    """Whether a window permits an override at all. Bedtime does not — the
    night lock is non-negotiable. Source of truth: OVERRIDE_ENABLED_WINDOWS."""
    return window in OVERRIDE_ENABLED_WINDOWS


def override_active(now_epoch: Optional[int] = None, window: str = "bedtime") -> bool:
    """Per-window override active iff the window permits overrides AND its
    override-until file exists with a numeric epoch strictly greater than now.

    Windows without overrides (bedtime) always return False, ignoring any
    stale or hand-written until-file — fail-safe toward locking."""
    if not override_enabled(window):
        return False
    if now_epoch is None:
        now_epoch = int(time.time())
    until = read_until_epoch(override_until_path(window))
    return until is not None and until > now_epoch
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `pytest tests/ -q`
Expected: PASS — all tests (the two new ones, the repointed one, and the existing 60) green.

- [ ] **Step 6: Commit**

```bash
git add sleep_lockdown/config.py sleep_lockdown/common.py tests/test_common.py
git commit -m "Disable override at night via OVERRIDE_ENABLED_WINDOWS policy"
```

---

### Task 2: Override CLI refusal + dead-code cleanup

Makes the override CLI refuse at night, and removes the now-dead bedtime grant path and the unused 1-hour-reprieve constant. Removing the constant from the config and its only user (the CLI) in the same task avoids a broken intermediate import.

**Files:**
- Modify: `sleep_lockdown/override.py`
- Modify: `sleep_lockdown/config.py` (remove `OVERRIDE_DURATION_SEC`)

**Interfaces:**
- Consumes: `common.override_enabled(window)` from Task 1.

- [ ] **Step 1: Add the night refusal in the CLI**

In `sleep_lockdown/override.py`, in `main()`, immediately after the `if win == "none":` block (before `state_dir().mkdir(...)`), add:

```python
    if not common.override_enabled(win):
        print(
            "Override is disabled during the night. The bedtime lock is "
            "non-negotiable — there is no reprieve to grant. Go to sleep.",
            file=sys.stderr,
        )
        return 1
```

- [ ] **Step 2: Drop the dead bedtime question**

In `_run`, replace:

```python
    questions = {
        "bedtime": "Why tonight specifically, and not tomorrow morning?",
        "lunch":   "Why is this lunch break the wrong time to step away?",
        "dinner":  "Why is this exercise + dinner break the wrong time to step away?",
    }
    q2 = questions[win]
```

with:

```python
    questions = {
        "lunch":   "Why is this lunch break the wrong time to step away?",
        "dinner":  "Why is this exercise + dinner break the wrong time to step away?",
    }
    q2 = questions[win]
```

- [ ] **Step 3: Simplify the grant logic (remove the bedtime branch)**

Replace:

```python
    # Bedtime grants a fixed 1h reprieve; breaks grant until end of
    # the current window (the lock is gentle enough that end-of-window
    # is the right unit).
    if win == "bedtime":
        expires = now + OVERRIDE_DURATION_SEC
    else:
        expires = common.window_end_epoch(win, now)
```

with:

```python
    # Only override-enabled windows (lunch, dinner) reach here — bedtime is
    # refused upstream in main(). Both grant a reprieve until end-of-window.
    # NOTE: if bedtime were ever re-added to OVERRIDE_ENABLED_WINDOWS it would
    # need a *bounded* duration here — window_end_epoch("bedtime") resolves to
    # 06:00, which would wrongly grant a reprieve until morning.
    expires = common.window_end_epoch(win, now)
```

- [ ] **Step 4: Simplify the success message (bedtime branch now unreachable)**

Replace:

```python
    expires_hm = datetime.fromtimestamp(expires).strftime("%H:%M")
    if win == "bedtime":
        print(f"Override granted until {expires_hm}. Sleep well.")
    else:
        print(f"Override granted for {win} until {expires_hm}.")
    return 0
```

with:

```python
    expires_hm = datetime.fromtimestamp(expires).strftime("%H:%M")
    print(f"Override granted for {win} until {expires_hm}.")
    return 0
```

- [ ] **Step 5: Drop the unused import and the config constant**

In `sleep_lockdown/override.py`, change the import line:

```python
from .config import COOLDOWN_SEC, OVERRIDE_DURATION_SEC, state_dir
```

to:

```python
from .config import COOLDOWN_SEC, state_dir
```

In `sleep_lockdown/config.py`, delete the line:

```python
OVERRIDE_DURATION_SEC = 3600         # bedtime override: 1 hour reprieve
```

- [ ] **Step 6: Verify the package still imports and the suite is green**

Run: `python -c "import sleep_lockdown.override, sleep_lockdown.config, sleep_lockdown.enforce"`
Expected: no output, exit 0 (no `ImportError` for the removed constant).

Run: `pytest tests/ -q`
Expected: PASS — all tests green.

- [ ] **Step 7: Manual check — bedtime refuses**

Force the clock into the bedtime window and run the CLI:

```bash
SLEEP_HOME=/tmp/sleep-verify python -c "
import sleep_lockdown.common as c
c.current_hhmm = lambda: 2300
import sleep_lockdown.override as o
raise SystemExit(o.main())
"
```
Expected: prints "Override is disabled during the night..." and exits 1.

- [ ] **Step 8: Manual check — lunch still grants**

Force the clock into the lunch window and pipe the three answers:

```bash
SLEEP_HOME=/tmp/sleep-verify python -c "
import sleep_lockdown.common as c
c.current_hhmm = lambda: 1145
import sleep_lockdown.override as o
raise SystemExit(o.main())
" <<< $'working\nreason\n13:00'
```
Expected: prints "Override granted for lunch until 12:15." and exits 0. Then clean up: `rm -rf /tmp/sleep-verify`.

- [ ] **Step 9: Commit**

```bash
git add sleep_lockdown/override.py sleep_lockdown/config.py
git commit -m "Refuse override at night in the CLI; drop dead 1h-reprieve path"
```

---

### Task 3: Status screen — show night override as disabled

For the bedtime block, replace the override/cooldown/overrides-today lines with one honest line.

**Files:**
- Modify: `sleep_lockdown/status.py`

**Interfaces:**
- Consumes: `common.override_enabled(window)` from Task 1.

- [ ] **Step 1: Add the disabled-window branch**

In `sleep_lockdown/status.py`, in `_print_window_block`, immediately after the `print(f"{label:<8} window {window_label}   {active}")` line, add:

```python
    if not common.override_enabled(win):
        print("         override: disabled (no reprieve at night)")
        return
```

This returns before the override-until / cooldown / overrides-today lines, so the bedtime block shows only its active-state line plus the disabled line. Lunch and dinner are unchanged.

- [ ] **Step 2: Verify import**

Run: `python -c "import sleep_lockdown.status"`
Expected: no output, exit 0.

- [ ] **Step 3: Verify the rendered output**

Run: `SLEEP_HOME=/tmp/sleep-verify python -m sleep_lockdown.status; rm -rf /tmp/sleep-verify`
Expected: under `Bedtime  window 21:00 - 06:00`, the next line reads `override: disabled (no reprieve at night)` and there are no `cooldown:` / `overrides today:` lines for bedtime. The Lunch and Dinner blocks still show `override: none`, `cooldown: ready`, `overrides today: 0`.

- [ ] **Step 4: Commit**

```bash
git add sleep_lockdown/status.py
git commit -m "status: show bedtime override as disabled"
```

---

### Task 4: Re-lock cadence 5 min → 3 min (Linux timer + Windows trigger)

Changes the cadence on both platforms and documents where it lives. No unit tests cover scheduler files; verification is by inspection, and the change takes effect only after a reinstall.

**Files:**
- Modify: `systemd/sleep-enforce.timer`
- Modify: `systemd/sleep-enforce-bedtime.timer` (comment only)
- Modify: `install.py` (Windows trigger delay + comment)
- Modify: `sleep_lockdown/config.py` (document cadence location in the CONFIG NOTE)

- [ ] **Step 1: Change the Linux monotonic timer to 3 minutes**

Overwrite `systemd/sleep-enforce.timer` with:

```ini
[Unit]
Description=Bedtime enforce timer (every 3 min; the service is window-gated and a no-op outside 21:00-06:00)

[Timer]
# Monotonic timer pair, not OnCalendar. The wake-loop semantics we want
# are "3 minutes after the user wakes the machine" — measured from the
# moment of resume, not from an absolute clock mark. Because the script
# blocks on `systemctl suspend` until the kernel resumes, the service
# stays active for the entire suspend duration and only deactivates on
# resume. OnUnitInactiveSec=3min therefore schedules the next fire for
# exactly resume_time + 3min.
#
# OnActiveSec=3min gives the first fire 3 min after the timer is
# enabled (initial bootstrap). After that, OnUnitInactiveSec drives the
# cadence: 3 min between every service end and the next fire.
OnActiveSec=3min
OnUnitInactiveSec=3min
Unit=sleep-enforce.service

[Install]
WantedBy=timers.target
```

- [ ] **Step 2: Update the bedtime calendar-kickoff comment**

In `systemd/sleep-enforce-bedtime.timer`, change `5 minutes late. This timer plugs that gap.` to `3 minutes late. This timer plugs that gap.`, and change `the monotonic timer fires within 5 min of resume anyway, and a` to `the monotonic timer fires within 3 min of resume anyway, and a`.

- [ ] **Step 3: Change the Windows trigger delay to 3 minutes**

In `install.py`, change `<Delay>PT5M</Delay>` to `<Delay>PT3M</Delay>`, and change the comment `# Wake-loop on resume — fires sleep-enforce 5 min after every` to `# Wake-loop on resume — fires sleep-enforce 3 min after every`.

- [ ] **Step 4: Document the cadence location**

In `sleep_lockdown/config.py`, inside the module docstring, immediately before the closing `"""`, add:

```text

RE-LOCK CADENCE: the every-3-minutes re-lock interval is likewise not
readable from here. On Linux it lives in systemd/sleep-enforce.timer
(OnActiveSec / OnUnitInactiveSec); on Windows it's the Task Scheduler
trigger <Delay> that install.py writes. Change both to change the cadence.
```

- [ ] **Step 5: Verify the values changed**

Run: `grep -n "3min" systemd/sleep-enforce.timer && grep -n "PT3M" install.py && ! grep -rn "5min\|PT5M" systemd/sleep-enforce.timer install.py`
Expected: shows `OnActiveSec=3min` and `OnUnitInactiveSec=3min`, shows `<Delay>PT3M</Delay>`, and the final negated grep finds no remaining `5min`/`PT5M` (so the command's overall exit is 0).

Run: `python -c "import sleep_lockdown.config"`
Expected: no output, exit 0 (docstring edit didn't break the module).

Note: the new cadence only takes effect after re-running the installer (`./install.sh` on Linux then `systemctl --user daemon-reload`, or `install.ps1` on Windows). Applying it is a deploy step, not part of this commit.

- [ ] **Step 6: Commit**

```bash
git add systemd/sleep-enforce.timer systemd/sleep-enforce-bedtime.timer install.py sleep_lockdown/config.py
git commit -m "Tighten re-lock cadence from 5 to 3 minutes (Linux + Windows)"
```

---

### Task 5: README — update for night-no-override and 3-minute cadence

Documentation only; verified by inspection. Do **not** touch the archived docs under `docs/specs/` or `docs/plans/` from the bash era — they are frozen historical records.

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Intro sentence — cadence**

Change `and keeps re-locking it every five minutes until each window ends` to `and keeps re-locking it every three minutes until each window ends`.

- [ ] **Step 2: Schedule table — cadence (3 rows)**

Change `11:30am – 12:15pm | Screen re-locks every 5 min.` to `... every 3 min.`; change `4:30pm – 6:30pm | Screen re-locks every 5 min.` to `... every 3 min.`; change `9:00pm – 6:00am | Screen re-locks every 5 min.` to `... every 3 min.`

- [ ] **Step 3: Override summary paragraph — night has no override**

Replace the paragraph that begins `If you have a real emergency inside any window, run \`sleep-override\`` (the one ending `each window's quota is independent.`) with:

```text
If you have a real emergency inside a **daytime** window (lunch or dinner), run `sleep-override` from any terminal. It detects which window is active, asks three deliberately uncomfortable questions, logs your answers, and grants a reprieve until the end of the current break. One override per window per 12 hours — each window's quota is independent. **Bedtime has no override**: the night lock is non-negotiable, and there is nothing to grant.
```

- [ ] **Step 4: Command list bullet**

Change `- \`sleep-override\` — interactive 3-question CLI. Detects the active window automatically.` to `- \`sleep-override\` — interactive 3-question CLI for the daytime windows (lunch, dinner). Detects the active window automatically. Refuses during bedtime — the night lock has no override.`

- [ ] **Step 5: "How it works" — the sleep-override paragraph**

In the paragraph beginning `\`sleep-override\` is intentionally slow.`:
- Change `what are you doing, why is *this* break the wrong time to step away (or, for bedtime, why tonight and not tomorrow morning), what time will you actually stop.` to `what are you doing, why is *this* break the wrong time to step away, what time will you actually stop.`
- Replace `Bedtime grants \`now+1h\` and writes \`override-until\`; breaks grant until end of the current window and write \`override-until-lunch\` or \`override-until-dinner\`.` with `Bedtime is refused before any questions — \`OVERRIDE_ENABLED_WINDOWS\` excludes it, so enforce honors no bedtime reprieve. Lunch and dinner grant until the end of the current window and write \`override-until-lunch\` or \`override-until-dinner\`.`

- [ ] **Step 6: Customize section — drop the reprieve constant, note the cadence**

In the config snippet, delete the line `OVERRIDE_DURATION_SEC = 3600         # bedtime override: 1 hour reprieve` and add, after the `COOLDOWN_SEC` line, `OVERRIDE_ENABLED_WINDOWS = ("lunch", "dinner")  # bedtime has no override`. Then, after the snippet (before "Then re-run..."), add a sentence:

```text
The re-lock cadence (every 3 minutes) is not in `config.py` — on Linux it lives in the systemd enforce timer, and on Windows in the Task Scheduler trigger that `install.py` writes. Change it there, then reinstall.
```

- [ ] **Step 7: Verify no stale cadence/override copy remains**

Run: `grep -n "every 5 min\|every five minutes\|Bedtime grants one hour\|OVERRIDE_DURATION_SEC" README.md`
Expected: no matches (exit 1).

- [ ] **Step 8: Commit**

```bash
git add README.md
git commit -m "docs: night has no override; re-lock every 3 minutes"
```

---

## Done criteria

- `pytest tests/ -q` is green, including the new `override_enabled` and bedtime-disabled coverage.
- The override CLI refuses in the bedtime window and still grants in lunch/dinner.
- `sleep-status` shows the bedtime override as disabled.
- The Linux timer and Windows trigger both specify a 3-minute cadence; no `5min`/`PT5M` remains in them.
- README reflects both changes; archived docs untouched.
- Merge `harden-night-lockdown` to `main`.
