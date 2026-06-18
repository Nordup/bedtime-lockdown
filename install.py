#!/usr/bin/env python3
"""Cross-platform installer for sleep-lockdown.

Linux: copies the package, writes shell shims, installs systemd user
units, enables timers.

Windows: copies the package, writes .cmd shims, registers Task Scheduler
entries, adds bin to user PATH.

Reads window start times from sleep_lockdown.config so Windows triggers
stay in sync with the in-process schedule.
"""

import os
import shlex
import shutil
import subprocess
import sys
from pathlib import Path
from xml.sax.saxutils import escape as xml_escape

REPO = Path(__file__).resolve().parent
sys.path.insert(0, str(REPO))

from sleep_lockdown.config import (  # noqa: E402
    DINNER_START_HHMM,
    LOCKDOWN_START_HHMM,
    LUNCH_START_HHMM,
)

ENTRY_POINTS = ("sleep-enforce", "sleep-agent", "sleep-override", "sleep-status", "sleep-warn")


# --- shared helpers -----------------------------------------------------

def _module_name(entry: str) -> str:
    # sleep-enforce → sleep_lockdown.enforce
    return f"sleep_lockdown.{entry.removeprefix('sleep-')}"


def _shim_body_posix(lib_dir: Path, module: str) -> str:
    # PYTHONPATH + -m keeps the path out of any nested string-quoting
    # layer. shlex.quote handles spaces, quotes, $ in lib_dir safely.
    # ${PYTHONPATH:+:$PYTHONPATH} preserves any existing PYTHONPATH
    # without leaving a trailing colon when it's empty.
    quoted = shlex.quote(str(lib_dir))
    return (
        "#!/bin/sh\n"
        f"PYTHONPATH={quoted}${{PYTHONPATH:+:$PYTHONPATH}} "
        f"exec python3 -m {module} \"$@\"\n"
    )


def _shim_body_windows(lib_dir: Path, module: str) -> str:
    # `set "VAR=..."` form in cmd.exe handles spaces in paths cleanly.
    # %PYTHONPATH% expands to empty if unset, leaving a trailing semicolon
    # — harmless for Python's path parser.
    return (
        "@echo off\r\n"
        f"set \"PYTHONPATH={lib_dir};%PYTHONPATH%\"\r\n"
        f"python -m {module} %*\r\n"
    )


def _copy_package(dest_lib: Path) -> None:
    src_pkg = REPO / "sleep_lockdown"
    dest_pkg = dest_lib / "sleep_lockdown"
    if dest_pkg.exists():
        shutil.rmtree(dest_pkg)
    shutil.copytree(src_pkg, dest_pkg)


# --- Linux --------------------------------------------------------------

def install_linux() -> None:
    home = Path.home()
    bin_dir   = home / ".local" / "bin"
    lib_dir   = home / ".local" / "share" / "sleep-lockdown"
    unit_dir  = home / ".config" / "systemd" / "user"
    state_dir = home / ".config" / "sleep"

    for d in (bin_dir, lib_dir, unit_dir, state_dir):
        d.mkdir(parents=True, exist_ok=True)

    print(f"Copying package to {lib_dir}")
    _copy_package(lib_dir)

    print(f"Writing {len(ENTRY_POINTS)} shims to {bin_dir}")
    for entry in ENTRY_POINTS:
        shim = bin_dir / entry
        shim.write_text(_shim_body_posix(lib_dir, _module_name(entry)))
        shim.chmod(0o755)

    print(f"Installing systemd units to {unit_dir}")
    for src in (REPO / "systemd").iterdir():
        if src.suffix in (".service", ".timer"):
            shutil.copy2(src, unit_dir / src.name)

    print("Reloading systemd user daemon and enabling timers")
    subprocess.run(["systemctl", "--user", "daemon-reload"], check=True)
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
    subprocess.run(["systemctl", "--user", "enable", "--now", *timers], check=True)

    print()
    print("Installed. Run sleep-status to inspect state any time.")


# --- Windows ------------------------------------------------------------

def install_windows() -> None:
    base = Path(os.environ.get("LOCALAPPDATA",
                               str(Path.home() / "AppData" / "Local"))) / "sleep-lockdown"
    bin_dir   = base / "bin"
    lib_dir   = base / "lib"
    state_dir = base / "state"
    for d in (bin_dir, lib_dir, state_dir):
        d.mkdir(parents=True, exist_ok=True)

    print(f"Copying package to {lib_dir}")
    _copy_package(lib_dir)

    print(f"Writing {len(ENTRY_POINTS)} .cmd shims to {bin_dir}")
    for entry in ENTRY_POINTS:
        shim = bin_dir / f"{entry}.cmd"
        shim.write_text(_shim_body_windows(lib_dir, _module_name(entry)))

    print("Ensuring bin directory is on user PATH")
    _ensure_user_path_windows(str(bin_dir))

    print("Registering Task Scheduler tasks")
    _register_windows_tasks(bin_dir)

    print()
    print("Installed. Open a NEW terminal and run sleep-status to inspect state.")


