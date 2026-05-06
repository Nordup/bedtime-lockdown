# Bedtime Lockdown — Design

**Date:** 2026-05-07
**Status:** Draft, pending user approval
**Target machine:** Manjaro Linux, GNOME on Wayland (single-user desktop)

## Problem

Late-night work compulsion. The 9pm "get ready for sleep" reminder gets dismissed with the rationalization "just 5–10 more minutes," then the user works until 5am. Reminders alone don't work because the bottleneck is willpower, not awareness. Need an enforcement mechanism that the addiction-brain can't reflexively bargain with.

No off-the-shelf Linux tool does this. Cold Turkey's "Frozen Turkey" is the conceptual match but it's Windows/Mac only. Linux blockers (DigitalZen, SelfControl port, Chomper, etc.) target websites/apps, not OS-level scheduled lockdown.

## Goal

A small, self-contained Linux service that:

- Hard-suspends the machine at 9:30pm every night and keeps it suspended (via wake-loop) until 6:00am.
- Provides a deliberately high-friction override path so that genuine emergencies are possible, but reflex "5 more minutes" bargaining is not.
- Is simple enough to fully understand and modify (no daemon, no closed source, no subscription).

## Non-goals

- Network blocking, app blocking, website blocking. Out of scope — the goal is to stop computer use entirely, not to filter it.
- Tamper-proofness against the user's root access. The user *is* root and could disable any unit. The system relies on the override being a faster, lower-shame escape than disabling, so the lazy path leads to bed.
- Cross-platform support. Linux + systemd only.
- Per-day customization (different schedules on different days). Same schedule every night.

## Schedule

Every night, Mon–Sun:

| Time      | Event                                                   |
|-----------|---------------------------------------------------------|
| 9:00pm    | Desktop notification: "Bedtime in 30 minutes."          |
| 9:25pm    | Desktop notification: "Bedtime in 5 minutes."           |
| 9:30pm    | Lock screen + `systemctl suspend`.                      |
| 9:30pm – 6:00am | If machine wakes, suspend again ~3 minutes later. |
| 6:00am    | Lockdown window ends. Machine stays awake.              |

The 6:00am end is enforced by the suspend script: when invoked outside the 9:30pm–6:00am window, it exits without suspending.

## Override mechanism

A CLI tool, `sleep-override`, runnable from any terminal. It asks three questions, one at a time, and refuses to proceed if any answer is empty or whitespace:

1. What are you doing right now?
2. Why tonight specifically, and not tomorrow morning?
3. What time will you actually stop?

On success it:

- Appends a record to `~/.config/sleep/overrides.log` with timestamp + the three answers.
- Writes the epoch timestamp `now + 3600` to `~/.config/sleep/override-until`.

The enforcement script reads `override-until` before suspending: if `now < override-until`, it skips suspend.

Override constraints:

