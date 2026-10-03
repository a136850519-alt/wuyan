import Foundation

struct ZhipuProvider: AIProvider {
    var apiKey: String
    var model: String = "glm-5.2"
    var endpoint: URL = URL(string: "https://open.bigmodel.cn/api/paas/v4/chat/completions")!
    var session: URLSession = .shared

    var isLocal: Bool { false }
    var supportsEmbeddings: Bool { false }

    var destinationDescription: String {
        "云端智谱（\(endpoint.absoluteString)，模型 \(model)）"
    }

    func complete(_ messages: [AIMessage], options: AIOptions) async throws -> String {
        guard !apiKey.isEmpty else { throw AIError.missingConfiguration }
        var request = makeRequest()
        request.httpBody = try JSONEncoder().encode(makeBody(messages: messages, options: options, stream: false))
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(ZhipuResponse.self, from: data)
        return decoded.choices.compactMap(\.message?.content).joined(separator: "\n")
    }

    func stream(_ messages: [AIMessage], options: AIOptions) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard !apiKey.isEmpty else { throw AIError.missingConfiguration }
                    var request = makeRequest()
                    request.httpBody = try JSONEncoder().encode(makeBody(messages: messages, options: options, stream: true))
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw AIError.providerError("智谱请求失败：HTTP \(http.statusCode)。")
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let event = try? JSONDecoder().decode(ZhipuStreamResponse.self, from: data)
                        else { continue }
                        for choice in event.choices {
                            if let content = choice.delta.content, !content.isEmpty {
                                continuation.yield(content)
                            }
                        }
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
        var request = URLRequest(url: Self.chatCompletionsURL(from: endpoint))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func chatCompletionsURL(from endpoint: URL) -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return endpoint
        }

        let trimmedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmedPath.isEmpty {
            components.path = "/api/paas/v4/chat/completions"
        } else if !trimmedPath.hasSuffix("chat/completions") {
            components.path = "/" + trimmedPath + "/chat/completions"
        }
        return components.url ?? endpoint
    }

    private func makeBody(messages: [AIMessage], options: AIOptions, stream: Bool) -> ZhipuRequest {
        ZhipuRequest(
            model: model,
            messages: messages.map { .init(role: $0.role.rawValue, content: $0.content) },
            stream: stream,
            max_tokens: options.maxTokens,
            temperature: options.temperature,
            thinking: .init(type: "disabled")
        )
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        if let error = try? JSONDecoder().decode(ZhipuErrorResponse.self, from: data) {
            throw AIError.providerError(error.error?.message ?? error.message ?? "智谱请求失败：HTTP \(http.statusCode)。")
        }
        if http.statusCode == 404 {
            let url = Self.chatCompletionsURL(from: endpoint).absoluteString
            throw AIError.providerError("智谱请求失败：HTTP 404。请检查智谱 Base URL，当前请求地址：\(url)")
        }
        throw AIError.providerError("智谱请求失败：HTTP \(http.statusCode)。")
    }
}

private struct ZhipuRequest: Encodable {
    struct Message: Encodable {
        var role: String
        var content: String
    }

    struct Thinking: Encodable {
        var type: String
    }

    var model: String
    var messages: [Message]
    var stream: Bool
    var max_tokens: Int
    var temperature: Double
    var thinking: Thinking?
}

private struct ZhipuResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            var content: String?
        }

        var message: Message?
    }

    var choices: [Choice]
}

private struct ZhipuStreamResponse: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            var content: String?
        }

        var delta: Delta
    }

    var choices: [Choice]
}

private struct ZhipuErrorResponse: Decodable {
    struct ProviderError: Decodable {
        var message: String?
    }

    var error: ProviderError?
    var message: String?
}
