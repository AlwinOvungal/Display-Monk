#!/usr/bin/env bash
# Builds a universal (arm64 + x86_64) release and packages it:
#   build/Display Monk.app   the menu bar app (ad-hoc signed)
#   build/DisplayMonk.zip    the app, zipped for distribution
#   build/DisplayMonk.dmg    the app on a disk image, with an Applications shortcut
#   build/displaymonk        the command-line tool
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.2.0}"
ARCH_FLAGS=(--arch arm64 --arch x86_64)

swift build -c release "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

APP="build/Display Monk.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DisplayMonkApp" "$APP/Contents/MacOS/DisplayMonk"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN_DIR/displaymonk" build/displaymonk

# Ad-hoc signatures: enough to run locally. Downloaded copies need right-click > Open the first time.
codesign --force --sign - "$APP"
codesign --force --sign - build/displaymonk

(cd build && ditto -c -k --keepParent "Display Monk.app" DisplayMonk.zip)

# Drag-and-drop install: the app next to a shortcut to /Applications.
DMG_ROOT="build/dmg"
mkdir -p "$DMG_ROOT"
ditto "$APP" "$DMG_ROOT/Display Monk.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname "Display Monk" -srcfolder "$DMG_ROOT" -fs HFS+ -format UDZO -ov build/DisplayMonk.dmg
rm -rf "$DMG_ROOT"
echo "Built $APP, build/DisplayMonk.zip, build/DisplayMonk.dmg and build/displaymonk"
