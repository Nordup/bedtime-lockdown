"""Platform dispatch. Imports the OS-specific backend and exposes it as `backend`."""

import sys

from .base import PlatformBackend


def _select() -> PlatformBackend:
    if sys.platform == "win32":
        from . import windows
        return windows.WindowsBackend()
    # Linux + everything else (BSD etc.) gets the Linux backend; works
    # for any X11/Wayland desktop with the standard freedesktop tools.
    from . import linux
    return linux.LinuxBackend()


backend: PlatformBackend = _select()
