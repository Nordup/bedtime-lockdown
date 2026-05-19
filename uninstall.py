#!/usr/bin/env python3
"""Cross-platform uninstaller. Mirrors install.py."""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ENTRY_POINTS = ("sleep-enforce", "sleep-agent", "sleep-override", "sleep-status", "sleep-warn")


def uninstall_linux() -> None:
    home = Path.home()
    bin_dir  = home / ".local" / "bin"
    lib_dir  = home / ".local" / "share" / "sleep-lockdown"
    unit_dir = home / ".config" / "systemd" / "user"

    timers = [
        "sleep-warn-15.timer",
        "sleep-warn-5.timer",
        "sleep-warn-lunch-15.timer",
        "sleep-warn-lunch-5.timer",
        "sleep-warn-dinner-15.timer",
        "sleep-warn-dinner-5.timer",
        "sleep-enforce.timer",
        "sleep-enforce-bedtime.timer",
        "sleep-enforce-lunch.timer",
        "sleep-enforce-dinner.timer",
    ]
    print("Disabling systemd timers")
    subprocess.run(["systemctl", "--user", "disable", "--now", *timers],
                   capture_output=True)

    print("Removing unit files")
    for src in (Path(__file__).resolve().parent / "systemd").iterdir():
        if src.suffix in (".service", ".timer"):
            (unit_dir / src.name).unlink(missing_ok=True)

    print("Removing shims")
    for entry in ENTRY_POINTS:
        (bin_dir / entry).unlink(missing_ok=True)

    print("Removing package directory")
    if lib_dir.exists():
        shutil.rmtree(lib_dir)

    subprocess.run(["systemctl", "--user", "daemon-reload"], check=True)

    print()
    print("Uninstalled. State directory ~/.config/sleep was left intact.")
    print("Remove manually with: rm -rf ~/.config/sleep")


def uninstall_windows(purge: bool = False) -> None:
    base = Path(os.environ.get("LOCALAPPDATA",
                               str(Path.home() / "AppData" / "Local"))) / "sleep-lockdown"
    bin_dir = base / "bin"
    lib_dir = base / "lib"

    print("Removing Task Scheduler tasks")
    for name in (
        "warn-15", "warn-5", "enforce-bedtime",
        "warn-lunch-15", "warn-lunch-5", "enforce-lunch",
        "warn-dinner-15", "warn-dinner-5", "enforce-dinner",
        "enforce-wakeloop",
    ):
        subprocess.run(
            ["schtasks", "/Delete", "/F", "/TN", f"\\BedtimeLockdown\\{name}"],
            capture_output=True,
        )
    # Remove the folder if empty.
    subprocess.run(
        ["schtasks", "/Delete", "/F", "/TN", "\\BedtimeLockdown"],
        capture_output=True,
    )

    print("Removing PATH entry")
    _remove_user_path_windows(str(bin_dir))

    print("Removing bin and lib directories")
    for d in (bin_dir, lib_dir):
        if d.exists():
            shutil.rmtree(d)

    if purge:
        state_dir = base / "state"
        if state_dir.exists():
            shutil.rmtree(state_dir)
        if base.exists() and not any(base.iterdir()):
            base.rmdir()
        print("Purged state directory too.")
    else:
        print()
        print("Uninstalled. State directory left intact. Pass --purge to remove it too.")


def _remove_user_path_windows(entry: str) -> None:
    user_path = subprocess.run(
        ["powershell", "-NoProfile", "-Command",
         "[Environment]::GetEnvironmentVariable('Path','User')"],
        capture_output=True, text=True,
    ).stdout.strip()
    parts = [p for p in user_path.split(";") if p and p.lower() != entry.lower()]
    subprocess.run(
        ["powershell", "-NoProfile", "-Command",
         f"[Environment]::SetEnvironmentVariable('Path','{';'.join(parts)}','User')"],
        check=True,
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="uninstall.py",
        description="Uninstall sleep-lockdown.",
    )
    parser.add_argument(
        "--purge", action="store_true",
        help="Also remove the runtime state directory (logs and override flags). "
             "Only honored on Windows; the Linux uninstaller never deletes state.",
    )
    args = parser.parse_args()

    if sys.platform == "win32":
        uninstall_windows(purge=args.purge)
    else:
        uninstall_linux()
    return 0


if __name__ == "__main__":
    sys.exit(main())
