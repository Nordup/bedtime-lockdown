"""sleep-warn: thin wrapper around the platform's notification API.

Invoked by systemd timers / Task Scheduler at the -15 and -5 marks
before each window start.
"""

import argparse
import sys

from .platforms import backend


def main() -> int:
    p = argparse.ArgumentParser(
        prog="sleep-warn",
        description="Send a critical desktop notification.",
    )
    p.add_argument("body", nargs="?", default="Bedtime warning")
    p.add_argument("title", nargs="?", default="Bedtime Lockdown")
    args = p.parse_args()

    backend.notify(args.title, args.body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
