#!/bin/bash
# 晤言 pre-commit hook：构建 + 魔法字符串检查
# 安装：cp Release/pre-commit.sh .git/hooks/pre-commit
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ── 1. swift build（静默输出，失败时才显示）──
build_output=$(swift build 2>&1) || {
  echo -e "${RED}✗ swift build 失败${NC}"
  echo "$build_output"
  exit 1
}
echo -e "${GREEN}✓ swift build 通过${NC}"

# ── 2. 魔法字符串检查 ──
violations=$(grep -rn '"settings\.' \
  --include='*.swift' \
  --exclude-dir='.build' \
  --exclude-dir='WuyanTests' \
  "Wuyan/" \
  | grep -v 'Wuyan/Common/AppSettings.swift' \
  | grep -v 'Wuyan/Common/SecureSettings.swift' \
  | grep -v '// ' \
  || true)

if [ -n "$violations" ]; then
  echo -e "${RED}✗ 发现 settings. 魔法字符串（应使用 SettingKey 常量）：${NC}"
  echo "$violations"
  exit 1
fi
echo -e "${GREEN}✓ 无 settings. 魔法字符串${NC}"

exit 0
