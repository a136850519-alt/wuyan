import Foundation

struct Manifest: Codable, Equatable {
    var schemaVersion: Int = 2
    // 内容指纹：条目/日札的「计数 + 两侧最大 updatedAt」。完全由内容派生，
    // 无操作的重复写入不会改变它；任一条目改动都会刷新其 updatedAt 从而改变指纹。
    // 本地据此做「远端无变化则跳过拉取」的增量判断。旧版 manifest 解码为 nil。
    var revision: String?
    var boards: [Board] = []
    var daynotes: [ManifestDayNote] = []
    var entries: [ManifestEntry] = []
    var crypto: CryptoManifestHeader?
    /// C02：远端持久化的格式迁移状态（随索引发布）。非 nil 表示迁移尚未完成：
    /// 任何设备的后续同步都必须据此补完迁移，而不是依赖某一台设备本地数据库里
    /// 的 in-progress 标记。只有对象盘点、转换与验证全部完成后的索引提交才会把它
    /// 清空。旧版 manifest 解码为 nil。
    var migration: RemoteMigrationState?
    /// V3-15：已过保留期、被移出 entries 的删除记录。只含 id 与删除时间，永久保留。
    /// Optional 以兼容旧版 manifest；空数组保存时会归一化为 nil。
    var purged: [PurgedEntry]?
}

/// V3-15：永久清除记录，不携带正文或媒体信息。
struct PurgedEntry: Codable, Equatable {
    var id: UUID
    var deletedAt: Date
}

/// C02：远端迁移标记。direction："encrypt"（明文→加密）或 "decrypt"（关闭加密）。
/// startedAt/startBy 仅用于诊断；协议语义只依赖 direction 是否存在。
struct RemoteMigrationState: Codable, Equatable {
    var direction: String
    var startedAt: Date
    var startedBy: String?

    static let encrypt = "encrypt"
    static let decrypt = "decrypt"

    init(direction: String, startedAt: Date, startedBy: String? = nil) {
        self.direction = direction
        self.startedAt = startedAt
        self.startedBy = startedBy
    }
}

struct CryptoManifestHeader: Codable, Equatable {
    var algorithm: String = "AES-GCM"
    var kdf: String = "PBKDF2-HMAC-SHA256"
    var saltBase64: String
    var iterations: Int
    // UI-01/S03：数据密钥（DEK）协议字段。nil 表示旧版（逐对象口令派生）格式。
    var keyId: String?
    var wrappedDekBase64: String?

    init(algorithm: String = "AES-GCM", kdf: String = "PBKDF2-HMAC-SHA256", saltBase64: String, iterations: Int, keyId: String? = nil, wrappedDekBase64: String? = nil) {
        self.algorithm = algorithm
        self.kdf = kdf
        self.saltBase64 = saltBase64
        self.iterations = iterations
        self.keyId = keyId
        self.wrappedDekBase64 = wrappedDekBase64
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        algorithm = try container.decode(String.self, forKey: .algorithm)
        // 兼容旧版 "SHA256-ITERATED" 写法
        let rawKdf = try container.decode(String.self, forKey: .kdf)
        kdf = (rawKdf == "SHA256-ITERATED") ? "PBKDF2-HMAC-SHA256" : rawKdf
        saltBase64 = try container.decode(String.self, forKey: .saltBase64)
        iterations = try container.decode(Int.self, forKey: .iterations)
        keyId = try container.decodeIfPresent(String.self, forKey: .keyId)
        wrappedDekBase64 = try container.decodeIfPresent(String.self, forKey: .wrappedDekBase64)
    }
}

/// UI-01：加密模式下的 manifest 容器。密钥头（含包装后的数据密钥）明文外置，
/// 索引本体由数据密钥加密。换口令只需重写密钥头，索引密文保持不变。
struct ManifestContainer: Codable, Equatable {
    var schemaVersion: Int = 3
    var crypto: CryptoManifestHeader?
    var payloadCiphertextBase64: String?
}

struct EncryptedPayload: Codable, Equatable {
    /// v3：数据密钥协议（keyId + 密文）。v1/v2：逐对象 PBKDF2 口令派生（salt/iterations/kdf）。
    var schemaVersion: Int
    var algorithm: String
    var kdf: String?
    var saltBase64: String?
    var iterations: Int?
    var keyId: String?
    var ciphertextBase64: String

