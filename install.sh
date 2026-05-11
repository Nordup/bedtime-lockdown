#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.local/bin"
LIB_DIR="$HOME/.local/share/sleep"
UNIT_DIR="$HOME/.config/systemd/user"
STATE_DIR="$HOME/.config/sleep"

mkdir -p "$BIN_DIR" "$LIB_DIR" "$UNIT_DIR" "$STATE_DIR"

install -m 755 "$REPO_ROOT/bin/sleep-warn"      "$BIN_DIR/sleep-warn"
install -m 755 "$REPO_ROOT/bin/sleep-enforce"   "$BIN_DIR/sleep-enforce"
install -m 755 "$REPO_ROOT/bin/sleep-override"  "$BIN_DIR/sleep-override"
install -m 755 "$REPO_ROOT/bin/sleep-status"    "$BIN_DIR/sleep-status"

install -m 644 "$REPO_ROOT/lib/sleep-common.sh" "$LIB_DIR/sleep-common.sh"

install -m 644 "$REPO_ROOT/systemd/sleep-warn-15.service"         "$UNIT_DIR/sleep-warn-15.service"
install -m 644 "$REPO_ROOT/systemd/sleep-warn-15.timer"           "$UNIT_DIR/sleep-warn-15.timer"
install -m 644 "$REPO_ROOT/systemd/sleep-warn-5.service"          "$UNIT_DIR/sleep-warn-5.service"
install -m 644 "$REPO_ROOT/systemd/sleep-warn-5.timer"            "$UNIT_DIR/sleep-warn-5.timer"
install -m 644 "$REPO_ROOT/systemd/sleep-enforce.service"         "$UNIT_DIR/sleep-enforce.service"
install -m 644 "$REPO_ROOT/systemd/sleep-enforce.timer"           "$UNIT_DIR/sleep-enforce.timer"
install -m 644 "$REPO_ROOT/systemd/sleep-enforce-bedtime.timer"   "$UNIT_DIR/sleep-enforce-bedtime.timer"

systemctl --user daemon-reload
systemctl --user enable --now \
    sleep-warn-15.timer \
    sleep-warn-5.timer \
    sleep-enforce.timer \
    sleep-enforce-bedtime.timer

echo
echo "Installed. Active timers:"
systemctl --user list-timers --all | grep -E 'sleep-' || true
echo
echo "Run sleep-status to inspect state any time."
