"""Pytest port of the original bats suite, with the same coverage and
the same fail-closed semantics. Pure-logic only — no platform side
effects."""

from datetime import datetime, timezone

import pytest

from sleep_lockdown import common
from sleep_lockdown.config import COOLDOWN_SEC


# ---- is_in_lockdown_window ---------------------------------------------

@pytest.mark.parametrize("hhmm,expected", [
    (2100, True),   # start inclusive
    (2130, True),
    (2359, True),
    (   0, True),   # across midnight
    ( 559, True),
    ( 600, False),  # end exclusive
    (2059, False),  # just before
    (1200, False),
])
def test_is_in_lockdown_window(hhmm, expected):
    assert common.is_in_lockdown_window(hhmm) is expected


@pytest.mark.parametrize("bad", ["", "abcd", "99999", "12:00"])
def test_is_in_lockdown_window_malformed_raises(bad):
    with pytest.raises(ValueError):
        common.is_in_lockdown_window(bad)


# ---- is_in_window ------------------------------------------------------

def test_is_in_window_lunch():
    from sleep_lockdown.config import LUNCH_START_HHMM, LUNCH_END_HHMM
    assert common.is_in_window(1130, LUNCH_START_HHMM, LUNCH_END_HHMM)
    assert not common.is_in_window(1215, LUNCH_START_HHMM, LUNCH_END_HHMM)
    assert common.is_in_window(1214, LUNCH_START_HHMM, LUNCH_END_HHMM)
    assert not common.is_in_window(1129, LUNCH_START_HHMM, LUNCH_END_HHMM)


def test_is_in_window_dinner():
    from sleep_lockdown.config import DINNER_START_HHMM, DINNER_END_HHMM
    assert common.is_in_window(1630, DINNER_START_HHMM, DINNER_END_HHMM)
    assert not common.is_in_window(1830, DINNER_START_HHMM, DINNER_END_HHMM)


# ---- current_window ----------------------------------------------------

@pytest.mark.parametrize("hhmm,expected", [
    (2200, "bedtime"),
    ( 300, "bedtime"),   # across midnight
    (1130, "lunch"),     # start
    (1214, "lunch"),     # last minute
    (1215, "none"),      # end exclusive
    (1630, "dinner"),    # start
    (1829, "dinner"),
    (1830, "none"),      # end exclusive
    (1000, "none"),
    (1300, "none"),      # between lunch and dinner
    (1900, "none"),      # between dinner and bedtime
])
def test_current_window(hhmm, expected):
    assert common.current_window(hhmm) == expected


# ---- read_until_epoch (the shared until-file reader) -------------------

def test_read_until_epoch_missing_file_returns_none(state_home):
    assert common.read_until_epoch(state_home / "nope") is None


def test_read_until_epoch_empty_file_returns_none(state_home):
    p = state_home / "agent-until"
    p.write_text("")
    assert common.read_until_epoch(p) is None


def test_read_until_epoch_non_numeric_returns_none(state_home):
    p = state_home / "agent-until"
    p.write_text("not-a-number")
    assert common.read_until_epoch(p) is None


def test_read_until_epoch_valid(state_home):
    p = state_home / "agent-until"
    p.write_text("1700000060\n")  # trailing newline is stripped
    assert common.read_until_epoch(p) == 1700000060


# ---- agent / enforce path helpers -------------------------------------

def test_agent_until_path(state_home):
    assert common.agent_until_path() == state_home / "agent-until"


def test_agent_log_path(state_home):
    assert common.agent_log_path() == state_home / "agent.log"


def test_agent_inhibit_pid_path(state_home):
    assert common.agent_inhibit_pid_path() == state_home / "agent-inhibit.pid"


def test_enforce_log_path(state_home):
    assert common.enforce_log_path() == state_home / "enforce.log"


# ---- override_until_path / overrides_log_path --------------------------

def test_override_until_path_keeps_historical_filenames(state_home):
    # Bedtime keeps the empty suffix so existing bash-era installs migrate
    # without losing state.
    assert common.override_until_path("bedtime") == state_home / "override-until"
    assert common.override_until_path("lunch")   == state_home / "override-until-lunch"
    assert common.override_until_path("dinner")  == state_home / "override-until-dinner"


