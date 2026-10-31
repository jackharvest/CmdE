#!/bin/bash
# Builds CmdE.app and packages it into a distributable DMG with a
# custom background and a drag-to-Applications layout.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(plutil -extract CFBundleShortVersionString raw Info.plist)"
DMG_NAME="CmdE-${VERSION}.dmg"

./build.sh

rm -f "$DMG_NAME"

# dmgbuild (pure Python, writes .DS_Store directly) instead of create-dmg/Finder
# AppleScript automation — Finder has been unreliable about "background picture"
# assignments to icon view options on recent macOS versions.
python3 -m dmgbuild \
  -s scripts/dmg_settings.py \
  -D app=CmdE.app \
  -D background=scripts/dmg_background.png \
  -D icon=Resources/AppIcon.icns \
  "CmdE" "$DMG_NAME"

echo "Built $DMG_NAME"
