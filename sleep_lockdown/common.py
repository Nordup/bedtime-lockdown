"""Pure logic helpers: window detection, override/agent state, cooldown.

No side effects, no platform calls. Mirrors lib/sleep-common.sh + .ps1
from the previous bash/PowerShell era.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional

from .config import (
    COOLDOWN_SEC,
    DINNER_END_HHMM,
    DINNER_START_HHMM,
    LOCKDOWN_END_HHMM,
    LOCKDOWN_START_HHMM,
    LUNCH_END_HHMM,
    LUNCH_START_HHMM,
    state_dir,
)

WINDOWS = ("bedtime", "lunch", "dinner")  # canonical names


def parse_hhmm(hhmm: str | int) -> int:
    """Return the integer HHMM, or raise ValueError on malformed input.

    Accepts strings like "2130" / "0600" / 600 (without leading zero).
    Rejects anything that isn't a 1-4 digit integer in [0, 2359].
    """
    if isinstance(hhmm, int):
        if hhmm < 0 or hhmm > 2359:
            raise ValueError(f"out of range: {hhmm}")
        return hhmm
    s = str(hhmm)
    if not s.isdigit() or len(s) > 4:
        raise ValueError(f"malformed HHMM: {hhmm!r}")
    n = int(s)
    if n < 0 or n > 2359:
        raise ValueError(f"out of range: {n}")
    if (n % 100) >= 60:
        raise ValueError(f"invalid minute component: {n}")
    return n


def is_in_lockdown_window(hhmm: str | int) -> bool:
    """Bedtime: 21:00 .. 06:00 (crosses midnight). Start inclusive, end exclusive."""
    n = parse_hhmm(hhmm)
    return n >= LOCKDOWN_START_HHMM or n < LOCKDOWN_END_HHMM


def is_in_window(hhmm: str | int, start: int, end: int) -> bool:
    """Generic same-day window check: start inclusive, end exclusive."""
    n = parse_hhmm(hhmm)
    return start <= n < end


def current_window(hhmm: str | int) -> str:
    """Returns 'bedtime' / 'lunch' / 'dinner' / 'none'.

    Bedtime takes priority on overlap (defaults don't overlap; defensive).
    """
    if is_in_lockdown_window(hhmm):
        return "bedtime"
    if is_in_window(hhmm, LUNCH_START_HHMM, LUNCH_END_HHMM):
        return "lunch"
    if is_in_window(hhmm, DINNER_START_HHMM, DINNER_END_HHMM):
        return "dinner"
    return "none"


def _window_suffix(window: str) -> str:
    """Filename suffix for per-window state. Bedtime keeps the empty suffix
    so the existing install's filenames (override-until, overrides.log)
    survive a migration from the bash era."""
    if window == "bedtime":
        return ""
    if window == "lunch":
        return "-lunch"
    if window == "dinner":
        return "-dinner"
    raise ValueError(f"unknown window: {window}")


def override_until_path(window: str) -> Path:
    return state_dir() / f"override-until{_window_suffix(window)}"


def overrides_log_path(window: str) -> Path:
    return state_dir() / f"overrides{_window_suffix(window)}.log"


def agent_until_path() -> Path:
    return state_dir() / "agent-until"


def agent_log_path() -> Path:
    return state_dir() / "agent.log"


def agent_inhibit_pid_path() -> Path:
    return state_dir() / "agent-inhibit.pid"


def enforce_log_path() -> Path:
    return state_dir() / "enforce.log"


def _read_epoch_file(path: Path) -> Optional[int]:
    """Read a file containing a single integer epoch. Returns None on any
    failure (missing, empty, non-numeric) — fail closed."""
    try:
        raw = path.read_text().strip()
    except (FileNotFoundError, PermissionError):
        return None
    if not raw.isdigit():
        return None
    return int(raw)


def override_active(now_epoch: Optional[int] = None, window: str = "bedtime") -> bool:
    """Per-window override active iff override-until file exists and contains
    a numeric epoch strictly greater than now."""
    if now_epoch is None:
        now_epoch = int(time.time())
    until = _read_epoch_file(override_until_path(window))
    return until is not None and until > now_epoch


def agent_mode_active(now_epoch: Optional[int] = None) -> bool:
    """Agent-mode bypasses every window — display blanked, PC awake, idle-
    suspend inhibited. Single global state; not per-window."""
    if now_epoch is None:
        now_epoch = int(time.time())
    until = _read_epoch_file(agent_until_path())
    return until is not None and until > now_epoch


@dataclass
class CooldownResult:
    """Either remaining > 0 (cooldown still in effect) or 0 (ready)."""
    remaining: int
    corrupted: bool = False  # true if the last log entry was unparseable


def _read_last_log_timestamp(path: Path) -> Optional[int]:
    """Read last line of a TSV log, parse the first field as ISO timestamp,
    return epoch seconds. Returns None if file missing/empty. Raises
    ValueError if the timestamp is corrupted (caller decides what to do)."""
    try:
        if not path.exists() or path.stat().st_size == 0:
            return None
        with path.open("r") as f:
            last_line = ""
            for line in f:
                if line.strip():
                    last_line = line
            if not last_line:
                return None
            iso = last_line.split("\t", 1)[0].strip()
    except (FileNotFoundError, PermissionError):
        return None

    # Python 3.11+ fromisoformat handles most ISO variants. For older
    # versions and edge cases (trailing 'Z'), strip 'Z' -> '+00:00'.
    iso_norm = iso.replace("Z", "+00:00") if iso.endswith("Z") else iso
    try:
        dt = datetime.fromisoformat(iso_norm)
    except ValueError as e:
        raise ValueError(f"corrupted timestamp: {iso!r}") from e
    return int(dt.timestamp())


def cooldown_remaining(now_epoch: int, window: str = "bedtime") -> CooldownResult:
    """Seconds remaining in the per-window override cooldown.

    Fail-closed: if the log's last timestamp is corrupted, returns the
    full COOLDOWN_SEC and flags corrupted=True so the caller can warn.
    """
    path = overrides_log_path(window)
    try:
        last = _read_last_log_timestamp(path)
    except ValueError:
        return CooldownResult(remaining=COOLDOWN_SEC, corrupted=True)
    if last is None:
        return CooldownResult(remaining=0)
    elapsed = now_epoch - last
    remaining = COOLDOWN_SEC - elapsed
    return CooldownResult(remaining=max(0, remaining))


def format_hm(seconds: int) -> str:
    """Truncates to HH:MM. e.g. 5430 -> '01:30', 43199 -> '11:59'."""
    h = seconds // 3600
    m = (seconds % 3600) // 60
    return f"{h:02d}:{m:02d}"


def format_hhmm_as_clock(hhmm: int) -> str:
    """2130 -> '21:30', 600 -> '06:00', 0 -> '00:00'."""
    padded = f"{hhmm:04d}"
    return f"{padded[:2]}:{padded[2:]}"


def window_end_epoch(window: str, now_epoch: int) -> int:
    """Epoch second at which the given window ends, resolved relative to
    the local date of now_epoch. If the same-day end has already passed,
    rolls forward by 24h (normal for bedtime, which crosses midnight)."""
    if window == "lunch":
        end_hhmm = LUNCH_END_HHMM
    elif window == "dinner":
        end_hhmm = DINNER_END_HHMM
    elif window == "bedtime":
        end_hhmm = LOCKDOWN_END_HHMM
    else:
        raise ValueError(f"unknown window: {window}")

    hh, mm = end_hhmm // 100, end_hhmm % 100
    now_dt = datetime.fromtimestamp(now_epoch)
    end_dt = now_dt.replace(hour=hh, minute=mm, second=0, microsecond=0)
    end = int(end_dt.timestamp())
    if end <= now_epoch:
        end += 86400
    return end


def current_hhmm() -> int:
    """Current local time as HHMM int."""
    now = datetime.now()
    return now.hour * 100 + now.minute


def now_iso() -> str:
    """Current local time as ISO-8601 with offset (matches `date -Iseconds`)."""
    return datetime.now().astimezone().isoformat(timespec="seconds")
