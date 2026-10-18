#!/bin/bash
# Builds Timelapse.app, installs it in ~/Applications and launches it.
# If capture fails after a rebuild even though the toggle in System Settings looks on
# (the ad-hoc signature changed), run:
#   tccutil reset ScreenCapture com.jorgetorres.timelapse
# and grant the permission again.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Timelapse.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 Timelapse.swift -o "$APP/Contents/MacOS/Timelapse"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force -s - "$APP"

pkill -x Timelapse || true
mkdir -p ~/Applications
rm -rf ~/Applications/Timelapse.app
cp -R "$APP" ~/Applications/
# Launch through LaunchServices so the permission is attributed to Timelapse, not Terminal.
open ~/Applications/Timelapse.app
echo "Timelapse.app instalado en ~/Applications"
