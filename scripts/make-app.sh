#!/bin/bash
# Builds build/DeskSwitch.app from the release binary. Ad-hoc signed (home use).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/DeskSwitch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/deskswitch "$APP/Contents/MacOS/deskswitch"
cp packaging/Info.plist "$APP/Contents/Info.plist"
# Task 19 adds: mkdir -p "$APP/Contents/Library/LaunchAgents" + LaunchAgent plist copy
codesign --force --sign - "$APP"
echo "Built $APP — copy to /Applications on both Macs"
