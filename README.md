# 晤言（Wuyan）

[English](README.en.md)

晤言是一款原生 macOS 私人日记应用。它以本地优先为基础，把时间线、板块、心情、天气、媒体和写作辅助放在同一个安静的记录空间里。

当前最新版本是 **v1.5.0**。这个版本加入了年度主题色、年度归档和年度 PDF 日记本，同时保留本地数据库、同步、加密、AI 辅助、富文本编辑和多种导出能力。

![晤言运行界面](docs/interface-1010/native-running-preview.png)

## 主要功能

- **本地优先日记**：使用 SQLite 保存日记、板块、标签、心情、草稿和媒体索引，支持富文本编辑、收藏、回收站和全文搜索。
- **日记板块**：按日常记录、成长记录、阅读观影或自定义板块组织内容；新建日记时可以通过记录仪式选择板块和今日心情。
- **日札与生活信息**：记录每日心情、天气、温度、地点、连续记录和历史上的今天。
- **媒体附件**：导入照片、音频和视频，使用内容寻址保存媒体并生成缩略图。
- **跨设备同步**：支持 WebDAV/NAS 和 S3 兼容存储；同步使用 manifest、版本哈希、冲突副本和删除标记，避免静默覆盖内容。
- **远端加密**：可使用 AES-GCM 加密上传到 WebDAV 或 S3 的对象。密码、同步口令和 AI 密钥保存到 macOS 钥匙串。
- **AI 辅助写作**：支持 Ollama、Claude 和智谱等 provider，可生成写作问题、标题、标签、今日一句话和基于本地记录的检索问答。
- **导出与归档**：支持 Word 导出、年度 PDF 日记本，以及 WebDAV/NAS 或本地加密文件归档。归档会在校验成功后才清理本地内容，并保留变化记录。
- **隐私与日常使用**：支持日记锁、每日写作提醒、连续记录统计、深色/浅色主题和窗口恢复。

## 下载

前往 [GitHub Releases](https://github.com/a136850519-alt/wuyan/releases/latest) 下载最新 macOS 安装包。

发布包要求 **macOS 14 或更高版本**。如果下载的是未经过 Apple 公证的本地构建包，首次打开时可能需要在“系统设置 → 隐私与安全性”中允许打开，或者在 Finder 中右键应用并选择“打开”。

正式发布需要 Developer ID 签名和 Apple 公证；仓库中的本地构建脚本默认用于开发者或维护者自己的机器。

## 从源码运行

需要：

- macOS 14 或更高版本
- Swift 5.9 或更高版本
- Xcode 或 Xcode Command Line Tools

在项目根目录执行：

```sh
swift build
swift run Wuyan
```

运行测试：

```sh
swift test
```

也可以用 Xcode 打开根目录的 `Package.swift`，选择 `Wuyan` scheme 运行。

## 构建安装包

普通开发构建：

```sh
swift build -c release
```

本地发布构建会组装 `.app` 并生成 DMG：

```sh
bash Release/build-local.sh
```

脚本要求工作区干净，并且钥匙串中存在代码签名证书“晤言 Local Signing”。可以使用 `WUYAN_SIGNING_IDENTITY` 指定其他签名身份。产物默认位于 `dist/晤言.app` 和 `dist/晤言.dmg`。

正式发布、公证和签名流程见 [`Release/RELEASING.md`](Release/RELEASING.md)。

## 同步和 AI 配置

WebDAV/NAS 配置可以通过脚本写入设置：

```sh
bash Release/configure-webdav.sh --url https://你的NAS:5006/dav --username 你的账号
```

S3 兼容存储：

```sh
bash Release/configure-s3.sh
```

应用设置页也可以配置同步后端、加密口令和 AI provider。远端存储密码、S3 Secret Key、AI API Key 和同步口令只保存到 macOS 钥匙串；地址、账号、模型等非敏感设置保存在用户 defaults 中。

同步加密只保护上传到 WebDAV/S3 的对象，不会自动加密本地 SQLite、媒体缓存或 AI 索引。使用本地数据库时仍应依赖 FileVault、受保护的 macOS 账户和正确的磁盘权限。

## v1.5.0 变更

- 每年保存预设或自定义主题色，支持 HEX 和系统取色器，并兼容旧主题配置。
- 年度归档支持 WebDAV/NAS 和本地加密文件两种目的地；校验成功后才清理本地内容，并保留归档变化记录。
- 年度 PDF 日记本支持 A5/A4、素纸文集、时光手帐和年度影集样式，可包含日记、日札、标签、照片及音视频说明。
- 日级心情支持明确清除，避免旧条目心情在兼容逻辑中再次出现。
- 继续支持 Word 导出、日记锁定、富文本编辑和 WebDAV 诊断。

同一 NAS 上的其他设备应先升级到支持 `daynote-mood` 的版本，再继续记录或同步日级心情。完整发布说明见 [`Release/RELEASE_NOTES_NEXT.md`](Release/RELEASE_NOTES_NEXT.md)。

## 目录结构

```text
Wuyan/                  SwiftUI 应用、领域模型、本地数据库、同步和导出实现
WuyanTests/             单元测试、回归测试和导出/同步测试
WebPreview/             独立的 Web 界面预览
Release/                版本信息、图标、签名、公证和打包脚本
script/                 开发预览和运行脚本
docs/                   界面验收记录、截图和评审材料
Package.swift           Swift Package Manager 工程定义
MIGRATION.md            移动硬盘和应用数据迁移说明
```

## 数据和迁移

应用数据位于沙盒目录：

```text
~/Library/Containers/com.wuyan.app/Data/Library/Application Support/Wuyan
~/Library/Containers/com.wuyan.app/Data/Library/Preferences/com.wuyan.app.plist
~/Library/Containers/com.wuyan.app/Data/Library/Caches/Wuyan
```

迁移到另一台 Mac 时，先启动并退出一次应用，再按 [`MIGRATION.md`](MIGRATION.md) 恢复数据。钥匙串内容不会随文件复制迁移；WebDAV、S3、AI 和同步口令需要在新机器上重新录入。

不要把 `AppData/`、数据库快照、导出文件或任何凭据提交到 Git。项目已通过 `.gitignore` 排除这些本地数据。

## 项目边界

晤言当前是 macOS 原生应用，不支持 iOS、iCloud 或 CloudKit。真实 NAS/S3 联调、通知和定位权限、AI provider 的在线请求以及 Developer ID 公证需要在对应环境中单独验收。

## 许可证

本仓库目前没有声明开源许可证。除非得到项目维护者明确授权，请不要将代码、设计稿、字体或其他资源用于再发布或商业用途。
