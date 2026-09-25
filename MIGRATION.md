# 晤言移动硬盘迁移说明

这个目录是可随身携带的晤言项目副本，包含 SwiftPM 源码、Git 元数据、资源、发布脚本、构建产物以及一份应用运行数据备份。

## 在另一台 Mac 上编辑源码

1. 插上移动硬盘。
2. 在终端进入项目：

```bash
cd /Volumes/AI小屋/晤言
```

3. 构建、测试或运行：

```bash
swift build
swift test
swift run Wuyan
```

也可以用 Xcode 直接打开本目录的 `Package.swift`。

## 应用数据备份位置

当前机器上的晤言沙盒数据已备份到：

```text
AppData/ContainerData/Library/Application Support/Wuyan
AppData/ContainerData/Library/Preferences/com.wuyan.app.plist
AppData/ContainerData/Library/Caches/Wuyan
```

其中 `Application Support/Wuyan` 包含 `Wuyan.sqlite` 和导入前备份数据库，是最重要的数据。

## 在另一台 Mac 上恢复应用数据

先在新 Mac 上启动一次晤言，让系统创建沙盒目录，然后退出晤言，再把上面的备份复制到：

```text
~/Library/Containers/com.wuyan.app/Data/Library/Application Support/Wuyan
~/Library/Containers/com.wuyan.app/Data/Library/Preferences/com.wuyan.app.plist
~/Library/Containers/com.wuyan.app/Data/Library/Caches/Wuyan
```

注意：macOS 钥匙串内容不会随文件复制迁移。如果应用里启用了加密口令、WebDAV/S3/AI API Key 等钥匙串或本机凭据，另一台 Mac 上可能需要重新输入。

安全边界：新版本源码和配置脚本不再把新凭据写入项目文件或 `defaults`；但历史 `AppData`、数据库快照和旧偏好文件仍需在迁移前按报告盘点，不能据文件位置推断已经脱敏。迁移时只复制上面的应用数据目录，
不要把凭据写回 `defaults` 或手工放入项目文件；WebDAV/S3/AI 的密码和同步口令应在新机器的钥匙串中重新保存。确认恢复材料可用后，再由用户轮换仍有效的旧凭据并清理旧副本。
