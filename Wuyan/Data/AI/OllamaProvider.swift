import Foundation

struct OllamaProvider: AIProvider {
    var endpoint: URL
    var model: String
    var embeddingModel: String
    var session: URLSession = .shared

    var isLocal: Bool { true }

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
            Task {
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
                    continuation.finish(throwing: error)
                }
            }
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
