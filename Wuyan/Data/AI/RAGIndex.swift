import Foundation

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
        self.url = directory.appendingPathComponent("rag-index.json")
    }

    func topChunks(for question: String, entries: [Entry], limit: Int = 6) async throws -> [RAGChunk] {
        var chunks = try load()
        let validChunkIds = Set(entries.flatMap { entry in
            chunkTexts(for: entry).indices.map { index in
                "\(entry.id.uuidString)-\(entry.contentHash)-\(index)"
            }
        })

        var existingIds = Set(chunks.map(\.id))
        var newChunks: [RAGChunk] = []
        for entry in entries where !entry.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let texts = chunkTexts(for: entry)
            for (index, text) in texts.enumerated() {
                let id = "\(entry.id.uuidString)-\(entry.contentHash)-\(index)"
                guard !existingIds.contains(id) else { continue }
                let embedding = try await provider.embed([text]).first ?? []
                newChunks.append(RAGChunk(id: id, entryId: entry.id, entryHash: entry.contentHash, text: text, embedding: embedding, updatedAt: Date()))
                existingIds.insert(id)
            }
        }

        chunks = chunks.filter { validChunkIds.contains($0.id) }
        chunks.append(contentsOf: newChunks)
        try save(chunks)

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
        let data = try JSONEncoder.wuyan.encode(chunks)
        try data.write(to: url, options: .atomic)
    }
}
