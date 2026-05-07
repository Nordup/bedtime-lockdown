#!/usr/bin/env bash
set -euo pipefail

BIN_DIR="$HOME/.local/bin"
LIB_DIR="$HOME/.local/share/sleep"
UNIT_DIR="$HOME/.config/systemd/user"

systemctl --user disable --now \
    sleep-warn-15.timer \
    sleep-warn-5.timer \
    sleep-enforce.timer 2>/dev/null || true

rm -f \
    "$UNIT_DIR/sleep-warn-15.service" \
    "$UNIT_DIR/sleep-warn-15.timer" \
    "$UNIT_DIR/sleep-warn-5.service" \
    "$UNIT_DIR/sleep-warn-5.timer" \
    "$UNIT_DIR/sleep-enforce.service" \
    "$UNIT_DIR/sleep-enforce.timer"

rm -f \
    "$BIN_DIR/sleep-warn" \
    "$BIN_DIR/sleep-enforce" \
    "$BIN_DIR/sleep-override" \
    "$BIN_DIR/sleep-status" \
    "$LIB_DIR/sleep-common.sh"

rmdir "$LIB_DIR" 2>/dev/null || true

systemctl --user daemon-reload

echo "Uninstalled. State directory ~/.config/sleep was left intact (logs preserved)."
echo "Remove manually with: rm -rf ~/.config/sleep"
