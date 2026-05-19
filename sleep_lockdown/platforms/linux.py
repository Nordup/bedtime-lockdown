"""Linux backend: gdbus / loginctl / notify-send / systemd-inhibit, all via subprocess.

Zero pip deps. Assumes a freedesktop graphical session for `loginctl`
and `notify-send`. agent-mode's display blank uses Mutter's
`DisplayConfig` D-Bus method (GNOME); other DEs warn and continue.
"""

from __future__ import annotations

import fcntl
import os
import signal
import subprocess
from contextlib import contextmanager
from pathlib import Path

from ..config import state_dir
from .base import PlatformBackend


class LinuxBackend(PlatformBackend):

    def lock_session(self) -> None:
        # Try the explicit session ID first (more robust when the user
        # unit's env is sparse), then fall back to the implicit form.
        session_id = os.environ.get("XDG_SESSION_ID", "")
        for cmd in (
            ["loginctl", "lock-session", session_id] if session_id else None,
            ["loginctl", "lock-session"],
        ):
            if cmd is None:
                continue
            r = subprocess.run(cmd, capture_output=True)
            if r.returncode == 0:
                return
        # All failed — likely no graphical session yet. Stay silent;
        # this matches the bash version's `|| true` behavior.

    def blank_display(self) -> bool:
        # SetPowerSaveMode: 0=on, 1=standby, 2=suspend, 3=off.
        cmd = [
            "gdbus", "call", "--session",
            "--dest", "org.gnome.Mutter.DisplayConfig",
            "--object-path", "/org/gnome/Mutter/DisplayConfig",
            "--method", "org.gnome.Mutter.DisplayConfig.SetPowerSaveMode",
            "3",
        ]
        r = subprocess.run(cmd, capture_output=True)
        return r.returncode == 0

    def notify(self, title: str, body: str) -> None:
        subprocess.run(
            ["notify-send", "--urgency=critical", title, body],
            capture_output=True,
        )

    def spawn_inhibit_idle_sleep(self, duration_sec: int, reason: str) -> int:
        # systemd-inhibit holds the lock for the lifetime of its child
        # command. `sleep N` is the cheapest child that lives exactly N
        # seconds. setsid + DEVNULL detaches from this terminal.
        proc = subprocess.Popen(
            [
                "systemd-inhibit",
                "--what=idle:sleep",
                "--who=sleep-agent",
                f"--why={reason}",
                "--mode=block",
                "sleep", str(duration_sec),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,  # detach from parent's session/PG
        )
        return proc.pid

    def kill_pid(self, pid: int) -> None:
        try:
            os.kill(pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass

    @contextmanager
    def acquire_single_writer_lock(self, name: str):
        # File-based flock — same primitive bash uses. Held for the life
        # of the file descriptor; released automatically on context exit.
        state_dir().mkdir(parents=True, exist_ok=True)
        lock_path: Path = state_dir() / f"{name}.lock"
        fd = os.open(lock_path, os.O_CREAT | os.O_WRONLY, 0o644)
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                os.close(fd)
                raise
            yield
        finally:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            except OSError:
                pass
            os.close(fd)
