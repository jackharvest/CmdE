#!/bin/bash
# Builds CmdE.app and packages it into a distributable DMG with a custom background and a
# drag-to-Applications layout, plus the -app.zip the in-app updater installs. Every GitHub
# release must include both.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(plutil -extract CFBundleShortVersionString raw Info.plist)"
DMG_NAME="CmdE-${VERSION}.dmg"
ZIP_NAME="CmdE-${VERSION}-app.zip"

./build.sh

rm -f "$DMG_NAME" "$ZIP_NAME"

# dmgbuild (pure Python, writes .DS_Store directly) instead of create-dmg/Finder
# AppleScript automation — Finder has been unreliable about "background picture"
# assignments to icon view options on recent macOS versions.
python3 -m dmgbuild \
  -s scripts/dmg_settings.py \
  -D app=CmdE.app \
  -D background=scripts/dmg_background.png \
  -D icon=Resources/AppIcon.icns \
  "CmdE" "$DMG_NAME"

ditto -c -k --keepParent CmdE.app "$ZIP_NAME"

echo "Built $DMG_NAME and $ZIP_NAME"
