"""Linux backend: loginctl / notify-send / systemd-inhibit, all via subprocess.

Zero pip deps. Assumes a freedesktop graphical session for `loginctl`
and `notify-send`. agent-mode is lock-only on Linux: GNOME 50 removed the
Mutter `DisplayConfig.SetPowerSaveMode` method that used to blank the
display, so there is no on-demand display-off step (see blank_display).
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
        # Both failing usually means no graphical session yet — stay
        # silent; this matches the bash version's `|| true` behavior.
        session_id = os.environ.get("XDG_SESSION_ID", "")
        attempts = []
        if session_id:
            attempts.append(["loginctl", "lock-session", session_id])
        attempts.append(["loginctl", "lock-session"])
        for cmd in attempts:
            if subprocess.run(cmd, capture_output=True).returncode == 0:
                return

    def blank_display(self) -> bool:
        # Lock-only on Linux. GNOME 50 removed
        # org.gnome.Mutter.DisplayConfig.SetPowerSaveMode, the only
        # on-demand display-off API we had, and nothing replaces it that
        # also wakes on a keypress: a DDC/CI power-off (ddcutil) does turn
        # the monitor off, but on real panels it can't be woken by input or
        # even by DDC — some need a physical power-cycle. So agent-mode
        # locks the session and keeps the PC awake, but leaves the display
        # powered. Returning False makes the CLI say "screen locked"
        # instead of falsely claiming the display went dark. A future
        # KDE/sway/X11-specific blank could revive this (see README).
        return False

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

    def pid_alive(self, pid: int) -> bool:
        # Signal 0 performs error-checking without sending a signal:
        # success or PermissionError means the process exists,
        # ProcessLookupError means it's gone.
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        return True

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