- One override per 12-hour window, max. The script reads the latest record in `overrides.log` and refuses if its issue timestamp is less than 12 hours ago. (This avoids the midnight edge case of "one per calendar day" — at 12:01am you'd otherwise get a second override.)
- Override grants exactly one hour from issue time. After expiry, the suspend loop resumes immediately on the next trigger.
- Override can be issued before lockdown starts (e.g., 8:00pm). It still consumes the 12-hour quota and lasts one hour from issue. Practically, this means an early override is wasteful but allowed.

## Components

Four bash scripts in `~/.local/bin/` and a small set of systemd user units in `~/.config/systemd/user/`.

### `sleep-warn`

Sends a desktop notification via `notify-send`. Takes the message as the first argument. Uses `--urgency=critical` so it shows above fullscreen apps and is hard to miss.

### `sleep-enforce`

The core enforcement script. On invocation:

1. Read current local time.
2. If current time is outside `[21:30, 06:00)`, exit 0. (Outside lockdown window.)
3. If `~/.config/sleep/override-until` exists and contains an epoch timestamp greater than `now`, exit 0. (Override active.)
4. Append a line to `~/.config/sleep/enforce.log`: timestamp + "suspending".
5. Run `loginctl lock-session`.
6. Run `systemctl suspend`.

Triggered by:
- A systemd user timer firing at 21:30 daily.
- A systemd user timer firing every 3 minutes during the lockdown window (handles wake events; cheap to run; the time-window check in step 2 makes it a no-op outside the window).

The 3-minute polling timer is simpler than `post-resume` hook plumbing and equally effective: the user-facing behavior is "you wake the machine, it suspends within ~3 minutes." That's plenty fast to defeat any meaningful work, and the polling cost is negligible (a 5-line bash script every 3 minutes).

### `sleep-override`

Interactive CLI. On invocation:

1. Read the last line of `~/.config/sleep/overrides.log` (if any). If its timestamp is less than 12 hours ago, print "Override already used (cooldown remaining: HH:MM)" and exit 1.
2. Prompt for answer 1; reject empty/whitespace input, retry.
3. Prompt for answer 2; same validation.
4. Prompt for answer 3; same validation.
5. Append `<ISO-8601 timestamp>\t<answer1>\t<answer2>\t<answer3>` to `~/.config/sleep/overrides.log`.
6. Write `<now-epoch + 3600>` to `~/.config/sleep/override-until`.
7. Print "Override granted until <HH:MM>. Sleep well."

### `sleep-status`

Read-only diagnostics. Prints:
- Current time.
- Whether currently in the lockdown window.
- Whether an override is active, and if so, when it expires.
- Today's override count (0 or 1).
- Last 5 lines of `enforce.log` and `overrides.log`.

## File layout

```
~/.local/bin/
  sleep-warn
  sleep-enforce
  sleep-override
  sleep-status

~/.config/systemd/user/
  sleep-warn-2100.service
  sleep-warn-2100.timer
  sleep-warn-2125.service
  sleep-warn-2125.timer
  sleep-enforce.service
  sleep-enforce.timer

~/.config/sleep/
  override-until        # epoch timestamp (file may be absent)
  overrides.log         # tab-separated: ISO-timestamp \t a1 \t a2 \t a3
  enforce.log           # ISO-timestamp + "suspending"
```

## Tech choices

**Language: bash.** Four scripts, none over ~30 lines. No runtime to manage.

**Scheduler: systemd user timers.** Cron alternative was rejected because (a) systemd already runs as a user service on this machine, (b) systemd timers handle missed runs and journal logging cleanly, (c) `systemctl --user list-timers` gives a one-line debug story, (d) cron has no clean wake-from-suspend trigger.

**Wake handling: 3-minute polling timer instead of `systemd-suspend.service` post-resume hook.** The post-resume hook is more elegant but requires either a system-level unit (root) or `OnResumePolicy` on a user unit, which has had inconsistent behavior across systemd versions. A polling timer is one extra config line and trivially correct.

**Lock command: `loginctl lock-session`.** Standard on Wayland GNOME. Tested as available on the target machine.

**Suspend command: `systemctl suspend`.** Polkit on Manjaro allows the active user to suspend without password prompt. No `sudo` needed.

**Notification: `notify-send --urgency=critical`.** Critical urgency bypasses Do Not Disturb on GNOME.

## Install / uninstall

`./install.sh`:
- Copies the four scripts to `~/.local/bin/` (creates dir if needed).
- `chmod +x` on each.
- Copies the six unit files to `~/.config/systemd/user/`.
- `systemctl --user daemon-reload`.
- `systemctl --user enable --now sleep-warn-2100.timer sleep-warn-2125.timer sleep-enforce.timer`.
- Prints status.

`./uninstall.sh`:
- `systemctl --user disable --now` the three timers.
- Removes the six unit files and four scripts.
- Leaves `~/.config/sleep/` data alone (logs are user data; user can delete manually).

## Edge cases & decisions

- **Computer off at 9:00pm or 9:30pm**: nothing fires, fine. When user turns it on at 11:00pm, the 3-minute enforce timer fires, sees current time is in window, suspends.
- **User on a video call at 9:30pm**: suspend kills the call. Acceptable — that's the point. The 9:00pm and 9:25pm warnings give 30 minutes to wrap up. If genuinely necessary, the user runs `sleep-override` before 9:30pm.
- **Override active, alarm clock app suspended too**: not a concern — phones handle alarms.
- **DST transitions**: bash `date` reports local time correctly across DST. The 9:30pm–6:00am window remains in local clock time, which is what the user intuitively wants.
- **Multiple consecutive overrides via clock manipulation**: out of scope. User is root; if they want to set the system clock back to defeat the daily quota, they can. That action is more deliberate than just `systemctl --user stop`, so it doesn't represent an easier escape than already exists.
- **The user disables the unit at 9:25pm**: explicitly accepted as a possible failure mode. The mitigation is *social* — the override path is faster than disabling, so the addiction-brain takes the override path. Disabling requires a deliberate moral act.

## Success criteria

- Spec is implementable in well under a day of work.
- After install, the machine reliably suspends at 9:30pm and keeps suspending until 6:00am, every night.
- `sleep-override` works end-to-end and grants a 1-hour reprieve.
- `sleep-status` is a useful diagnostic that the user actually runs to sanity-check the system.
- No background daemons, no language runtimes, no closed source. Total install footprint: ~10 files, all human-readable.
