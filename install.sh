#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
BINDIR="$PREFIX/bin"
TARGET="$BINDIR/airplay-tv"

cd "$(dirname "$0")"

swift build -c release

mkdir -p "$BINDIR"
install -m 0755 ".build/release/airplay-tv" "$TARGET"

echo "Installed: $TARGET"
echo "Next: run 'airplay-tv setup' and grant Accessibility permission."
