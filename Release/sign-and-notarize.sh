#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-.build/release/Wuyan.app}"
IDENTITY="${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION}"
PROFILE="${NOTARYTOOL_PROFILE:?Set NOTARYTOOL_PROFILE}"
ENTITLEMENTS="${ENTITLEMENTS_PATH:-Release/Wuyan.entitlements}"

codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP_PATH"
ditto -c -k --keepParent "$APP_PATH" Wuyan-notary.zip
xcrun notarytool submit Wuyan-notary.zip --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP_PATH"
