import Foundation

protocol PoeticGenerator {
    func line(from rawSummary: String) async -> String
}

struct StubPoeticGenerator: PoeticGenerator {
    func line(from rawSummary: String) async -> String {
        rawSummary.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
