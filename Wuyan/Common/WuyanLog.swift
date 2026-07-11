import os

/// 统一日志入口，subsystem = com.wuyan.app，category 按域划分。
enum WuyanLog {
    static let sync = Logger(subsystem: "com.wuyan.app", category: "sync")
    static let media = Logger(subsystem: "com.wuyan.app", category: "media")
    static let ai = Logger(subsystem: "com.wuyan.app", category: "ai")
    static let db = Logger(subsystem: "com.wuyan.app", category: "db")
    static let security = Logger(subsystem: "com.wuyan.app", category: "security")
}
