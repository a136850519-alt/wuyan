#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-.build/release/Wuyan.app}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$(dirname "$APP_PATH")/../Info.plist" 2>/dev/null || echo "unknown")"
DMG_PATH="${2:-Wuyan-${VERSION}.dmg}"
VOLUME_NAME="${VOLUME_NAME:-晤言}"
STAGING="$(mktemp -d)"

cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"
rm -rf "$STAGING"
echo "DMG: $DMG_PATH"
