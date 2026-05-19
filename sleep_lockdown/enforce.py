"""sleep-enforce: the locker. Run by systemd timers (Linux) or Task
Scheduler (Windows) every 5 min during an active window. All three
windows share this single code path."""

import sys
import time

from . import common
from .config import state_dir


def main() -> int:
    now = int(time.time())
    win = common.current_window(common.current_hhmm())

    if win == "none":
        return 0

    # Agent-mode bypasses every window — display blanked, PC awake,
    # idle-suspend inhibited. See sleep_lockdown.agent.
    if common.agent_mode_active(now):
        return 0

    if common.override_active(now, win):
        return 0

    state_dir().mkdir(parents=True, exist_ok=True)
    with common.enforce_log_path().open("a") as f:
        f.write(f"{common.now_iso()}\t{win}\tlocking\n")

    from .platforms import backend
    backend.lock_session()
    return 0


if __name__ == "__main__":
    sys.exit(main())
