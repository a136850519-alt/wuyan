#!/usr/bin/env bash
set -euo pipefail

# Runs an isolated debug instance; never touches dist/ or /Applications.
WUYAN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$WUYAN_ROOT"
WUYAN_MODE="${1:-run}"
case "$WUYAN_MODE" in
  run|--verify|--prepare-only) ;;
  *) echo "usage: $0 [run|--verify|--prepare-only]" >&2; exit 2 ;;
esac

# Only the development instance may be relaunched. Never kill Wuyan.
if pgrep -x WuyanPreview >/dev/null; then
  echo "晤言开发预览已经运行，请先在预览窗口按 ⌘Q 退出，再重新运行。" >&2
  exit 1
fi
swift build --product Wuyan
WUYAN_BIN_DIR="$(swift build --show-bin-path)"
WUYAN_PREVIEW_DIR="$WUYAN_ROOT/.build/development-preview"
WUYAN_PREVIEW_APP="$WUYAN_PREVIEW_DIR/晤言开发预览.app"
mkdir -p "$WUYAN_PREVIEW_APP/Contents/MacOS" "$WUYAN_PREVIEW_APP/Contents/Resources/Fonts"
cp "$WUYAN_BIN_DIR/Wuyan" "$WUYAN_PREVIEW_APP/Contents/MacOS/WuyanPreview"
cp Wuyan/Resources/Fonts/LXGWWenKai-Regular.ttf "$WUYAN_PREVIEW_APP/Contents/Resources/Fonts/"
cp Release/AppIcon.icns "$WUYAN_PREVIEW_APP/Contents/Resources/AppIcon.icns"
python3 - "$WUYAN_PREVIEW_APP" "$HOME/Library/Application Support/WuyanDevelopmentPreview" <<'PY'
import plistlib
import sys
from pathlib import Path
app, data = sys.argv[1:]
with (Path(app) / 'Contents/Info.plist').open('wb') as file:
    plistlib.dump({
        'CFBundleExecutable': 'WuyanPreview',
        'CFBundleIdentifier': 'com.wuyan.development-preview',
        'CFBundleName': '晤言开发预览',
        'CFBundleDisplayName': '晤言开发预览',
        'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': '0.0.0',
        'CFBundleVersion': '1010',
        'CFBundleIconFile': 'AppIcon',
        'LSMinimumSystemVersion': '14.0',
        'NSPrincipalClass': 'NSApplication',
        'NSHighResolutionCapable': True,
        'WuyanPreviewDataDirectory': data,
        'NSMicrophoneUsageDescription': '在独立开发预览中录制日记附件。',
    }, file)
PY
codesign --force --sign - "$WUYAN_PREVIEW_APP"
if [[ "$WUYAN_MODE" == --prepare-only ]]; then
  echo "$WUYAN_PREVIEW_APP"
  exit 0
fi
/usr/bin/open -n "$WUYAN_PREVIEW_APP"
if [[ "$WUYAN_MODE" == --verify ]]; then
  sleep 2
  pgrep -x WuyanPreview
fi
