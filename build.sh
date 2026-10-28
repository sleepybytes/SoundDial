#!/usr/bin/env bash
# Builds SoundDial.app into ./build and signs it.
#   ./build.sh            release build
#   ./build.sh install    also copies it to /Applications (needed for "Launch at login")
# SIGN_IDENTITY overrides the signing identity (defaults to your first "Apple Development"
# certificate, falling back to ad-hoc). A stable identity keeps the audio permission across rebuilds.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP=build/SoundDial.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SoundDial" "$APP/Contents/MacOS/SoundDial"
cp Resources/Info.plist "$APP/Contents/Info.plist"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "install" ]]; then
  pkill -x SoundDial || true
  rm -rf /Applications/SoundDial.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/SoundDial.app"
fi
