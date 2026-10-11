# V5 审查落地记录

依据：`/Users/smartfox/Desktop/晤言-全面审查报告-V5.md`

当前改动保留在工作区，尚未创建提交或版本标签。下表只记录已经落入源码且完成自动验证的项目；依赖真实钥匙串、NAS 或 Pages/WPS 的项目列为待实机验收。

| 编号 | 状态 | 自动验证 | 说明 |
|---|---|---|---|
| V5-01 | 完成 | `exportProducesParseableXML` | DOCX XML 校验、字符转义与 `textutil` 转换通过 |
| V5-02 | 代码完成，待实机 | 全量测试 | 锁定时移除正文树，关闭编辑器 sheet、焦点与 Quick Look；需人工检查 VoiceOver |
| V5-03 | 完成，待证书安装 | `unavailableCredentialsFailClosed` | 钥匙串不可读时保持锁定；正式打包要求固定签名证书 |
| V5-04 | 完成 | 现有编辑器集成测试 | 生命周期边界立即提交 RTFD，延迟任务绑定条目 ID |
| V5-05 | 完成 | `unknownManifestFeatureIsRejected` | Manifest 能力门槛在任何远端写入前检查 |
| V5-06 | 代码完成，待真实 NAS | `collectionURLRetainsTrailingSlash` | 基础路径预检、目录尾斜杠和公开诊断字段已接入 |
| V5-07 | 完成，待 Pages/WPS | `exportProducesParseableXML`、`photoAttachmentIsEmbedded`、`richTextAndInlineImageAreEmbedded`、`failedExportDoesNotOverwrite` | 进程内 ZIP、样式、正文图片、附件与失败回滚 |
| V5-08 | 完成，待实机 | `diaryUnlockThrottleEscalates` | 系统锁屏/睡眠监听、PBKDF2 后台运行、常量时间比较、共享递进节流 |
| V5-09 | 完成 | `build-local.sh` 语法与拒绝脏工作区检查 | 本次完整改动统一提交并标记为 v1.3.0；发布脚本继续拒绝脏工作区 |
| V5-10～V5-18 | 完成 | 全量测试 | 粘贴文件名、导出快照/保存结果、删除确认、切换提示、板块刷新、AI 标签、日志级别、`onChange` |
| U-01～U-08 | 已落实可直接修改项 | 开发预览实机检查；`clearLegacyProjectedMood` | 正文 720pt、AI 卡折叠、心情清除（含旧条目投影）、无标题行去重、锁页装饰隐藏、标准设置入口等 |

验证结果：`swift test` 共 114 个测试、39 个测试套件通过；`swift build -c release` 通过；`git diff --check` 通过。开发预览已检查深色宽窗口，AI 卡折叠/展开正常且没有布局重叠。

发布前仍需：安装 `晤言 Local Signing` 代码签名证书；在正式沙盒包中用 Pages 或 WPS 打开含图片 DOCX；在开启锁和 VoiceOver 的情况下覆盖报告列出的五种窗口状态；使用真实 NAS 凭据验证 WebDAV 基础路径。
