import CryptoKit
import Foundation

public enum Hashing {
    public static func dayNoteHash(_ note: DayNote) -> String {
        let payload = DayNoteHashPayload(
            date: note.date,
            rawSummary: note.rawSummary.trimmingCharacters(in: .whitespacesAndNewlines),
            poeticLine: note.poeticLine.trimmingCharacters(in: .whitespacesAndNewlines),
            generatedBy: note.generatedBy?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let data = (try? JSONEncoder.wuyan.encode(payload)) ?? Data()
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func entryContentHash(
        title: String?,
        body: String,
        bodyRTF: Data?,
        tags: [String],
        mood: Int?,
        weather: Weather?,
        location: GeoPlace?,
        mediaIds: [UUID]
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
            mediaIds: media
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
}

private struct DayNoteHashPayload: Codable {
    var date: String
    var rawSummary: String
    var poeticLine: String
    var generatedBy: String?
}
