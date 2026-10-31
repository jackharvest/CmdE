#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="CmdE.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

swiftc main.swift -o "$APP/Contents/MacOS/CmdE"

codesign --force --deep --sign - "$APP"

echo "Built $APP"
