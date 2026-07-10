import Foundation

protocol AIProvider: Sendable {
    var isLocal: Bool { get }
    func complete(_ messages: [AIMessage], options: AIOptions) async throws -> String
    func stream(_ messages: [AIMessage], options: AIOptions) -> AsyncThrowingStream<String, Error>
    func embed(_ texts: [String]) async throws -> [[Float]]
}

struct AIMessage: Codable, Sendable {
    enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
    }

    var role: Role
    var content: String
}

struct AIOptions: Codable, Sendable {
    var temperature: Double = 0.7
    var maxTokens: Int = 1024
}

enum AIError: LocalizedError {
    case disabled
    case missingConfiguration
    case cancelledForPrivacy
    case blockedBySensitiveBoard
    case providerError(String)

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "AI 已关闭。"
        case .missingConfiguration:
            return "AI 配置不完整。"
        case .cancelledForPrivacy:
            return "已取消云端发送。"
        case .blockedBySensitiveBoard:
            return "涉及「禁止云端 AI」的板块，已阻止发送到云端。"
        case let .providerError(message):
            return message
        }
    }
}

struct WritingContext {
    var date: Date
    var weather: Weather?
    var recentEntries: [Entry]
}

enum Period: String {
    case week
    case month
}

struct MoodTrend {
    var summary: String
    var score: Double
}

struct AnswerWithSources {
    var answer: String
    var sourceEntryIds: [UUID]
}
