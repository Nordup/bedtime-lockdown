"""Hard-coded constants and runtime paths.

CONFIG NOTE: window start values are duplicated in the Linux systemd
calendar timers (systemd timers can't read shell or python variables)
and in the Windows Task Scheduler triggers (written by install.py from
these values). If you change a *_START_HHMM here you must reinstall
to push the new triggers, or edit them by hand:

    LOCKDOWN_START_HHMM (bedtime):
        systemd/sleep-warn-15.timer         -> 15 min before
        systemd/sleep-warn-5.timer          ->  5 min before
        systemd/sleep-enforce-bedtime.timer -> sharp
    LUNCH_START_HHMM:
        systemd/sleep-warn-lunch-15.timer / sleep-warn-lunch-5.timer /
        sleep-enforce-lunch.timer
    DINNER_START_HHMM:
        systemd/sleep-warn-dinner-15.timer / sleep-warn-dinner-5.timer /
        sleep-enforce-dinner.timer

*_END_HHMM values are used only by window checks in this module; no
unit refers to them.
"""

import os
import sys
from pathlib import Path

LOCKDOWN_START_HHMM = 2100          # bedtime: lock at 21:00
LOCKDOWN_END_HHMM   = 600           # wake-up: window ends at 06:00
LUNCH_START_HHMM    = 1130          # lunch break starts 11:30
LUNCH_END_HHMM      = 1215          # lunch break ends 12:15
DINNER_START_HHMM   = 1630          # exercise+dinner starts 16:30
DINNER_END_HHMM     = 1830          # exercise+dinner ends 18:30

COOLDOWN_SEC          = 12 * 3600    # one override per 12 hours, per window

# Windows that permit an override. Bedtime is deliberately excluded — the
# night lock is non-negotiable. Single source of truth for the override
# policy; consumed by common.override_enabled().
OVERRIDE_ENABLED_WINDOWS = ("lunch", "dinner")


def state_dir() -> Path:
    """Runtime state location.

    Linux:   ~/.config/sleep                  (matches the bash layout)
    Windows: %LOCALAPPDATA%/sleep-lockdown/state
    """
    override = os.environ.get("SLEEP_HOME")
    if override:
        return Path(override)
    if sys.platform == "win32":
        base = os.environ.get("LOCALAPPDATA") or str(Path.home() / "AppData" / "Local")
        return Path(base) / "sleep-lockdown" / "state"
    return Path.home() / ".config" / "sleep"
