#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.wuyan.app}"
DEFAULT_URL="https://nas.local:5006"

usage() {
  cat <<EOF
用法：
  bash Release/configure-webdav.sh --url <webdav_url> --username <username> [--password <password>] [--mark-onboarding-done]

说明：
  - 把晤言的 WebDAV 地址和用户名写入本机 defaults
  - 把 WebDAV 密码写入本机 defaults（若未传 --password，会交互式提示输入）
  - 可选地把 onboarding 标记为已完成

示例：
  bash Release/configure-webdav.sh --url https://192.168.1.20:5006 --username wuyan
  bash Release/configure-webdav.sh --url https://nas.local:5006 --username wuyan --password 'your-password' --mark-onboarding-done

环境变量：
  APP_BUNDLE_ID   默认是 com.wuyan.app
EOF
}

WEB_DAV_URL=""
WEB_DAV_USERNAME=""
WEB_DAV_PASSWORD=""
MARK_ONBOARDING_DONE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)
      WEB_DAV_URL="${2:-}"
      shift 2
      ;;
    --username)
      WEB_DAV_USERNAME="${2:-}"
      shift 2
      ;;
    --password)
      WEB_DAV_PASSWORD="${2:-}"
      shift 2
      ;;
    --mark-onboarding-done)
      MARK_ONBOARDING_DONE="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数：$1" >&2
      echo >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$WEB_DAV_URL" ]]; then
  WEB_DAV_URL="$DEFAULT_URL"
fi

if [[ -z "$WEB_DAV_USERNAME" ]]; then
  echo "缺少 --username" >&2
  echo >&2
  usage >&2
  exit 1
fi

if [[ -z "$WEB_DAV_PASSWORD" ]]; then
  read -r -s -p "请输入 WebDAV 密码: " WEB_DAV_PASSWORD
  echo
fi

if [[ -z "$WEB_DAV_PASSWORD" ]]; then
  echo "密码不能为空。" >&2
  exit 1
fi

if [[ ! "$WEB_DAV_URL" =~ ^https?:// ]]; then
  echo "WebDAV 地址需要包含 http:// 或 https:// 前缀。" >&2
  exit 1
fi

defaults write "$APP_BUNDLE_ID" "settings.storage.backend" -string "webDAV"
defaults write "$APP_BUNDLE_ID" "settings.webdav.baseURL" -string "$WEB_DAV_URL"
defaults write "$APP_BUNDLE_ID" "settings.webdav.username" -string "$WEB_DAV_USERNAME"

# 将密码写入 Keychain（不再写 defaults，避免明文泄露）
security add-generic-password -a "settings.webdav.password" -s "com.wuyan.app" -w "$WEB_DAV_PASSWORD" -U 2>/dev/null \
  || security add-generic-password -a "settings.webdav.password" -s "com.wuyan.app" -w "$WEB_DAV_PASSWORD"

if [[ "$MARK_ONBOARDING_DONE" == "true" ]]; then
  defaults write "$APP_BUNDLE_ID" "onboarding.completed" -bool true
fi

echo "已写入晤言 WebDAV 配置："
echo "  Bundle ID: $APP_BUNDLE_ID"
echo "  地址: $WEB_DAV_URL"
echo "  账号: $WEB_DAV_USERNAME"
if [[ "$MARK_ONBOARDING_DONE" == "true" ]]; then
  echo "  onboarding: 已标记完成"
fi
echo
echo "密码已写入系统钥匙串。"
