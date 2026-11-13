#!/bin/bash
# make_app.sh — build VanishCamApp in release mode and assemble build/VanishCam.app, then open it.
# Usage: scripts/make_app.sh [--no-open]
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/VanishCam.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/VanishCamApp "$APP/Contents/MacOS/VanishCamApp"
cp Sources/VanishCamApp/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources" && cp Assets/* "$APP/Contents/Resources/"
codesign --force --deep --sign - "$APP"

if [ "${1:-}" != "--no-open" ]; then
    open "$APP"
else
    echo "built: $APP"
fi
