#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/mousevoice-build.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/MouseVoice.app"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp Resources/MouseVoice.icns "$APP/Contents/Resources/MouseVoice.icns"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" \
  -framework AppKit -framework CoreGraphics -framework ApplicationServices \
  Sources/HoldDetector.swift Sources/KeyOutput.swift Sources/main.swift \
  -o "$APP/Contents/MacOS/MouseVoice"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier local.alan.MouseVoice "$APP"
codesign --verify --deep --strict "$APP"
# Keep a clean signed copy: File Provider may reattach metadata after copying a .app.
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$PWD/MouseVoice.app.zip"
printf 'Clean signed archive: %s\n' "$PWD/MouseVoice.app.zip"
