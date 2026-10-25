#!/usr/bin/env bash
# Installs (or updates) Display Monk in /Applications and opens it:
#   curl -fsSL https://alwinovungal.github.io/Display-Monk/install.sh | bash
# Files downloaded with curl carry no quarantine flag, so macOS opens the app without the
# "can't be opened" prompt that browser downloads of unnotarized apps get.
set -euo pipefail

REPO="AlwinOvungal/Display-Monk"
ZIP_URL="https://github.com/$REPO/releases/latest/download/DisplayMonk.zip"
APP_NAME="Display Monk.app"
DEST="/Applications/$APP_NAME"
BUNDLE_ID="app.displaymonk.DisplayMonk"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "Display Monk runs on macOS only."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 13 ] || fail "Display Monk needs macOS 13 Ventura or later."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say "Downloading the latest Display Monk"
curl -fL --progress-bar -o "$TMP/DisplayMonk.zip" "$ZIP_URL" || fail "The download failed. Check your connection and try again."
ditto -x -k "$TMP/DisplayMonk.zip" "$TMP/app" || fail "The download is damaged. Try again."

NEW="$TMP/app/$APP_NAME"
[ -d "$NEW" ] || fail "The download doesn't contain $APP_NAME."
id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$NEW/Contents/Info.plist" 2>/dev/null || true)"
[ "$id" = "$BUNDLE_ID" ] || fail "The download isn't Display Monk."
codesign --verify --deep --strict "$NEW" 2>/dev/null || fail "The app's signature doesn't check out. Try again."
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$NEW/Contents/Info.plist")"

if pgrep -x DisplayMonk >/dev/null; then
  say "Quitting the running Display Monk"
  osascript -e 'quit app "Display Monk"' >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do pgrep -x DisplayMonk >/dev/null || break; sleep 0.25; done
  pkill -x DisplayMonk 2>/dev/null || true
fi

SUDO=""
if [ ! -w /Applications ] || { [ -e "$DEST" ] && [ ! -w "$DEST" ]; }; then
  say "Your password is needed to write to /Applications"
  SUDO="sudo"
fi

say "Installing Display Monk $version in /Applications"
$SUDO rm -rf "$DEST"
$SUDO ditto "$NEW" "$DEST"
$SUDO xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

open "$DEST"
say "Done. Display Monk is in your menu bar."
echo "    Using the brightness or volume key options? After an update, re-add Display Monk under"
echo "    System Settings > Privacy & Security > Accessibility (remove it with -, add it with +)."
