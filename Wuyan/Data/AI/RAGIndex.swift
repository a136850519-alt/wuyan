import Foundation
import CryptoKit

struct RAGChunk: Codable, Equatable, Identifiable {
    var id: String
    var entryId: UUID
    var entryHash: String
    var text: String
    var embedding: [Float]
    var updatedAt: Date
}

actor RAGIndexStore {
    private let url: URL
    private let provider: AIProvider

    init(provider: AIProvider) throws {
        self.provider = provider
        let directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Wuyan/AI", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identity = provider.destinationDescription
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(16)
        // 不同 provider/地址/模型不能共享 embedding 缓存；否则切换模型后相似度
        // 仍会使用旧向量，结果看似成功但语义已经失真。
        self.url = directory.appendingPathComponent("rag-index-\(digest).json")
    }

    func topChunks(for question: String, entries: [Entry], limit: Int = 6) async throws -> [RAGChunk] {
        var currentChunks: [String: (entry: Entry, text: String)] = [:]
        for entry in entries {
            for (index, text) in chunkTexts(for: entry).enumerated() {
                let id = "\(entry.id.uuidString)-\(entry.contentHash)-\(index)"
                currentChunks[id] = (entry, text)
            }
        }
        let validChunkIds = Set(currentChunks.keys)
        var chunks = try load().compactMap { cached -> RAGChunk? in
            guard let current = currentChunks[cached.id] else { return nil }
            var hydrated = cached
            // 缓存只保存向量和身份信息，正文每次从当前条目恢复，避免在磁盘留下第二份明文日记。
            hydrated.text = current.text
            return hydrated
        }

        var existingIds = Set(chunks.map(\.id))
        var pending: [(id: String, entry: Entry, text: String)] = []
        for entry in entries where !entry.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let texts = chunkTexts(for: entry)
            for (index, text) in texts.enumerated() {
                try Task.checkCancellation()
                let id = "\(entry.id.uuidString)-\(entry.contentHash)-\(index)"
                guard !existingIds.contains(id) else { continue }
                existingIds.insert(id)
                pending.append((id: id, entry: entry, text: text))
            }
        }

        var newChunks: [RAGChunk] = []
        if !pending.isEmpty {
            try Task.checkCancellation()
            let embeddings = try await provider.embed(pending.map(\.text))
            guard embeddings.count == pending.count else {
                throw AIError.providerError("AI 嵌入服务返回的向量数量不匹配。")
            }
            newChunks = zip(pending, embeddings).map { item, embedding in
                RAGChunk(id: item.id, entryId: item.entry.id, entryHash: item.entry.contentHash, text: item.text, embedding: embedding, updatedAt: Date())
            }
        }

        chunks = chunks.filter { validChunkIds.contains($0.id) }
        chunks.append(contentsOf: newChunks)
        try save(chunks)

        try Task.checkCancellation()
        let questionEmbedding = try await provider.embed([question]).first ?? []
        return chunks
            .map { (chunk: $0, score: cosine(questionEmbedding, $0.embedding)) }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.chunk)
    }

    private func chunkTexts(for entry: Entry) -> [String] {
        let title = entry.title.map { "\($0)\n\n" } ?? ""
        let text = title + entry.body
        let maxLength = 800
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: maxLength, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[start..<end]))
            start = end
        }
        return chunks
    }

    private func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot: Double = 0
        var left: Double = 0
        var right: Double = 0
        for index in lhs.indices {
            let a = Double(lhs[index])
            let b = Double(rhs[index])
            dot += a * b
            left += a * a
            right += b * b
        }
        guard left > 0, right > 0 else { return 0 }
        return dot / (sqrt(left) * sqrt(right))
    }

    private func load() throws -> [RAGChunk] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder.wuyan.decode([RAGChunk].self, from: data)
    }

    private func save(_ chunks: [RAGChunk]) throws {
        let persisted = chunks.map { chunk -> RAGChunk in
            var redacted = chunk
            redacted.text = ""
            return redacted
        }
        let data = try JSONEncoder.wuyan.encode(persisted)
        try data.write(to: url, options: .atomic)
    }
}
