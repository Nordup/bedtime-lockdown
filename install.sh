#!/usr/bin/env bash
# Bootstrap. The real installer is install.py.
set -euo pipefail
cd "$(dirname "$0")"
exec python3 install.py "$@"
