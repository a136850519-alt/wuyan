#!/usr/bin/env bash
set -euo pipefail

# 晤言 · 自用版打包脚本
# 编译 → 组装 .app → 固定本地证书签名 → 生成 DMG。
# 需要预先创建固定的“代码签名”证书（默认名称：晤言 Local Signing）。
#
# 用法：  bash Release/build-local.sh
# 产物：  dist/晤言.app  和  dist/晤言.dmg
# 可用 WUYAN_PACKAGE_OUTPUT_DIR 指定独立输出目录，保留现有 dist 产物。

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="晤言"
BIN_NAME="Wuyan"
CONFIG="release"
DIST="${WUYAN_PACKAGE_OUTPUT_DIR:-$ROOT/dist}"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/$APP_NAME.dmg"
INFO_PLIST="$ROOT/Release/Info.plist"
ENTITLEMENTS="$ROOT/Release/Wuyan.entitlements"
ICON="$ROOT/Release/AppIcon.icns"   # 可选：放了才接入图标
SIGNING_IDENTITY="${WUYAN_SIGNING_IDENTITY:-晤言 Local Signing}"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "错误：工作区有未提交改动，拒绝生成正式安装包。" >&2
  echo "请先提交当前版本，或使用独立干净 worktree 打包。" >&2
  exit 1
fi

AVAILABLE_SIGNING_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if ! grep -Fq "\"$SIGNING_IDENTITY\"" <<< "$AVAILABLE_SIGNING_IDENTITIES"; then
  echo "错误：找不到固定签名身份 '$SIGNING_IDENTITY'。" >&2
  echo "请在钥匙串访问中创建代码签名证书，或设置 WUYAN_SIGNING_IDENTITY。" >&2
  exit 1
fi

echo "▶︎ 1/5 编译 release（首次较慢）…"
swift build -c "$CONFIG"
BUILD_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "▶︎ 2/5 组装 .app …"
rm -rf "$APP" "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"
cp "$INFO_PLIST" "$APP/Contents/Info.plist"

# SPM 资源 bundle 一并带上（可签名、无害）
shopt -s nullglob
for b in "$BUILD_DIR"/*.bundle; do
  cp -R "$b" "$APP/Contents/Resources/"
done
shopt -u nullglob

# 字体直接放进 Contents/Resources/Fonts —— WuyanFont 从这里加载，避开 SwiftPM Bundle.module
# 在 .app 里只认顶层路径、且签名不允许顶层内容的坑。
mkdir -p "$APP/Contents/Resources/Fonts"
cp "$ROOT/Wuyan/Resources/Fonts/LXGWWenKai-Regular.ttf" "$APP/Contents/Resources/Fonts/"

# 确保可执行文件名键存在
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $BIN_NAME" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $BIN_NAME" "$APP/Contents/Info.plist"

# 图标（可选）
if [[ -f "$ICON" ]]; then
  cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
  echo "    · 已接入图标 AppIcon.icns"
else
  echo "    · 未找到 Release/AppIcon.icns，跳过图标（用系统默认图标）"
fi

echo "▶︎ 3/5 固定证书签名（$SIGNING_IDENTITY）…"
codesign --force --deep --entitlements "$ENTITLEMENTS" --sign "$SIGNING_IDENTITY" "$APP"
# Q02：签名验证失败必须阻断发布，不能 || true 吞掉后继续出 DMG。
codesign --verify --verbose=1 "$APP"

echo "▶︎ 4/5 生成 DMG …"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo "▶︎ 5/5 完成 ✅"
echo "    App : $APP"
echo "    DMG : $DMG"
echo
echo "安装：打开 DMG，把「${APP_NAME}」拖进 Applications 即可。"
echo "本机自编译的产物不带隔离属性，通常可直接双击打开。"
echo "若拷到别的 Mac 后被拦：系统设置 → 隐私与安全性 → 找到「${APP_NAME}」→『仍要打开』；"
echo "或在该机执行： xattr -dr com.apple.quarantine \"/Applications/${APP_NAME}.app\""
