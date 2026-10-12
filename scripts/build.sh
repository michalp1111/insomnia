#!/bin/bash
# Usage: scripts/build.sh [debug|release] [--install]
set -eo pipefail
cd "$(dirname "$0")/.."

CONFIG=${1:-debug}
OUT=build/$CONFIG
APP=$OUT/Insomnia.app
mkdir -p "$OUT"

FLAGS=(-sdk "$(xcrun --show-sdk-path)")

# Older Command Line Tools installs can leave a stale module map behind that
# redefines SwiftBridging and breaks every import. Hide it if it is still there.
STALE=/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
if [ -f "$STALE" ] && [ -f "${STALE%/*}/bridging.modulemap" ]; then
  : > build/empty.modulemap
  cat > build/vfs.yaml <<YAML
{ "version": 0, "roots": [ { "name": "${STALE%/*}", "type": "directory", "contents": [
  { "name": "module.modulemap", "type": "file", "external-contents": "$PWD/build/empty.modulemap" } ] } ] }
YAML
  FLAGS+=(-vfsoverlay "$PWD/build/vfs.yaml")
fi

if [ ! -f Resources/AppIcon.icns ]; then
  swiftc "${FLAGS[@]}" scripts/make-icon.swift -o build/make-icon
  build/make-icon
fi

FLAGS+=(-parse-as-library -module-name Insomnia -swift-version 6)
# Swift 6 reports many concurrency bugs as warnings. CI fails on them; a local
# build does not, so a newer compiler's new warnings never block one.
[ "$CI" = true ] && FLAGS+=(-warnings-as-errors)
if [ "$CONFIG" = release ]; then
  FLAGS+=(-O -whole-module-optimization)
  ARCHS=(arm64 x86_64)
else
  FLAGS+=(-Onone -g -D DEBUG)
  ARCHS=(arm64)
fi

BINARIES=()
for ARCH in "${ARCHS[@]}"; do
  swiftc "${FLAGS[@]}" -target "$ARCH-apple-macosx14.0" Sources/*.swift -o "$OUT/Insomnia-$ARCH"
  BINARIES+=("$OUT/Insomnia-$ARCH")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/Insomnia"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/ "$APP/Contents/Resources/"
codesign --force --sign - --identifier com.michalptacek.insomnia "$APP"

if [ "$2" = --install ]; then
  pkill -x Insomnia 2>/dev/null && sleep 1 || true
  rm -rf /Applications/Insomnia.app
  cp -R "$APP" /Applications/Insomnia.app
  open /Applications/Insomnia.app
  echo "Installed /Applications/Insomnia.app"
else
  echo "Built $APP"
fi
