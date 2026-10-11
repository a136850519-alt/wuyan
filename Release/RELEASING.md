---
AIGC:
  ContentProducer: '001191110102MAD55U9H0F10002'
  ContentPropagator: '001191110102MAD55U9H0F10002'
  Label: '1'
  ProduceID: 'aaf4bd4f-fffa-4f93-bb44-a163934db562'
  PropagateID: 'aaf4bd4f-fffa-4f93-bb44-a163934db562'
  ReservedCode1: '3e414681-b8e3-4d17-91f4-36fb11475915'
  ReservedCode2: '3e414681-b8e3-4d17-91f4-36fb11475915'
---

# 晤言发布流程

## 版本号规则

- 遵循语义版本：`MAJOR.MINOR.PATCH`
  - MAJOR：架构重构、不兼容数据格式变更
  - MINOR：新功能、新增迁移
  - PATCH：bug 修复、无迁移
- `CFBundleShortVersionString` = 语义版本号（如 `2.0.0`）
- `CFBundleVersion` = 递增整数（每次发布 +1）
- 两者均在 `Release/Info.plist` 中维护

## 发布前检查清单

1. `swift build -c release` 通过
2. `bash Release/ci-local.sh` 通过（构建 + 魔法字符串检查）
3. 如有 Xcode 环境：`swift test` 全部通过
4. 更新 `Release/Info.plist` 中的版本号
5. 检查 `Wuyan/CHANGELOG.md`（如有）或 git log 确认变更范围

## 本地自编译发布

首次打包前，在“钥匙串访问”中通过“证书助理 → 创建证书”创建一个固定的代码签名证书，默认名称为 `晤言 Local Signing`，证书类型选择“代码签名”。可以用下面的命令确认系统能找到它：

```bash
security find-identity -v -p codesigning
```

`build-local.sh` 只允许在干净工作区运行，并使用这个固定身份签名。需要使用其他证书名称时设置 `WUYAN_SIGNING_IDENTITY`：

```bash
bash Release/build-local.sh
WUYAN_SIGNING_IDENTITY="证书名称" bash Release/build-local.sh
```

固定证书让不同构建版本保持稳定的 designated requirement，避免覆盖安装后反复请求访问钥匙串。脚本找不到证书或检测到未提交改动时会停止，不生成 DMG。

产物在 `dist/` 目录：
- `晤言.app`
- `晤言.dmg`

## 本地 DMG 命名

`build-local.sh` 生成的 DMG 默认命名为 `晤言.dmg`。
如需带版本号：

```bash
bash Release/make-dmg.sh dist/晤言.app dist/晤言-2.0.0.dmg
```

## 正式签名 & 公证（需 Apple 开发者账号）

```bash
bash Release/sign-and-notarize.sh
```

具体步骤见该脚本内注释。

## Git tag

```bash
git tag -a v2.0.0 -m "v2.0.0: 深度优化 — P0~P3 全量落地"
git push origin v2.0.0
```

## 不做的事

- 不引入 Sparkle 自动更新（当前手动发 DMG）
- 不上架 Mac App Store（沙盒限制与同步架构冲突）
- 不支持 iOS / iCloud / CloudKit
