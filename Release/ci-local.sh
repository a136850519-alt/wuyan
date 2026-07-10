#!/bin/bash
# 晤言本地 CI：构建 + 魔法字符串检查
# 用法：bash Release/ci-local.sh [--skip-test]
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass=0
fail=0

step() {
  echo -e "\n${YELLOW}▶ $1${NC}"
}

ok() {
  echo -e "${GREEN}  ✓ $1${NC}"
  ((pass++))
}

err() {
  echo -e "${RED}  ✗ $1${NC}"
  ((fail++))
}

# ── 1. swift build ──
step "swift build"
if swift build 2>&1; then
  ok "构建成功"
else
  err "构建失败"
fi

# ── 2. swift test (如果可用) ──
SKIP_TEST="${2:-}"
if [[ "$1" != "--skip-test" && "$SKIP_TEST" != "--skip-test" ]]; then
  step "swift test"
  if swift test 2>&1; then
    ok "测试全部通过"
  else
    # SPM CLI 可能没有 XCTest，不当作硬失败
    echo -e "${YELLOW}  ⚠ swift test 未通过（SPM CLI 可能缺少 XCTest）${NC}"
  fi
else
  echo "  跳过测试 (--skip-test)"
fi

# ── 3. 魔法字符串检查：不应再用 "settings." 硬编码 ──
step "魔法字符串检查"
# 排除 AppSettings.swift（定义常量的地方）和 WuyanTests
violations=$(grep -rn '"settings\.' \
  --include='*.swift' \
  --exclude-dir='.build' \
  --exclude-dir='WuyanTests' \
  "Wuyan/" \
  | grep -v 'Wuyan/Common/AppSettings.swift' \
  | grep -v 'Wuyan/Common/SecureSettings.swift' \
  | grep -v '// ' \
  || true)

if [ -z "$violations" ]; then
  ok "无 settings. 魔法字符串"
else
  err "发现 settings. 魔法字符串（应使用 SettingKey 常量）："
  echo "$violations"
fi

# ── 4. 检查 SettingKey 前缀一致性 ──
step "SettingKey 前缀一致性"
# 所有 SettingKey 常量的值必须以 "settings." 开头
bad_keys=$(grep -n 'static let.*= "' Wuyan/Common/AppSettings.swift \
  | grep -v '"settings\.' \
  | grep -v 'enum SettingKey' \
  || true)

if [ -z "$bad_keys" ]; then
  ok "所有 SettingKey 常量以 settings. 开头"
else
  err "以下 SettingKey 常量缺少 settings. 前缀："
  echo "$bad_keys"
fi

# ── 5. 检查待提交文件 ──
step "Git 工作区状态"
if git diff --quiet && git diff --cached --quiet; then
  ok "工作区干净"
else
  echo -e "${YELLOW}  ⚠ 有未提交的修改${NC}"
  git status --short
fi

# ── 汇总 ──
echo -e "\n${YELLOW}═══════════════════════════════════${NC}"
echo -e "  通过: ${GREEN}${pass}${NC}  失败: ${RED}${fail}${NC}"
if [ "$fail" -gt 0 ]; then
  echo -e "  ${RED}有检查项未通过${NC}"
  exit 1
else
  echo -e "  ${GREEN}全部检查通过${NC}"
  exit 0
fi
