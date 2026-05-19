"""Shared pytest fixtures. The state_dir() lookup honors SLEEP_HOME, so
overriding it per-test gives us isolated state without monkeypatching."""

import os

import pytest


@pytest.fixture
def state_home(tmp_path, monkeypatch):
    """Point sleep_lockdown.config.state_dir() at a fresh tmp dir."""
    monkeypatch.setenv("SLEEP_HOME", str(tmp_path))
    return tmp_path
