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
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp packaging/com.vuphan.deskswitch.plist "$APP/Contents/Library/LaunchAgents/"
codesign --force --sign - "$APP"
echo "Built $APP — copy to /Applications on both Macs"
