import Foundation

struct EntryEnvelope: Codable {
    var entry: Entry
    var board: Board?
    var dayNote: DayNote?
    var schemaVersion: Int = 2
}

enum SyncPaths {
    static let root = "/Wuyan/"
    static let manifest = "/Wuyan/manifest.json"

    static func entryPath(_ entry: Entry) -> String {
        let parts = entry.dayDate.split(separator: "-")
        let year = parts.indices.contains(0) ? String(parts[0]) : "unknown"
        let month = parts.indices.contains(1) ? String(parts[1]) : "unknown"
        return "/Wuyan/entries/\(year)/\(month)/\(entry.id.uuidString).json"
    }

    static func dayNotePath(_ note: DayNote) -> String {
        let parts = note.date.split(separator: "-")
        let year = parts.indices.contains(0) ? String(parts[0]) : "unknown"
        let month = parts.indices.contains(1) ? String(parts[1]) : "unknown"
        return "/Wuyan/daynotes/\(year)/\(month)/\(note.date).json"
    }

    static func dayNotePath(date: String) -> String {
        let note = DayNote(date: date, rawSummary: "", poeticLine: "")
        return dayNotePath(note)
    }

    static func deviceStatePath(deviceId: String) -> String {
        "/Wuyan/.sync/\(deviceId).state"
    }

    static func mediaPath(sha256: String, filename: String) -> String {
        let prefix = String(sha256.prefix(2))
        let ext = URL(fileURLWithPath: filename).pathExtension
        let final = ext.isEmpty ? sha256 : "\(sha256).\(ext)"
        return "/Wuyan/media/\(prefix)/\(final)"
    }

    static func encryptedMediaPath(sha256: String, filename: String) -> String {
        mediaPath(sha256: sha256, filename: filename) + ".enc"
    }

    static func thumbnailPath(sha256: String) -> String {
        "/Wuyan/media/thumbnails/\(sha256).jpg"
    }
}
