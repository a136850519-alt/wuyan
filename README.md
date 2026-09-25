# 晤言（Wuyan）

macOS 原生私有日记应用。当前已按桌面 `晤言-设计稿` 的 P0 范围落地为 SwiftUI + GRDB 的本地优先骨架。

## 运行

```bash
swift build
swift test
swift run Wuyan
```

如果要先把 WebDAV 同步配置好，可以直接跑：

```bash
bash Release/configure-webdav.sh --url https://你的NAS:5006 --username 你的账号
```

也可以用 Xcode 直接打开本目录的 `Package.swift`。

远端存储密码、S3 Secret Key、AI API Key 和同步口令只保存到 macOS 钥匙串；
地址、账号、模型等非敏感设置保存在 defaults。导出 AppData、复制源码或执行移动硬盘迁移时不会带走钥匙串凭据，
换 Mac 后需要在设置页或 `Release/configure-*.sh` 中重新录入。

“远端同步加密”只保护上传到 WebDAV/S3 的对象，不代表本地 SQLite、媒体缓存或 AI 索引自动加密；
本机仍应使用 FileVault、受保护的账户和磁盘权限。RAG 索引只持久化向量与条目身份，正文在运行时从本地数据库恢复。

> 本机已安装 Xcode 27.0，但当前 Xcode/Apple SDK 许可证尚未接受，因此 `swift build`、`swift test` 和 `xcodebuild` 会以退出码 69 停止；接受许可证后可直接从 SwiftPM 打开运行并做完整 GUI 验收。

## 字体

已内置霞鹜文楷 Regular：

- 文件：`Wuyan/Resources/Fonts/LXGWWenKai-Regular.ttf`
- 来源：LXGW WenKai v1.522 release zip
- 校验：release zip sha256 为 `3b596205423d838ccd0965bfa2c7e8b6ebcb9d9284e1809e234ad1d5f441adef`

## 发布备注

当前环境缺少已授权可用的完整 Xcode、Developer ID 证书与 notarytool 登录态，因此 P4 的签名、公证、DMG 只能在具备这些条件的机器上执行。代码侧已完成导出、加密、S3 Provider 和 onboarding。

## 阶段落实状态

- P0：SwiftUI + GRDB 本地骨架、三栏、新建仪式、自动保存、板块管理、霞鹜文楷已落实。
- P1：WebDAV Provider、manifest 同步引擎、媒体导入/缩略图/内容寻址、全文搜索 UI、设置页连接测试已落实；真实 NAS 双机冲突验收需配置绿联 WebDAV 后执行。
- P2：本地通知调度器、连续打卡统计、热力图、月历、历史上的今天、Open-Meteo 天气服务已落实；通知/定位需系统授权和网络可用性验收，无天气 API Key 配置。
- P3：AIProvider、Ollama、Claude、AIService、仪式润色、写作提示、标题/标签建议、RAG 问答骨架已落实；真实输出需本地 Ollama 或 Claude API Key。
- P4：AES-GCM 远端加密、完整备份与导入、onboarding、WebDAV/S3 Provider、发布脚本已落实；真实 MinIO/NAS 联调、公证、DMG 仍需要对应服务和完整 Xcode/Developer ID 环境验收。
