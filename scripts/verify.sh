#!/bin/bash
# Usage: scripts/verify.sh [path/to/Insomnia.app]
# Checks what a broken release would get wrong without failing the compile.
set -eo pipefail
cd "$(dirname "$0")/.."

APP=${1:-build/release/Insomnia.app}
BIN=$APP/Contents/MacOS/Insomnia
PLIST=$APP/Contents/Info.plist

plutil -lint "$PLIST"
codesign --verify --strict "$APP"

ARCHS=$(lipo -archs "$BIN")
for ARCH in arm64 x86_64; do
  [[ " $ARCHS " == *" $ARCH "* ]] || { echo "missing $ARCH in $BIN (has: $ARCHS)"; exit 1; }
done

PLIST_MIN=$(plutil -extract LSMinimumSystemVersion raw "$PLIST")
for ARCH in $ARCHS; do
  BIN_MIN=$(vtool -arch "$ARCH" -show-build "$BIN" | awk '/minos/ { print $2 }')
  [ "$BIN_MIN" = "$PLIST_MIN" ] || { echo "$ARCH needs macOS $BIN_MIN, Info.plist says $PLIST_MIN"; exit 1; }
done

echo "Verified $APP ($ARCHS, macOS $PLIST_MIN+)"
