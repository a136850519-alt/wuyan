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

> 本机当前 active developer directory 是 Command Line Tools，无法使用 `xcodebuild` 生成/验证 `.xcodeproj`。因此 P0 先以 SwiftPM 工程承载；安装完整 Xcode 后可直接从 SwiftPM 打开运行。

## 字体

已内置霞鹜文楷 Regular：

- 文件：`Wuyan/Resources/Fonts/LXGWWenKai-Regular.ttf`
- 来源：LXGW WenKai v1.522 release zip
- 校验：release zip sha256 为 `3b596205423d838ccd0965bfa2c7e8b6ebcb9d9284e1809e234ad1d5f441adef`

## 发布备注

当前环境没有完整 Xcode、Developer ID 证书与 notarytool 登录态，因此 P4 的签名、公证、DMG 只能在具备 Apple Developer ID 的机器上执行。代码侧已预留导出、加密、S3 Provider 和 onboarding 骨架。

## 阶段落实状态

- P0：SwiftUI + GRDB 本地骨架、三栏、新建仪式、自动保存、板块管理、霞鹜文楷已落实。
- P1：WebDAV Provider、manifest 同步引擎、媒体导入/缩略图/内容寻址、全文搜索 UI、设置页连接测试已落实；真实 NAS 双机冲突验收需配置绿联 WebDAV 后执行。
- P2：本地通知调度器、连续打卡统计、热力图、月历、历史上的今天、OpenWeather 服务骨架已落实；通知/定位/天气需系统授权和 API Key 验收。
- P3：AIProvider、Ollama、Claude、AIService、仪式润色、写作提示、标题/标签建议、RAG 问答骨架已落实；真实输出需本地 Ollama 或 Claude API Key。
- P4：AES-GCM 加密工具、导出 Markdown/JSON/PDF、onboarding、S3 Provider 配置占位、发布说明已落实；MinIO 完整同步、公证、DMG 需要 Soto/Developer ID/完整 Xcode 环境继续完成。