def test_override_until_path_unknown_window_raises():
    with pytest.raises(ValueError):
        common.override_until_path("bogus")


def test_overrides_log_path(state_home):
    assert common.overrides_log_path("bedtime") == state_home / "overrides.log"
    assert common.overrides_log_path("lunch")   == state_home / "overrides-lunch.log"
    assert common.overrides_log_path("dinner")  == state_home / "overrides-dinner.log"


# ---- override_active ---------------------------------------------------

def test_override_active_missing_file(state_home):
    assert not common.override_active(1700000000, "lunch")


def test_override_active_until_greater_than_now(state_home):
    # Repointed to lunch: bedtime no longer honors any reprieve, so the
    # "future until-file activates an override" path is tested on a window
    # that still permits overrides.
    (state_home / "override-until-lunch").write_text("1700000060")
    assert common.override_active(1700000000, "lunch")


def test_override_active_until_equal_to_now_is_false(state_home):
    # Strict > semantics — equal means expired this second.
    (state_home / "override-until-lunch").write_text("1700000000")
    assert not common.override_active(1700000000, "lunch")


def test_override_active_empty_file(state_home):
    (state_home / "override-until-lunch").write_text("")
    assert not common.override_active(1700000000, "lunch")


def test_override_active_non_numeric_garbage(state_home):
    (state_home / "override-until-lunch").write_text("not-a-number")
    assert not common.override_active(1700000000, "lunch")


def test_override_active_per_window_isolation(state_home):
    # Lunch override-until must NOT activate bedtime, and vice versa.
    (state_home / "override-until-lunch").write_text("1700000060")
    assert not common.override_active(1700000000, "bedtime")
    assert common.override_active(1700000000, "lunch")


def test_override_active_dinner_does_not_leak_to_lunch(state_home):
    (state_home / "override-until-dinner").write_text("1700000060")
    assert not common.override_active(1700000000, "lunch")
    assert common.override_active(1700000000, "dinner")


def test_override_enabled():
    assert common.override_enabled("lunch")
    assert common.override_enabled("dinner")
    assert not common.override_enabled("bedtime")


def test_override_active_bedtime_disabled_even_with_fresh_file(state_home):
    # Night is non-negotiable: a valid, future-dated reprieve file is ignored.
    (state_home / "override-until").write_text("1700000060")
    assert not common.override_active(1700000000, "bedtime")


# ---- cooldown_remaining ------------------------------------------------

def _write_iso_log(path, epoch):
    iso = datetime.fromtimestamp(epoch, tz=timezone.utc).isoformat(timespec="seconds")
    path.write_text(f"{iso}\ta\tb\tc\n")


def test_cooldown_remaining_missing_log(state_home):
    cd = common.cooldown_remaining(1700000000, "bedtime")
    assert cd.remaining == 0
    assert not cd.corrupted


def test_cooldown_remaining_within_window(state_home):
    _write_iso_log(state_home / "overrides.log", 1699999000)
    cd = common.cooldown_remaining(1700000000, "bedtime")
    # 12h - 1000s elapsed = 42200s remaining.
    assert cd.remaining == 42200


def test_cooldown_remaining_outside_window(state_home):
    _write_iso_log(state_home / "overrides.log", 1699956000)
    assert common.cooldown_remaining(1700000000, "bedtime").remaining == 0


def test_cooldown_remaining_at_exact_12h_boundary(state_home):
    _write_iso_log(state_home / "overrides.log", 1699956800)  # 12h before
    assert common.cooldown_remaining(1700000000, "bedtime").remaining == 0


def test_cooldown_remaining_reads_last_log_entry(state_home):
    p = state_home / "overrides.log"
    old_iso = datetime.fromtimestamp(1699000000, tz=timezone.utc).isoformat(timespec="seconds")
    new_iso = datetime.fromtimestamp(1699999000, tz=timezone.utc).isoformat(timespec="seconds")
    p.write_text(f"{old_iso}\told\told\told\n{new_iso}\tnew\tnew\tnew\n")
    cd = common.cooldown_remaining(1700000000, "bedtime")
    assert cd.remaining == 42200


