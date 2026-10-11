import CryptoKit
import Foundation

public enum Hashing {
    /// 以固定大小分块读取文件并计算 SHA-256，避免把大媒体一次性载入内存。
    public static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func dayNoteHash(_ note: DayNote) -> String {
        let payload = DayNoteHashPayload(
            date: note.date,
            rawSummary: note.rawSummary.trimmingCharacters(in: .whitespacesAndNewlines),
            poeticLine: note.poeticLine.trimmingCharacters(in: .whitespacesAndNewlines),
            generatedBy: note.generatedBy?.trimmingCharacters(in: .whitespacesAndNewlines),
            mood: note.mood,
            moodCleared: note.moodCleared ? true : nil
        )
        let data = (try? JSONEncoder.wuyan.encode(payload)) ?? Data()
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// D06：这是「同步完整版本指纹」，不只覆盖正文内容。
    /// 收藏 / 归属板块 / 归属日期 / 删除状态等同步语义字段必须参与哈希，
    /// 否则只改这些字段的推送会被对端以「contentHash 未变」为由跳过拉取。
    /// boardId 等参数带默认值，是为了兼容只比较文本内容的既有调用点。
    public static func entryContentHash(
        title: String?,
        body: String,
        bodyRTF: Data?,
        tags: [String],
        mood: Int?,
        weather: Weather?,
        location: GeoPlace?,
        mediaIds: [UUID],
        boardId: UUID? = nil,
        dayDate: String? = nil,
        journalDate: Date? = nil,
        isFavorite: Bool = false,
        isDraft: Bool = false,
        deleted: Bool = false
    ) -> String {
        let normalizedTags = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
        let media = mediaIds.map(\.uuidString).sorted()
        let payload = EntryHashPayload(
            title: title?.trimmingCharacters(in: .whitespacesAndNewlines),
            body: body.trimmingCharacters(in: .whitespacesAndNewlines),
            bodyRTFBase64: bodyRTF?.base64EncodedString(),
            tags: normalizedTags,
            mood: mood,
            weather: weather,
            location: location,
            mediaIds: media,
            boardId: boardId?.uuidString,
            dayDate: dayDate,
            journalDate: journalDate.map { $0.timeIntervalSince1970 },
            isFavorite: isFavorite,
            isDraft: isDraft,
            deleted: deleted
        )
        let data = (try? JSONEncoder.wuyan.encode(payload)) ?? Data()
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct EntryHashPayload: Codable {
    var title: String?
    var body: String
    var bodyRTFBase64: String?
    var tags: [String]
    var mood: Int?
    var weather: Weather?
    var location: GeoPlace?
    var mediaIds: [String]
    // D06：同步语义字段（isFavorite / boardId / dayDate / journalDate / deleted / isDraft）
    var boardId: String?
    var dayDate: String?
    var journalDate: Double?
    var isFavorite: Bool
    var isDraft: Bool
    var deleted: Bool
}

private struct DayNoteHashPayload: Codable {
    var date: String
    var rawSummary: String
    var poeticLine: String
    var generatedBy: String?
    var mood: Int?
    /// Optional preserves the pre-v17 hash for notes without a mood or clear marker.
    var moodCleared: Bool?
}
