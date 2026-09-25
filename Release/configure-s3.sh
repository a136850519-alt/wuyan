#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.wuyan.app}"
DEFAULT_REGION="us-east-1"
DEFAULT_BUCKET="wuyan"

usage() {
  cat <<EOF
用法：
  bash Release/configure-s3.sh --endpoint <s3_endpoint> --access-key <access_key> [--secret-key <secret_key>] [--bucket <bucket>] [--region <region>] [--virtual-hosted-style]

说明：
  - 把晤言的 S3 / MinIO 配置写入本机 defaults
  - 把 Secret Key 写入本机钥匙串（若未传 --secret-key，会交互式提示输入）
  - MinIO 通常使用 path-style URL，所以默认开启 Path-style URL

示例：
  bash Release/configure-s3.sh --endpoint http://192.168.50.85:9000 --bucket wuyan --access-key wuyan-app
  bash Release/configure-s3.sh --endpoint https://你的域名:9000 --bucket wuyan --access-key wuyan-app --secret-key 'your-secret'

环境变量：
  APP_BUNDLE_ID   默认是 com.wuyan.app
EOF
}

S3_ENDPOINT=""
S3_BUCKET="$DEFAULT_BUCKET"
S3_REGION="$DEFAULT_REGION"
S3_ACCESS_KEY=""
S3_SECRET_KEY=""
S3_PATH_STYLE="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --endpoint)
      S3_ENDPOINT="${2:-}"
      shift 2
      ;;
    --bucket)
      S3_BUCKET="${2:-}"
      shift 2
      ;;
    --region)
      S3_REGION="${2:-}"
      shift 2
      ;;
    --access-key)
      S3_ACCESS_KEY="${2:-}"
      shift 2
      ;;
    --secret-key)
      S3_SECRET_KEY="${2:-}"
      shift 2
      ;;
    --virtual-hosted-style)
      S3_PATH_STYLE="false"
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

if [[ -z "$S3_ENDPOINT" ]]; then
  echo "缺少 --endpoint" >&2
  echo >&2
  usage >&2
  exit 1
fi

if [[ -z "$S3_ACCESS_KEY" ]]; then
  echo "缺少 --access-key" >&2
  echo >&2
  usage >&2
  exit 1
fi

if [[ -z "$S3_SECRET_KEY" ]]; then
  read -r -s -p "请输入 S3 Secret Key: " S3_SECRET_KEY
  echo
fi

if [[ -z "$S3_BUCKET" || -z "$S3_REGION" || -z "$S3_SECRET_KEY" ]]; then
  echo "bucket、region 和 secret key 不能为空。" >&2
  exit 1
fi

if [[ ! "$S3_ENDPOINT" =~ ^https?:// ]]; then
  echo "S3 Endpoint 需要包含 http:// 或 https:// 前缀。" >&2
  exit 1
fi

defaults write "$APP_BUNDLE_ID" "settings.storage.backend" -string "s3"
defaults write "$APP_BUNDLE_ID" "settings.s3.endpoint" -string "$S3_ENDPOINT"
defaults write "$APP_BUNDLE_ID" "settings.s3.region" -string "$S3_REGION"
defaults write "$APP_BUNDLE_ID" "settings.s3.bucket" -string "$S3_BUCKET"
defaults write "$APP_BUNDLE_ID" "settings.s3.accessKey" -string "$S3_ACCESS_KEY"
defaults write "$APP_BUNDLE_ID" "settings.s3.pathStyle" -bool "$S3_PATH_STYLE"

# 将 Secret Key 写入 Keychain（不再写 defaults，避免明文泄露）
# 不使用 -A（允许所有应用访问）。钥匙串会按当前用户的访问控制处理首次读取；
# 如需预先信任已安装的应用，可传 KEYCHAIN_TRUSTED_APP 指向应用可执行文件。
KEYCHAIN_ARGS=(-a "settings.s3.secretKey" -s "com.wuyan.app" -U)
if [[ -n "${KEYCHAIN_TRUSTED_APP:-}" ]]; then
  KEYCHAIN_ARGS+=(-T "$KEYCHAIN_TRUSTED_APP")
fi
security add-generic-password "${KEYCHAIN_ARGS[@]}" -w "$S3_SECRET_KEY"

echo "已写入晤言 S3 / MinIO 配置："
echo "  Bundle ID: $APP_BUNDLE_ID"
echo "  Endpoint: $S3_ENDPOINT"
echo "  Bucket: $S3_BUCKET"
echo "  Region: $S3_REGION"
echo "  Access Key: $S3_ACCESS_KEY"
echo "  Path-style URL: $S3_PATH_STYLE"
echo
echo "Secret Key 已写入系统钥匙串。"