    init(schemaVersion: Int = 3, algorithm: String = "AES-GCM", kdf: String? = nil, saltBase64: String? = nil, iterations: Int? = nil, keyId: String? = nil, ciphertextBase64: String) {
        self.schemaVersion = schemaVersion
        self.algorithm = algorithm
        self.kdf = kdf
        self.saltBase64 = saltBase64
        self.iterations = iterations
        self.keyId = keyId
        self.ciphertextBase64 = ciphertextBase64
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, algorithm, kdf, saltBase64, iterations, keyId, ciphertextBase64
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        algorithm = try container.decode(String.self, forKey: .algorithm)
        if let rawKdf = try container.decodeIfPresent(String.self, forKey: .kdf) {
            kdf = (rawKdf == "SHA256-ITERATED") ? "PBKDF2-HMAC-SHA256" : rawKdf
        } else {
            kdf = nil
        }
        saltBase64 = try container.decodeIfPresent(String.self, forKey: .saltBase64)
        iterations = try container.decodeIfPresent(Int.self, forKey: .iterations)
        keyId = try container.decodeIfPresent(String.self, forKey: .keyId)
        ciphertextBase64 = try container.decode(String.self, forKey: .ciphertextBase64)
    }
}

struct ManifestDayNote: Codable, Equatable {
    var date: String
    var path: String
    var updatedAt: Date
    var hash: String
}

struct SyncDeviceState: Codable, Equatable {
    var deviceId: String
    var syncedAt: Date
    var pushed: Int
    var pulled: Int
    var mediaUploaded: Int
    var conflicts: [UUID]
}

struct ManifestEntry: Codable, Equatable, Identifiable {
    var id: UUID
    var boardId: UUID
    var dayDate: String
    var path: String
    var updatedAt: Date
    var hash: String
    var deleted: Bool
    /// 删除动作发生的时间，与条目最后编辑时间分开，用于远端保留期计算。
    /// 旧 manifest 没有该字段时按 updatedAt 兼容。
    var deletedAt: Date?
    /// UI-04：该条目引用的媒体 sha256 列表。用于彻底删除保留期到期后，
    /// 判断远端媒体文件是否仍被其他条目引用——仅当整个索引都携带此字段时
    /// 才允许判定「无引用」并清理远端媒体；旧索引（nil）不会触发媒体删除。
    var mediaShas: [String]?

    init(id: UUID, boardId: UUID, dayDate: String, path: String, updatedAt: Date, hash: String, deleted: Bool, mediaShas: [String]? = nil, deletedAt: Date? = nil) {
        self.id = id
        self.boardId = boardId
        self.dayDate = dayDate
        self.path = path
        self.updatedAt = updatedAt
        self.hash = hash
        self.deleted = deleted
        self.deletedAt = deletedAt
        self.mediaShas = mediaShas
    }
}

struct SyncReport: Equatable {
    var pushed = 0
    var pulled = 0
    var conflicts: [UUID] = []
    var mediaUploaded = 0
    /// C01：缺失对象巡检补传的对象数（正文/日札/媒体）。
    var repaired = 0
    /// V3-15：远端永久清除记录应用到本地回收站的条目数。
    var purgedToTrash = 0
}

/// UI-02：归档推送结果——只包含「读回校验通过」的条目/日札快照，
/// 调用方据此清理本地，且须再次比对本地当前指纹防止归档期间被编辑。
struct ArchiveResult {
    let report: SyncReport
    let pushedEntries: [Entry]
    let pushedNotes: [DayNote]
}

struct SyncProgress: Equatable, Sendable {
    var phase: String
    var completedUnitCount: Int
    var totalUnitCount: Int
    var detail: String?

    var fractionCompleted: Double {
        guard totalUnitCount > 0 else { return 0 }
        return min(1, max(0, Double(completedUnitCount) / Double(totalUnitCount)))
    }

    var percentageText: String {
        "\(Int((fractionCompleted * 100).rounded()))%"
    }
}

enum SyncStatus: Equatable {
    case idle
    case syncing
    case error(String)
}
