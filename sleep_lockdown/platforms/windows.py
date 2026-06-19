"""Windows backend: ctypes for lock + monitor power + execution state,
optional winrt for modern toast notifications (falls back to PowerShell).

The idle-suspend inhibitor on Windows is the per-thread
`SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)` flag.
That flag belongs to a thread and is cleared when the thread exits, so
we spawn a tiny long-lived Python child process whose only job is to
hold the flag set and sleep for the duration. Matches the Linux model
(detached background process holding the inhibitor).
"""

from __future__ import annotations

import ctypes
import os
import subprocess
import sys
from contextlib import contextmanager
from pathlib import Path

from ..config import state_dir
from .base import PlatformBackend

# --- ctypes prototypes ----------------------------------------------------

if sys.platform == "win32":
    _user32 = ctypes.WinDLL("user32", use_last_error=True)
    _kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

    # LockWorkStation(): no args, returns BOOL.
    _user32.LockWorkStation.restype = ctypes.c_bool

    # SendMessageW(hWnd, msg, wParam, lParam) — used to power off the
    # monitor via SC_MONITORPOWER.
    _user32.SendMessageW.argtypes = (
        ctypes.c_void_p,           # HWND
        ctypes.c_uint,             # UINT
        ctypes.c_void_p,           # WPARAM
        ctypes.c_ssize_t,          # LPARAM
    )
    _user32.SendMessageW.restype = ctypes.c_ssize_t

    # OpenProcess/TerminateProcess for kill_pid; WaitForSingleObject for
    # pid_alive (probing whether the inhibitor child is still running).
    _kernel32.OpenProcess.argtypes = (ctypes.c_uint, ctypes.c_bool, ctypes.c_uint)
    _kernel32.OpenProcess.restype = ctypes.c_void_p
    _kernel32.TerminateProcess.argtypes = (ctypes.c_void_p, ctypes.c_uint)
    _kernel32.TerminateProcess.restype = ctypes.c_bool
    _kernel32.WaitForSingleObject.argtypes = (ctypes.c_void_p, ctypes.c_uint)
    _kernel32.WaitForSingleObject.restype = ctypes.c_uint
    _kernel32.CloseHandle.argtypes = (ctypes.c_void_p,)
    _kernel32.CloseHandle.restype = ctypes.c_bool

    # SetThreadExecutionState — held by the detached inhibitor child.
    _kernel32.SetThreadExecutionState.argtypes = (ctypes.c_uint,)
    _kernel32.SetThreadExecutionState.restype = ctypes.c_uint

    HWND_BROADCAST   = ctypes.c_void_p(0xFFFF)
    WM_SYSCOMMAND    = 0x0112
    SC_MONITORPOWER  = 0xF170
    MONITOR_OFF      = 2
    PROCESS_TERMINATE = 0x0001
    SYNCHRONIZE       = 0x00100000
    WAIT_TIMEOUT      = 0x00000102  # handle still signalled => process alive


