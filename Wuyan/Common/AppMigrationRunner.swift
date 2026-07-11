import Foundation
import os

// MARK: - R2-3 / R2-4: 应用迁移运行器

/// 仿 GRDB migrator 的有序、幂等、成功才记版本号迁移框架。
/// 启动时在构造任何 store 之前跑一次，失败仅记日志不崩溃，下次启动重试。
enum AppMigrationRunner {
    private static let versionKey = "wuyan.migration.version"
    private static let log = WuyanLog.general

    /// 所有已注册的迁移步骤，按 version 升序排列。
    /// 新迁移只需在此数组追加一个条目。
    private static let steps: [(version: Int, id: String, run: () throws -> Void)] = [
        // v1: Keychain 凭据迁移（原 SecureSettings.migrateAllFromDefaults）
        (version: 1, id: "keychain-credentials", run: { SecureSettings.migrateAllFromDefaults() }),
        // v2: 媒体从 Caches → Application Support（原 LocalMediaStore.migrateFromCachesIfNeeded）
        // 注意：此迁移需要 database + fileManager，在 runMigrations 中特殊处理
    ]

    /// 当前已完成的版本号（持久化在 UserDefaults）。
    static var currentVersion: Int {
        UserDefaults.standard.integer(forKey: versionKey)
    }

    /// 根入口：执行所有未完成的迁移。失败不崩溃，仅记日志。
    /// - Parameter mediaMigrator: v2 媒体迁移闭包（需要 database 参数，由调用方提供）。
    static func run(mediaMigrator: (() throws -> Void)? = nil) {
        let current = currentVersion
        log.info("AppMigrationRunner 启动，当前版本 \(current)，待执行 \(steps.count) 步")

        for step in steps {
            guard current < step.version else { continue }
            do {
                log.info("迁移 v\(step.version) [\(step.id)] 开始")
                try step.run()
                markCompleted(step.version)
                log.info("迁移 v\(step.version) [\(step.id)] 完成")
            } catch {
                log.error("迁移 v\(step.version) [\(step.id)] 失败：\(error.localizedDescription)")
                // 不标记完成，下次启动重试
                break
            }
        }

        // v2: 媒体 Caches → Application Support 迁移（需要特殊处理因为依赖 LocalMediaStore init）
        if current < 2, let mediaMigrator {
            do {
                log.info("迁移 v2 [media-caches] 开始")
                try mediaMigrator()
                markCompleted(2)
                log.info("迁移 v2 [media-caches] 完成")
            } catch {
                log.error("迁移 v2 [media-caches] 失败：\(error.localizedDescription)")
            }
        }
    }

    private static func markCompleted(_ version: Int) {
        UserDefaults.standard.set(version, forKey: versionKey)
    }
}
