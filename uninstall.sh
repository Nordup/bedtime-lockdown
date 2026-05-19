#!/usr/bin/env bash
# Bootstrap. The real uninstaller is uninstall.py.
set -euo pipefail
cd "$(dirname "$0")"
exec python3 uninstall.py "$@"
