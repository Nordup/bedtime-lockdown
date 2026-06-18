"""sleep-override: window-aware friction CLI. Detects the active window,
asks 3 deliberately uncomfortable questions, logs the answers, grants a
window-appropriate reprieve."""

import sys
import time
from datetime import datetime

from . import common
from .config import state_dir
from .platforms import backend


def _read_nonempty(prompt: str) -> str:
    while True:
        try:
            ans = input(f"{prompt} ")
        except EOFError:
            print("\n(input ended; aborting)", file=sys.stderr)
            sys.exit(1)
        if ans.strip():
            return ans
        print("  (answer cannot be empty)", file=sys.stderr)


def main() -> int:
    now = int(time.time())
    win = common.current_window(common.current_hhmm())

    if win == "none":
        print(
            "No active enforcement window right now. Override is only useful "
            "inside a lock window.",
            file=sys.stderr,
        )
        return 1

    if not common.override_enabled(win):
        print(
            "Override is disabled during the night. The bedtime lock is "
            "non-negotiable — there is no reprieve to grant. Go to sleep.",
            file=sys.stderr,
        )
        return 1

    state_dir().mkdir(parents=True, exist_ok=True)

    try:
        with backend.acquire_single_writer_lock(f"override.{win}"):
            return _run(now, win)
    except BlockingIOError:
        print("Another sleep-override is running. Try again.", file=sys.stderr)
        return 1


def _run(now: int, win: str) -> int:
    cd = common.cooldown_remaining(now, win)
    if cd.corrupted:
        log = common.overrides_log_path(win)
        print(f"warning: corrupted timestamp in {log}; failing closed", file=sys.stderr)
    if cd.remaining > 0:
        print(
            f"Override for {win} already used. Cooldown remaining: "
            f"{common.format_hm(cd.remaining)}",
            file=sys.stderr,
        )
        return 1

    questions = {
        "lunch":   "Why is this lunch break the wrong time to step away?",
        "dinner":  "Why is this exercise + dinner break the wrong time to step away?",
    }
    q2 = questions[win]

    a1 = _read_nonempty("What are you doing right now?")
    a2 = _read_nonempty(q2)
    a3 = _read_nonempty("What time will you actually stop?")

    # Only override-enabled windows (lunch, dinner) reach here — bedtime is
    # refused upstream in main(). Both grant a reprieve until end-of-window.
    # NOTE: if bedtime were ever re-added to OVERRIDE_ENABLED_WINDOWS it would
    # need a *bounded* duration here — window_end_epoch("bedtime") resolves to
    # 06:00, which would wrongly grant a reprieve until morning.
    expires = common.window_end_epoch(win, now)

    log_path = common.overrides_log_path(win)
    with log_path.open("a") as f:
        f.write(f"{common.now_iso()}\t{a1}\t{a2}\t{a3}\n")

    common.override_until_path(win).write_text(str(expires))

    expires_hm = datetime.fromtimestamp(expires).strftime("%H:%M")
    print(f"Override granted for {win} until {expires_hm}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
