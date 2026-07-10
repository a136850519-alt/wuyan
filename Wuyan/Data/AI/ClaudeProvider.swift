import Foundation

struct ClaudeProvider: AIProvider {
    var apiKey: String
    var model: String = "claude-3-5-sonnet-latest"
    var endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!
    var session: URLSession = .shared

    var isLocal: Bool { false }

    func complete(_ messages: [AIMessage], options: AIOptions) async throws -> String {
        guard !apiKey.isEmpty else { throw AIError.missingConfiguration }
        let system = messages.first(where: { $0.role == .system })?.content
        let body = ClaudeRequest(
            model: model,
            max_tokens: options.maxTokens,
            temperature: options.temperature,
            system: system,
            stream: false,
            messages: messages.filter { $0.role != .system }.map { .init(role: $0.role.rawValue, content: $0.content) }
        )
        var request = makeRequest()
        request.httpBody = try JSONEncoder().encode(body)
        let (data, urlResponse) = try await session.data(for: request)
        try validate(response: urlResponse, data: data)
        let decoded = try JSONDecoder().decode(ClaudeResponse.self, from: data)
        return decoded.content.map(\.text).joined(separator: "\n")
    }

    func stream(_ messages: [AIMessage], options: AIOptions) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard !apiKey.isEmpty else { throw AIError.missingConfiguration }
                    let system = messages.first(where: { $0.role == .system })?.content
                    let body = ClaudeRequest(
                        model: model,
                        max_tokens: options.maxTokens,
                        temperature: options.temperature,
                        system: system,
                        stream: true,
                        messages: messages.filter { $0.role != .system }.map { .init(role: $0.role.rawValue, content: $0.content) }
                    )
                    var request = makeRequest()
                    request.httpBody = try JSONEncoder().encode(body)
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw AIError.providerError("Claude 请求失败：HTTP \(http.statusCode)。")
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let event = try? JSONDecoder().decode(ClaudeStreamEvent.self, from: data),
                              event.type == "content_block_delta",
                              let text = event.delta?.text
                        else { continue }
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        throw AIError.missingConfiguration
    }

    private func makeRequest() -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        if let error = try? JSONDecoder().decode(ClaudeErrorResponse.self, from: data) {
            throw AIError.providerError(error.error?.message ?? "Claude 请求失败：HTTP \(http.statusCode)。")
        }
        throw AIError.providerError("Claude 请求失败：HTTP \(http.statusCode)。")
    }
}

private struct ClaudeRequest: Encodable {
    struct Message: Encodable {
        var role: String
        var content: String
    }
    var model: String
    var max_tokens: Int
    var temperature: Double
    var system: String?
    var stream: Bool
    var messages: [Message]
}

private struct ClaudeResponse: Decodable {
    struct Content: Decodable {
        var text: String
    }
    var content: [Content]
}

private struct ClaudeErrorResponse: Decodable {
    struct ProviderError: Decodable {
        var message: String?
    }
    var error: ProviderError?
}

private struct ClaudeStreamEvent: Decodable {
    struct Delta: Decodable {
        var type: String?
        var text: String?
    }
    var type: String
    var delta: Delta?
}
