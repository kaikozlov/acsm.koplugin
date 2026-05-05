#!/bin/bash
# Run ACSM plugin tests inside a headless KOReader environment.
#
# Usage:
#   ./test/headless_test.sh
#
# Requires KOReader at /Applications/KOReader.app (macOS)
# or set KOREADER_DIR to point to a KOReader installation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -z "${KOREADER_DIR:-}" ]; then
    if [ -d "/Applications/KOReader.app/Contents/koreader" ]; then
        KOREADER_DIR="/Applications/KOReader.app/Contents/koreader"
    fi
fi

if [ -z "${KOREADER_DIR:-}" ]; then
    echo "Error: Cannot find KOReader installation."
    echo "Set KOREADER_DIR or install KOReader.app to /Applications/"
    exit 1
fi

echo "[headless] Using KOReader at: $KOREADER_DIR"

cd "$KOREADER_DIR"
exec ./luajit "$PLUGIN_ROOT/test/headless.lua" "$@"
