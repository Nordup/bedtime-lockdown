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
        return _reassert(now, win)

    expires = common.window_end_epoch(win, now)
    duration = expires - now

    # Order matters. Side effects fall into three groups:
    #   1) Cleanup (idempotent): kill leftover inhibitor from a prior crash.
    #   2) Commitment (must succeed before declaring agent-mode active):
    #      spawn the new inhibitor and pin its PID. If this fails we abort
    #      WITHOUT writing agent-until — otherwise enforce.py would skip
    #      its lock loop while the OS could still auto-suspend.
    #   3) Best-effort visible side effects (log, lock, blank): if any
    #      fail after step 2, agent-mode is still correctly active.
    _kill_leftover_inhibitor()

    pid = backend.spawn_inhibit_idle_sleep(
        duration_sec=duration,
        reason=f"sleep-agent active in {win} window",
    )
    common.agent_inhibit_pid_path().write_text(str(pid))
    common.agent_until_path().write_text(str(expires))

    with common.agent_log_path().open("a") as f:
        f.write(f"{common.now_iso()}\t{win}\n")

    backend.lock_session()
    blanked = backend.blank_display()

    until_hm = datetime.fromtimestamp(expires).strftime("%H:%M")
    print(
        f"Agent-mode active in {win} window until {until_hm}. "
        f"{_screen_state_msg(blanked)}"
    )
    return 0


def _screen_state_msg(blanked: bool) -> str:
    """Tail of the activation message, honest about what actually happened.
    Where the display was powered off (Windows) say so; where it couldn't
    be (Linux — GNOME 50 dropped the on-demand blank API, so agent-mode is
    lock-only) make clear the screen is locked but still lit."""
    if blanked:
        return "Display off, any key wakes."
    return "Screen locked; display stays on, PC stays awake."


def _reassert(now: int, win: str) -> int:
    """Agent-mode is already active but the user ran sleep-agent again —
    they want the screen locked and blanked again. The display wakes on
    any key, and there is otherwise no way to put it back until the window
    ends; re-running is that "off switch".

    Re-apply the visible side effects and revive the idle-suspend
    inhibitor if its process has died. This never shortens the existing
    until-epoch: re-enabling only ever strengthens enforcement."""
    until = common.read_until_epoch(common.agent_until_path())
    if until is None:
        # Lost the until-file between the active-check and here (a race or
        # external tampering). Treat it as no longer active and re-run the
        # full activation for the current window.
        return _activate(now, win)

    _revive_inhibitor_if_dead(now, until, win)

    backend.lock_session()
    blanked = backend.blank_display()

    until_hm = datetime.fromtimestamp(until).strftime("%H:%M")
    print(
        f"Agent-mode re-applied; still active until {until_hm}. "
        f"{_screen_state_msg(blanked)}"
    )
    return 0


def _revive_inhibitor_if_dead(now: int, until: int, win: str) -> None:
    """If the pinned idle-suspend inhibitor process is gone, respawn it for
    the remaining time so the PC keeps staying awake. A live inhibitor is
    left untouched — spawning a second one would leak a process."""
    pid_path = common.agent_inhibit_pid_path()
    try:
        pid = int(pid_path.read_text().strip())
    except (ValueError, OSError):
        pid = None

    if pid is not None and backend.pid_alive(pid):
        return

    remaining = until - now
    if remaining <= 0:
        return

    new_pid = backend.spawn_inhibit_idle_sleep(
        duration_sec=remaining,
        reason=f"sleep-agent re-applied in {win} window",
    )
    pid_path.write_text(str(new_pid))


def _kill_leftover_inhibitor() -> None:
    pid_path = common.agent_inhibit_pid_path()
    if not pid_path.exists():
        return
    try:
        old = int(pid_path.read_text().strip())
    except (ValueError, OSError):
        return
    backend.kill_pid(old)


def _run_internal_inhibit(duration_sec: int) -> int:
    """Windows-only: hold ES_SYSTEM_REQUIRED for the duration. Linux uses
    the systemd-inhibit subprocess pattern instead and never hits this
    code path — invoking --internal-inhibit on Linux is a configuration
    error worth surfacing rather than papering over."""
    if sys.platform != "win32":
        print(
            "sleep-agent --internal-inhibit is a Windows-only helper. "
            "On Linux the inhibitor is systemd-inhibit, spawned directly "
            "by the Linux backend.",
            file=sys.stderr,
        )
        return 2
    from .platforms.windows import hold_execution_state
    hold_execution_state(duration_sec)
    return 0


if __name__ == "__main__":
    sys.exit(main())
