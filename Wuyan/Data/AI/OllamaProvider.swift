import Foundation

struct OllamaProvider: AIProvider {
    var endpoint: URL
    var model: String
    var embeddingModel: String
    var session: URLSession = .shared

    /// S04/UI-05：「本地」必须基于实际目的地址判断，不能因为 provider 叫 Ollama 就视为本地。
    /// 仅回环地址（localhost / 127.x / ::1）视为本地；用户填写的局域网或公网地址
    /// 一律按远程服务对待——必须经云 AI 授权确认，且受私密板块过滤约束。
    var isLocal: Bool { Self.isLoopback(endpoint) }
    var supportsEmbeddings: Bool { true }

    static func isLoopback(_ endpoint: URL) -> Bool {
        guard let host = endpoint.host?.lowercased() else { return false }
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        // 127.0.0.0/8 整段都是回环，但必须先确认是合法 IPv4，避免把
        // 127.example.com 这类公网域名误当成本机地址。
        let octets = host.split(separator: ".")
        if octets.count == 4,
           octets.allSatisfy({ part in
               guard let value = Int(part), String(value) == String(part) || part == "0" else { return false }
               return (0...255).contains(value)
           }),
           octets.first == "127" { return true }
        return false
    }

    var destinationDescription: String {
        "Ollama（\(endpoint.absoluteString)，对话模型 \(model)，嵌入模型 \(embeddingModel)）"
    }

    private var hostDisplay: String {
        endpoint.host ?? endpoint.absoluteString
    }

    func complete(_ messages: [AIMessage], options: AIOptions) async throws -> String {
        let requestBody = OllamaChatRequest(model: model, messages: messages.map { .init(role: $0.role.rawValue, content: $0.content) }, stream: false, options: .init(temperature: options.temperature, num_predict: options.maxTokens))
        var request = URLRequest(url: endpoint.appendingPathComponent("/api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)
        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
        return response.message.content
    }

    func stream(_ messages: [AIMessage], options: AIOptions) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let requestBody = OllamaChatRequest(model: model, messages: messages.map { .init(role: $0.role.rawValue, content: $0.content) }, stream: true, options: .init(temperature: options.temperature, num_predict: options.maxTokens))
                    var request = URLRequest(url: endpoint.appendingPathComponent("/api/chat"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONEncoder().encode(requestBody)
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw AIError.missingConfiguration
                    }
                    for try await line in bytes.lines {
                        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        let data = Data(line.utf8)
                        let chunk = try JSONDecoder().decode(OllamaChatStreamResponse.self, from: data)
                        if !chunk.message.content.isEmpty {
                            continuation.yield(chunk.message.content)
                        }
                        if chunk.done {
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled { continuation.finish() }
                    else { continuation.finish(throwing: error) }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        try await texts.asyncMap { text in
            let body = OllamaEmbeddingRequest(model: embeddingModel, prompt: text)
            var request = URLRequest(url: endpoint.appendingPathComponent("/api/embeddings"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
            let (data, _) = try await session.data(for: request)
            return try JSONDecoder().decode(OllamaEmbeddingResponse.self, from: data).embedding
        }
    }
}

private struct OllamaChatRequest: Encodable {
    struct Message: Encodable {
        var role: String
        var content: String
    }
    struct Options: Encodable {
        var temperature: Double
        var num_predict: Int
    }
    var model: String
    var messages: [Message]
    var stream: Bool
    var options: Options
}

private struct OllamaChatResponse: Decodable {
    struct Message: Decodable {
        var content: String
    }
    var message: Message
}

private struct OllamaChatStreamResponse: Decodable {
    struct Message: Decodable {
        var content: String
    }
    var message: Message
    var done: Bool
}

private struct OllamaEmbeddingRequest: Encodable {
    var model: String
    var prompt: String
}

private struct OllamaEmbeddingResponse: Decodable {
    var embedding: [Float]
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async throws -> [T] {
        var values: [T] = []
        for element in self {
            try await values.append(transform(element))
        }
        return values
    }
}
