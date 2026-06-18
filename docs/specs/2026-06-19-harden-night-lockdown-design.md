# Harden Night Lockdown — Design

**Date:** 2026-06-19
**Status:** Approved, not yet implemented
**Target machine:** Manjaro Linux + GNOME (primary); Windows 10/11 kept at 1:1 parity

## Problem

The bedtime window (21:00–06:00) currently locks the screen and re-locks every
5 minutes, but it can be bought off with the 3-question override CLI, which
grants a 1-hour reprieve. For the user this defeats the purpose: the addiction-
brain answers three questions and keeps working. The night needs to stop being
negotiable.

The daytime windows (lunch, dinner) are different — those breaks have legitimate
"this is genuinely the wrong moment to step away" cases, so their override
should stay.

## Goal

1. **Remove the override at night.** During the bedtime window the override CLI
   refuses, and the lock loop honors no bedtime reprieve. The screen keeps
   re-locking until 06:00. There is no reprieve to grant.
2. **Tighten the re-lock cadence from 5 minutes to 3 minutes** in every window
   (bedtime, lunch, dinner), on both Linux and Windows.

## Non-goals

- **Powering the machine off or suspending at night.** Considered and rejected
  by the user; the screen-lock mechanism is kept. This change does not make the
  machine refuse to be *on* — it makes the night lock un-buyable.
- **Removing agent mode at night.** Deliberately kept. Agent mode (lock + blank
  display + hold idle-suspend until window end) remains available in all three
  windows, including bedtime, as the one intentional night escape for overnight
  background jobs. The user accepted that this leaves a known hole: one agent-
  mode invocation at 21:00 suppresses the re-lock loop until 06:00.
- **Tamper-proofness.** Unchanged stance: the user is root and can stop the
  scheduler. The system relies on compliance being the lazy path; removing the
  override removes the *easy* bypass while leaving the deliberate one (stop the
  timer) as a conscious act.
- **Changing window times or warning lead times.** The 15-/5-minute pre-window
  warnings are untouched. Only the re-lock cadence changes.

## Behavior summary

| Aspect | Today | After |
|---|---|---|
| Night override (bedtime reprieve) | 3 questions → 1 hour | **Removed** — CLI refuses, loop ignores any reprieve file |
| Day override (lunch, dinner) | 3 questions → until end of break | Unchanged |
| Agent mode (all windows) | lock + blank + stay awake until window end | Unchanged |
| Re-lock cadence (all windows) | every 5 min | **every 3 min** |
| Pre-window warnings (15/5 min) | — | Unchanged |

## Design

### 1. Config-driven override policy (Approach A, approved)

A single setting in the config declares which windows allow an override:

```python
OVERRIDE_ENABLED_WINDOWS = ("lunch", "dinner")   # bedtime has no override
```

This is the one source of truth for the policy. Two consumers read it through a
small predicate in the pure-logic layer (`override_enabled(window) -> bool`,
returning `window in OVERRIDE_ENABLED_WINDOWS`):

- **The reprieve check** (`override_active`) short-circuits to `False` for any
  window not in the set, *before* reading any file. This means the lock loop
  ignores a bedtime reprieve file even if a stale one exists from before this
  change or is written by hand — fail-safe toward locking.
- **The override CLI** checks the predicate right after it detects the active
  window. If the window is not override-enabled (i.e. bedtime), it prints a
  clear refusal and exits non-zero, before the cooldown check or any questions.

Rejected alternatives: scattering `if window == "bedtime"` checks across the CLI
and the lock loop (policy in two places, against the codebase's DRY grain);
ripping bedtime out of the override machinery entirely (breaks the "all three
windows share one code path" symmetry, harder to reverse).

### 2. Re-lock cadence: 5 min → 3 min

There is intentionally **no central constant** for the cadence, because the
Linux side can't read one:

- **Linux:** the monotonic re-lock timer carries the cadence as two interval
  values (first-fire delay and inter-fire gap). Both change from 5 min to 3 min.
  Its explanatory comments and the bedtime calendar-kickoff timer's comment
  (currently "up to 5 minutes late") are updated to read "up to 3 minutes late."
- **Windows:** the Task Scheduler re-lock trigger carries the cadence as a delay
  value written by the installer. It changes from `PT5M` to `PT3M`, with its
  comment updated.
- The config file's existing "CONFIG NOTE" gains a line documenting where the
  cadence lives, mirroring how the window start-times are already documented
  there. A config constant is explicitly avoided: systemd can't read it, so it
  would be a second source of truth that's silently ignored on Linux.

### 3. Cleanup (dead code after night refuses early)

- The fixed bedtime-reprieve duration constant becomes unused (only lunch/dinner
  grant reprieves now, and they grant until end-of-window, not a fixed
  duration). Remove it from the config and the override CLI's import.
- The override CLI's grant logic loses its bedtime branch; it now always grants
  until end-of-window (the only reachable windows are lunch and dinner). A
  comment notes that bedtime is excluded upstream and would need a *bounded*
  duration restored if it were ever re-added to the policy — otherwise it would
  wrongly grant a reprieve until 06:00.
- The bedtime entry in the CLI's per-window question map is removed (unreachable).
- `COOLDOWN_SEC` stays — lunch and dinner still use the one-per-12-hours rule.

### 4. Status screen

For the bedtime block, the status output replaces the override/cooldown/
overrides-today lines with a single honest line:

```
override: disabled (no reprieve at night)
```

Lunch and dinner blocks are unchanged.

### 5. Tests

- Repoint the override-active test that asserts a reprieve activates to a day
  window (lunch), so the until-comparison logic stays covered.
- Add coverage that bedtime's reprieve check returns `False` even with a fresh,
  future-dated reprieve file present (the disabled-at-night guarantee).
- Add coverage for the new policy predicate: enabled for lunch/dinner, disabled
  for bedtime.
- The existing per-window isolation test (bedtime inactive, lunch active) still
  passes, now for the stronger reason. All other pure-logic tests are unaffected.

### 6. Docs (README)

- Schedule table: "re-locks every 5 min" → "every 3 min" (all three rows) and
  the intro sentence's "every five minutes" → "every three minutes."
- Override section: bedtime no longer has an override; only lunch and dinner do.
  The one-per-12-hours rule now describes the day windows only.
- "How it works" enforce description: note bedtime has no override path.
- Customize section: remove the bedtime-reprieve-duration line; note the cadence
  lives in the Linux timer and the Windows trigger.

## Cross-platform

The override-policy change is in the shared pure-logic layer, so it lands on
both OSes from one edit. The cadence change is made in both the Linux timer and
the Windows trigger to preserve the project's stated 1:1 parity.

## What this does NOT achieve (honest framing)

The machine stays powered on at night. This change removes the *easy* night
bypass (the override) and tightens the re-lock to every 3 minutes, so the lock
screen returns quickly and can't be bought off. The remaining ways past at night
are unchanged and deliberate: agent mode (the user's chosen escape) and stopping
the scheduler (a conscious act, the basis of the existing anti-cheat philosophy).
