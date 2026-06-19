"""Abstract platform backend.

Each method is one OS-specific side effect that the CLI commands
delegate to. The contract is intentionally narrow — pure logic stays
in common.py.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Optional


class PlatformBackend(ABC):
    @abstractmethod
    def lock_session(self) -> None:
        """Lock the current graphical session. Best-effort: should not
        raise if no graphical session is available — locking from a
        headless TTY simply does nothing useful."""
        ...

    @abstractmethod
    def blank_display(self) -> bool:
        """Turn the display off. Returns True on success, False if the
        backend couldn't do it (e.g. wrong DE). Caller should warn but
        continue — the rest of agent-mode is still useful."""
        ...

    @abstractmethod
    def notify(self, title: str, body: str) -> None:
        """Best-effort desktop notification. Critical urgency on Linux,
        toast on Windows."""
        ...

    @abstractmethod
    def spawn_inhibit_idle_sleep(self, duration_sec: int, reason: str) -> int:
        """Spawn a detached background process that holds an idle-sleep
        inhibitor for `duration_sec` and then exits, releasing it.
        Returns the PID. The process should survive its parent's exit."""
        ...

    @abstractmethod
    def kill_pid(self, pid: int) -> None:
        """Best-effort SIGTERM (Linux) / TerminateProcess (Windows).
        Silently no-ops if the PID doesn't exist or isn't ours."""
        ...

    @abstractmethod
    def pid_alive(self, pid: int) -> bool:
        """True if a process with this PID currently exists. Used to decide
        whether a re-run must respawn the idle-suspend inhibitor (its
        pinned process may have died). Best-effort: returns False if the
        process is gone or its state can't be determined."""
        ...

    @abstractmethod
    def acquire_single_writer_lock(self, name: str):
        """Returns a context manager that holds a process-wide exclusive
        lock named `name`, or raises BlockingIOError if another holder
        exists. Used to prevent two interactive commands racing on the
        same log/state file."""
        ...
