"""sleep-agent: per-window agent-mode. Inside any active enforcement
window, locks the session, blanks the display, and spawns a backgrounded
idle-suspend inhibitor that lives until window-end. No questions, no
cooldown — designed for routine 3x/day use."""

import argparse
import sys
import time
from datetime import datetime

from . import common
from .config import state_dir
from .platforms import backend


def main() -> int:
    p = argparse.ArgumentParser(
        prog="sleep-agent",
        description="Lock + blank + inhibit idle-suspend until the current window ends.",
    )
    # Internal helper used on Windows to hold ES_SYSTEM_REQUIRED in a
    # detached child process. Mirrors `systemd-inhibit ... sleep N` on
    # Linux. Hidden from --help.
    p.add_argument(
        "--internal-inhibit", type=int, default=None,
        help=argparse.SUPPRESS,
    )
    args = p.parse_args()

    if args.internal_inhibit is not None:
        return _run_internal_inhibit(args.internal_inhibit)

    now = int(time.time())
    win = common.current_window(common.current_hhmm())
    if win == "none":
        print(
            "No active enforcement window right now. Sleep-agent only does "
            "something inside lunch, dinner, or bedtime.",
            file=sys.stderr,
        )
        return 1

    state_dir().mkdir(parents=True, exist_ok=True)

    try:
        with backend.acquire_single_writer_lock("agent"):
            return _activate(now, win)
    except BlockingIOError:
        print("Another sleep-agent is running. Try again.", file=sys.stderr)
        return 1


def _activate(now: int, win: str) -> int:
    if common.agent_mode_active(now):
        until = int(common.agent_until_path().read_text().strip())
        until_hm = datetime.fromtimestamp(until).strftime("%H:%M")
        print(f"Agent-mode already active until {until_hm}. Nothing to do.")
        return 0

    expires = common.window_end_epoch(win, now)
    duration = expires - now

    # Log one line per use.
    with common.agent_log_path().open("a") as f:
        f.write(f"{common.now_iso()}\t{win}\n")

    common.agent_until_path().write_text(str(expires))

    # Kill any leftover inhibitor from a previous run.
    pid_path = common.agent_inhibit_pid_path()
    if pid_path.exists():
        try:
            old = int(pid_path.read_text().strip())
            backend.kill_pid(old)
        except (ValueError, OSError):
            pass

    pid = backend.spawn_inhibit_idle_sleep(
        duration_sec=duration,
        reason=f"sleep-agent active in {win} window",
    )
    pid_path.write_text(str(pid))

    backend.lock_session()
    if not backend.blank_display():
        print(
            "warning: could not blank the display. PC will still stay awake.",
            file=sys.stderr,
        )

    until_hm = datetime.fromtimestamp(expires).strftime("%H:%M")
    print(
        f"Agent-mode active in {win} window until {until_hm}. "
        "Display off, any key wakes."
    )
    return 0


def _run_internal_inhibit(duration_sec: int) -> int:
    """Windows-only: hold ES_SYSTEM_REQUIRED for the duration. Linux
    uses the systemd-inhibit subprocess pattern instead and never hits
    this code path."""
    if sys.platform != "win32":
        # Linux path runs systemd-inhibit directly; calling --internal-
        # inhibit on Linux is a misconfiguration. Sleep the duration
        # anyway so the parent's PID record doesn't immediately stale.
        time.sleep(duration_sec)
        return 0
    from .platforms.windows import hold_execution_state
    hold_execution_state(duration_sec)
    return 0


if __name__ == "__main__":
    sys.exit(main())
