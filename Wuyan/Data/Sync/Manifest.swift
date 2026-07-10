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
}

struct CryptoManifestHeader: Codable, Equatable {
    var algorithm: String = "AES-GCM"
    var kdf: String = "SHA256-ITERATED"
    var saltBase64: String
    var iterations: Int
}

struct EncryptedPayload: Codable, Equatable {
    var schemaVersion: Int = 1
    var algorithm: String = "AES-GCM"
    var kdf: String = "SHA256-ITERATED"
    var saltBase64: String
    var iterations: Int
    var ciphertextBase64: String
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
}

struct SyncReport: Equatable {
    var pushed = 0
    var pulled = 0
    var conflicts: [UUID] = []
    var mediaUploaded = 0
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