def _ensure_user_path_windows(new_entry: str) -> None:
    # setx PATH is the standard approach. It only affects new processes,
    # which is fine — the install message tells the user to open a new
    # terminal.
    current = os.environ.get("PATH", "")
    if new_entry.lower() in (p.lower() for p in current.split(os.pathsep)):
        return
    user_path = subprocess.run(
        ["powershell", "-NoProfile", "-Command",
         "[Environment]::GetEnvironmentVariable('Path','User')"],
        capture_output=True, text=True,
    ).stdout.strip()
    parts = [p for p in user_path.split(";") if p]
    if new_entry.lower() not in (p.lower() for p in parts):
        parts.append(new_entry)
    subprocess.run(
        ["powershell", "-NoProfile", "-Command",
         f"[Environment]::SetEnvironmentVariable('Path','{';'.join(parts)}','User')"],
        check=True,
    )


def _hhmm_to_clock(hhmm: int) -> str:
    return f"{hhmm // 100:02d}:{hhmm % 100:02d}"


def _minus(hhmm: int, minutes: int) -> str:
    """HHMM minus N minutes, as HH:MM clock. Wraps via 24h."""
    total = (hhmm // 100) * 60 + (hhmm % 100) - minutes
    total %= 24 * 60
    return f"{total // 60:02d}:{total % 60:02d}"


def _register_windows_tasks(bin_dir: Path) -> None:
    # Reuses Task Scheduler XML for richer triggers, but for the
    # familiar daily kickoffs schtasks /Create is simpler. Each task
    # name is scoped under \BedtimeLockdown\.
    folder = r"\BedtimeLockdown"
    warn_cmd = str(bin_dir / "sleep-warn.cmd")
    enforce_cmd = str(bin_dir / "sleep-enforce.cmd")

    plan = [
        # (task name, time HH:MM, command line)
        ("warn-15",          _minus(LOCKDOWN_START_HHMM, 15),
         f'"{warn_cmd}" "Bedtime in 15 minutes. Save your work."'),
        ("warn-5",           _minus(LOCKDOWN_START_HHMM,  5),
         f'"{warn_cmd}" "Bedtime in 5 minutes."'),
        ("enforce-bedtime",  _hhmm_to_clock(LOCKDOWN_START_HHMM),
         f'"{enforce_cmd}"'),

        ("warn-lunch-15",    _minus(LUNCH_START_HHMM, 15),
         f'"{warn_cmd}" "Lunch in 15 minutes."'),
        ("warn-lunch-5",     _minus(LUNCH_START_HHMM,  5),
         f'"{warn_cmd}" "Lunch in 5 minutes."'),
        ("enforce-lunch",    _hhmm_to_clock(LUNCH_START_HHMM),
         f'"{enforce_cmd}"'),

        ("warn-dinner-15",   _minus(DINNER_START_HHMM, 15),
         f'"{warn_cmd}" "Exercise + dinner in 15 minutes."'),
        ("warn-dinner-5",    _minus(DINNER_START_HHMM,  5),
         f'"{warn_cmd}" "Exercise + dinner in 5 minutes."'),
        ("enforce-dinner",   _hhmm_to_clock(DINNER_START_HHMM),
         f'"{enforce_cmd}"'),
    ]

    for name, hhmm, cmd in plan:
        full = f"{folder}\\{name}"
        subprocess.run(
            ["schtasks", "/Create", "/F",  # /F = overwrite if exists
             "/TN", full,
             "/SC", "DAILY",
             "/ST", hhmm,
             "/TR", cmd,
             "/RL", "LIMITED",  # current user, no elevation
            ],
            check=True,
        )

    # Wake-loop on resume — fires sleep-enforce 3 min after every
    # power-state resume event. Replicates the Linux monotonic timer.
    wakeloop_xml = _wakeloop_task_xml(enforce_cmd)
    xml_path = bin_dir / "wakeloop.xml"
    xml_path.write_text(wakeloop_xml, encoding="utf-16")
    subprocess.run(
        ["schtasks", "/Create", "/F",
         "/TN", f"{folder}\\enforce-wakeloop",
         "/XML", str(xml_path)],
        check=True,
    )


def _wakeloop_task_xml(enforce_cmd: str) -> str:
    # Event trigger: System / Microsoft-Windows-Power-Troubleshooter /
    # Event ID 1 (logged on every return from low-power state). 3-min
    # delay matches the Linux monotonic wake-loop. XML-escape the
    # command path defensively — real Windows paths rarely contain &/<,
    # but an escape pass is free insurance.
    cmd = xml_escape(enforce_cmd)
    return f"""<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Delay>PT3M</Delay>
      <Subscription>
&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;
*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]
&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;
      </Subscription>
    </EventTrigger>
  </Triggers>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
  </Settings>
  <Actions>
    <Exec>
      <Command>{cmd}</Command>
    </Exec>
  </Actions>
</Task>
"""


# --- entrypoint ---------------------------------------------------------

def main() -> int:
    if sys.platform == "win32":
        install_windows()
    else:
        install_linux()
    return 0


if __name__ == "__main__":
    sys.exit(main())
