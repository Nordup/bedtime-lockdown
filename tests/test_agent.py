"""Behavioral tests for sleep-agent's re-assert path: running `sleep-agent`
again while agent-mode is already active must re-lock + re-blank the
screen (so the user can put the display back to sleep after any key woke
it), revive a dead idle-suspend inhibitor, and never shorten the existing
until-epoch.

Uses a fake backend so no real OS side effects fire.
"""

import pytest

from sleep_lockdown import agent, common


class FakeBackend:
    """Records side-effect calls instead of touching the OS."""

    def __init__(self, *, pid_alive=True, blank_ok=True):
        self._pid_alive = pid_alive
        self._blank_ok = blank_ok
        self.locked = 0
        self.blanked = 0
        self.spawned = []          # list of (duration_sec, reason)
        self.next_pid = 4242

    def lock_session(self):
        self.locked += 1

    def blank_display(self):
        self.blanked += 1
        return self._blank_ok

    def spawn_inhibit_idle_sleep(self, duration_sec, reason):
        self.spawned.append((duration_sec, reason))
        return self.next_pid

    def pid_alive(self, pid):
        return self._pid_alive


@pytest.fixture
def fake_backend(monkeypatch):
    fb = FakeBackend()
    monkeypatch.setattr(agent, "backend", fb)
    return fb


def _arm_active_agent_mode(state_home, now, *, pid="1234"):
    """Write the on-disk state for an already-active agent-mode ending an
    hour from `now`, with a pinned inhibitor PID."""
    until = now + 3600
    common.agent_until_path().write_text(str(until))
    common.agent_inhibit_pid_path().write_text(pid)
    return until


def test_reassert_relocks_and_reblanks(state_home, fake_backend):
    now = 1700000000
    _arm_active_agent_mode(state_home, now)

    rc = agent._activate(now, "bedtime")

    assert rc == 0
    assert fake_backend.locked == 1
    assert fake_backend.blanked == 1


def test_reassert_keeps_until_unchanged(state_home, fake_backend):
    now = 1700000000
    until = _arm_active_agent_mode(state_home, now)

    agent._activate(now, "bedtime")

    # Re-enabling must never move the deadline.
    assert common.read_until_epoch(common.agent_until_path()) == until


def test_reassert_revives_dead_inhibitor(state_home, monkeypatch):
    fb = FakeBackend(pid_alive=False)
    monkeypatch.setattr(agent, "backend", fb)
    now = 1700000000
    until = _arm_active_agent_mode(state_home, now, pid="9999")

    agent._activate(now, "bedtime")

    # Dead inhibitor => respawned for exactly the remaining time, and the
    # new PID is pinned.
    assert len(fb.spawned) == 1
    duration, _reason = fb.spawned[0]
    assert duration == until - now
    assert common.agent_inhibit_pid_path().read_text() == str(fb.next_pid)


def test_reassert_leaves_live_inhibitor_alone(state_home, monkeypatch):
    fb = FakeBackend(pid_alive=True)
    monkeypatch.setattr(agent, "backend", fb)
    now = 1700000000
    _arm_active_agent_mode(state_home, now, pid="1234")

    agent._activate(now, "bedtime")

    # Live inhibitor => no second process, PID file untouched.
    assert fb.spawned == []
    assert common.agent_inhibit_pid_path().read_text() == "1234"


def test_reassert_reports_lock_only_when_not_blanked(state_home, monkeypatch, capsys):
    # Linux can't blank on GNOME 50 (lock-only). The message must say so,
    # and must NOT print the old scary "could not blank" warning.
    fb = FakeBackend(blank_ok=False)
    monkeypatch.setattr(agent, "backend", fb)
    now = 1700000000
    _arm_active_agent_mode(state_home, now)

    rc = agent._activate(now, "bedtime")

    assert rc == 0
    assert fb.locked == 1
    out = capsys.readouterr()
    assert "could not blank" not in (out.out + out.err)
    assert "Screen locked" in out.out


def test_reassert_reports_display_off_when_blanked(state_home, monkeypatch, capsys):
    # Windows actually blanks: the message should reflect the dark screen.
    fb = FakeBackend(blank_ok=True)
    monkeypatch.setattr(agent, "backend", fb)
    now = 1700000000
    _arm_active_agent_mode(state_home, now)

    agent._activate(now, "bedtime")

    assert "Display off" in capsys.readouterr().out