class WindowsBackend(PlatformBackend):

    def lock_session(self) -> None:
        try:
            _user32.LockWorkStation()
        except Exception:
            pass  # best-effort, matches PowerShell version

    def blank_display(self) -> bool:
        try:
            _user32.SendMessageW(
                HWND_BROADCAST, WM_SYSCOMMAND, SC_MONITORPOWER, MONITOR_OFF,
            )
            return True
        except Exception:
            return False

    def notify(self, title: str, body: str) -> None:
        # Try winrt for proper toast first (matches the old PowerShell
        # path). If unavailable, fall back to a single PowerShell line
        # using the same Windows.UI.Notifications API.
        try:
            self._notify_winrt(title, body)
            return
        except Exception:
            pass
        self._notify_powershell(title, body)

    def _notify_winrt(self, title: str, body: str) -> None:
        # Lazy import; winrt is optional ([windows] extra).
        from winrt.windows.ui.notifications import (
            ToastNotification, ToastNotificationManager,
        )
        from winrt.windows.data.xml.dom import XmlDocument

        xml = (
            f"<toast><visual><binding template='ToastGeneric'>"
            f"<text>{_xml_escape(title)}</text>"
            f"<text>{_xml_escape(body)}</text>"
            f"</binding></visual></toast>"
        )
        doc = XmlDocument()
        doc.load_xml(xml)
        notifier = ToastNotificationManager.create_toast_notifier(
            "BedtimeLockdown.Notifier"
        )
        notifier.show(ToastNotification(doc))

    def _notify_powershell(self, title: str, body: str) -> None:
        ps = (
            "[Windows.UI.Notifications.ToastNotificationManager,"
            "Windows.UI.Notifications,ContentType=WindowsRuntime]>$null;"
            "[Windows.Data.Xml.Dom.XmlDocument,"
            "Windows.Data.Xml.Dom.XmlDocument,ContentType=WindowsRuntime]>$null;"
            f"$xml=[xml]'<toast><visual><binding template=\"ToastGeneric\">"
            f"<text>{_ps_escape(title)}</text>"
            f"<text>{_ps_escape(body)}</text>"
            f"</binding></visual></toast>';"
            "$d=New-Object Windows.Data.Xml.Dom.XmlDocument;$d.LoadXml($xml.OuterXml);"
            "$n=[Windows.UI.Notifications.ToastNotificationManager]::"
            "CreateToastNotifier('BedtimeLockdown.Notifier');"
            "$n.Show([Windows.UI.Notifications.ToastNotification]::new($d))"
        )
        subprocess.run(
            ["powershell", "-NoProfile", "-Command", ps],
            capture_output=True,
        )

    def spawn_inhibit_idle_sleep(self, duration_sec: int, reason: str) -> int:
        # Re-exec ourselves into the hidden inhibitor helper command. The
        # child sets the ES_SYSTEM_REQUIRED execution-state flag and
        # sleeps for `duration_sec`; on exit, the flag clears.
        creationflags = 0x00000008  # DETACHED_PROCESS — no console window
        proc = subprocess.Popen(
            [sys.executable, "-m", "sleep_lockdown.agent",
             "--internal-inhibit", str(duration_sec)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=creationflags,
            close_fds=True,
        )
        return proc.pid

    def kill_pid(self, pid: int) -> None:
        h = _kernel32.OpenProcess(PROCESS_TERMINATE, False, pid)
        if not h:
            return
        try:
            _kernel32.TerminateProcess(h, 0)
        finally:
            _kernel32.CloseHandle(h)

    def pid_alive(self, pid: int) -> bool:
        # SYNCHRONIZE is enough to wait on the handle. A zero-timeout wait
        # returns WAIT_TIMEOUT while the process runs and WAIT_OBJECT_0 (0)
        # once it has exited. A null handle means it's already gone.
        h = _kernel32.OpenProcess(SYNCHRONIZE, False, pid)
        if not h:
            return False
        try:
            return _kernel32.WaitForSingleObject(h, 0) == WAIT_TIMEOUT
        finally:
            _kernel32.CloseHandle(h)

    @contextmanager
    def acquire_single_writer_lock(self, name: str):
        # msvcrt.locking is the Windows equivalent of fcntl.flock for a
        # file region. Non-blocking exclusive lock on byte 0 of the lock
        # file; raises OSError if held by another process — we re-raise
        # as BlockingIOError so callers can use one except clause.
        import msvcrt

        state_dir().mkdir(parents=True, exist_ok=True)
        lock_path: Path = state_dir() / f"{name}.lock"
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
        try:
            try:
                msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
            except OSError as e:
                os.close(fd)
                raise BlockingIOError(str(e)) from e
            yield
        finally:
            try:
                os.lseek(fd, 0, 0)
                msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
            except OSError:
                pass
            os.close(fd)


# --- helpers --------------------------------------------------------------

def _xml_escape(s: str) -> str:
    return (s.replace("&", "&amp;")
             .replace("<", "&lt;")
             .replace(">", "&gt;")
             .replace('"', "&quot;")
             .replace("'", "&apos;"))


def _ps_escape(s: str) -> str:
    # Both XML-escape and PowerShell-string-escape (single-quote → double).
    return _xml_escape(s).replace("'", "''")


ES_CONTINUOUS       = 0x80000000
ES_SYSTEM_REQUIRED  = 0x00000001


def hold_execution_state(duration_sec: int) -> None:
    """Internal: invoked by `sleep-agent --internal-inhibit N` in a
    detached child. Sets ES_SYSTEM_REQUIRED + ES_CONTINUOUS, sleeps,
    then clears it. The OS treats the flag as held until cleared or
    the thread exits."""
    import time as _time

    _kernel32.SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)
    try:
        _time.sleep(duration_sec)
    finally:
        _kernel32.SetThreadExecutionState(ES_CONTINUOUS)
