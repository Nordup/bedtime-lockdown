"""sleep-status: read-only diagnostic. Shows window states, agent-mode,
recent enforce events, recent overrides."""

import sys
import time
from datetime import datetime

from . import common
from .config import (
    DINNER_END_HHMM,
    DINNER_START_HHMM,
    LOCKDOWN_END_HHMM,
    LOCKDOWN_START_HHMM,
    LUNCH_END_HHMM,
    LUNCH_START_HHMM,
    state_dir,
)


def main() -> int:
    now = int(time.time())
    hhmm = common.current_hhmm()
    active_win = common.current_window(hhmm)

    print(f"Now:           {datetime.now()}")
    print(f"Active window: {active_win}")

    agent_until = common.read_until_epoch(common.agent_until_path())
    if agent_until is not None and agent_until > now:
        until_hm = datetime.fromtimestamp(agent_until).strftime("%H:%M")
        print(
            f"Agent-mode:    ACTIVE until {until_hm} "
            "(display off, idle-suspend inhibited)"
        )
    else:
        print("Agent-mode:    inactive")
    print()

    _print_window_block("Bedtime", "bedtime", LOCKDOWN_START_HHMM, LOCKDOWN_END_HHMM, now, active_win)
    print()
    _print_window_block("Lunch",   "lunch",   LUNCH_START_HHMM,    LUNCH_END_HHMM,    now, active_win)
    print()
    _print_window_block("Dinner",  "dinner",  DINNER_START_HHMM,   DINNER_END_HHMM,   now, active_win)

    print()
    print("Last 5 enforce events:")
    _print_tail(common.enforce_log_path(), 5)

    print()
    print("Last 5 overrides (across all windows):")
    _print_merged_overrides()

    return 0


def _print_window_block(label: str, win: str, start: int, end: int, now: int, active_win: str) -> None:
    window_label = f"{common.format_hhmm_as_clock(start)} - {common.format_hhmm_as_clock(end)}"
    active = "ACTIVE" if active_win == win else "inactive"
    print(f"{label:<8} window {window_label}   {active}")

    override_until = common.read_until_epoch(common.override_until_path(win))
    if override_until is not None and override_until > now:
        until_hm = datetime.fromtimestamp(override_until).strftime("%H:%M")
        print(f"         override active until {until_hm}")
    else:
        print("         override: none")

    cd = common.cooldown_remaining(now, win)
    if cd.remaining > 0:
        print(f"         cooldown: {common.format_hm(cd.remaining)} remaining")
    else:
        print("         cooldown: ready")

    log_path = common.overrides_log_path(win)
    today = datetime.now().strftime("%Y-%m-%d")
    count = 0
    if log_path.exists() and log_path.stat().st_size:
        for line in log_path.read_text().splitlines():
            if line.startswith(today):
                count += 1
    print(f"         overrides today: {count}")


def _print_tail(path, n: int) -> None:
    if not path.exists() or path.stat().st_size == 0:
        print("  (none)")
        return
    lines = [ln for ln in path.read_text().splitlines() if ln.strip()]
    for line in lines[-n:]:
        print(line)


def _print_merged_overrides() -> None:
    rows = []
    for win in ("bedtime", "lunch", "dinner"):
        path = common.overrides_log_path(win)
        if not path.exists() or path.stat().st_size == 0:
            continue
        for line in path.read_text().splitlines():
            if not line.strip():
                continue
            ts, rest = (line.split("\t", 1) + [""])[:2]
            rows.append((ts, win, rest))
    rows.sort(key=lambda r: r[0])
    if not rows:
        print("  (none)")
        return
    for ts, win, rest in rows[-5:]:
        print(f"{ts}\t[{win}]\t{rest}")


if __name__ == "__main__":
    sys.exit(main())
