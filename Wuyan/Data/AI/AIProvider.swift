import Foundation

protocol AIProvider: Sendable {
    var isLocal: Bool { get }
    /// Whether this provider can build semantic embeddings without sending
    /// diary content to an unsupported remote embedding service.
    var supportsEmbeddings: Bool { get }
    /// S04/UI-05：目的地描述（provider + 实际地址 + 模型），用于授权弹窗明示发送去向，
    /// 并作为会话信任的绑定标识——配置变更后标识变化，旧授权自动失效。
    var destinationDescription: String { get }
    func complete(_ messages: [AIMessage], options: AIOptions) async throws -> String
    func stream(_ messages: [AIMessage], options: AIOptions) -> AsyncThrowingStream<String, Error>
    func embed(_ texts: [String]) async throws -> [[Float]]
}

extension AIProvider {
    /// Keep third-party/test providers source-compatible; opt in explicitly
    /// when the provider really implements embeddings.
    var supportsEmbeddings: Bool { false }
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
    var boardName: String? = nil
    var boardKind: BoardKind? = nil
    var boardId: UUID? = nil
    var boardTheme: String? = nil
    var annualAge: String? = nil
    var draft: Entry? = nil
    var mood: Int? = nil
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
    /// 语义索引不可用时显式标记降级，界面不得把最近条目回退伪装成完整检索。
    var retrievalWasDegraded: Bool = false
}