def test_cooldown_remaining_corrupted_fails_closed(state_home):
    (state_home / "overrides.log").write_text("garbage-not-a-timestamp\ta\tb\tc\n")
    cd = common.cooldown_remaining(1700000000, "bedtime")
    assert cd.remaining == COOLDOWN_SEC
    assert cd.corrupted


def test_cooldown_remaining_per_window_isolation(state_home):
    _write_iso_log(state_home / "overrides-lunch.log", 1699999000)
    # Lunch log must not influence bedtime cooldown.
    assert common.cooldown_remaining(1700000000, "bedtime").remaining == 0
    assert common.cooldown_remaining(1700000000, "lunch").remaining == 42200
    assert common.cooldown_remaining(1700000000, "dinner").remaining == 0


# ---- agent_mode_active -------------------------------------------------

def test_agent_mode_missing_file(state_home):
    assert not common.agent_mode_active(1700000000)


def test_agent_mode_until_greater(state_home):
    (state_home / "agent-until").write_text("1700000060")
    assert common.agent_mode_active(1700000000)


def test_agent_mode_until_equal_is_false(state_home):
    (state_home / "agent-until").write_text("1700000000")
    assert not common.agent_mode_active(1700000000)


def test_agent_mode_empty_file(state_home):
    (state_home / "agent-until").write_text("")
    assert not common.agent_mode_active(1700000000)


def test_agent_mode_garbage(state_home):
    (state_home / "agent-until").write_text("not-a-number")
    assert not common.agent_mode_active(1700000000)


def test_agent_mode_ignores_override_files(state_home):
    # Per-window override files must not be confused with the global
    # agent-until file.
    (state_home / "override-until").write_text("1700000060")
    (state_home / "override-until-lunch").write_text("1700000060")
    assert not common.agent_mode_active(1700000000)


# ---- format helpers ----------------------------------------------------

@pytest.mark.parametrize("seconds,expected", [
    (0, "00:00"),
    (3600, "01:00"),
    (12 * 3600 - 1, "11:59"),
    (5430, "01:30"),
])
def test_format_hm(seconds, expected):
    assert common.format_hm(seconds) == expected


@pytest.mark.parametrize("hhmm,expected", [
    (2130, "21:30"),
    (600,  "06:00"),
    (0,    "00:00"),
])
def test_format_hhmm_as_clock(hhmm, expected):
    assert common.format_hhmm_as_clock(hhmm) == expected


# ---- window_end_epoch --------------------------------------------------

def test_window_end_epoch_lunch():
    now = int(datetime.now().replace(hour=11, minute=45, second=0, microsecond=0).timestamp())
    expected = int(datetime.now().replace(hour=12, minute=15, second=0, microsecond=0).timestamp())
    assert common.window_end_epoch("lunch", now) == expected


def test_window_end_epoch_dinner():
    now = int(datetime.now().replace(hour=17, minute=0, second=0, microsecond=0).timestamp())
    expected = int(datetime.now().replace(hour=18, minute=30, second=0, microsecond=0).timestamp())
    assert common.window_end_epoch("dinner", now) == expected


def test_window_end_epoch_bedtime_evening_rolls_to_tomorrow():
    base = datetime.now().replace(hour=22, minute=0, second=0, microsecond=0)
    now = int(base.timestamp())
    expected_dt = base.replace(hour=6, minute=0)
    expected = int(expected_dt.timestamp()) + 86400
    assert common.window_end_epoch("bedtime", now) == expected


def test_window_end_epoch_bedtime_after_midnight_same_day():
    base = datetime.now().replace(hour=3, minute=0, second=0, microsecond=0)
    now = int(base.timestamp())
    expected = int(base.replace(hour=6, minute=0).timestamp())
    assert common.window_end_epoch("bedtime", now) == expected


def test_window_end_epoch_unknown_window_raises():
    with pytest.raises(ValueError):
        common.window_end_epoch("bogus", 1700000000)
