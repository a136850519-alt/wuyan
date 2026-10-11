import Foundation

struct AIRequestOutput {
    var text: String
    var sources: [UUID] = []
    var retrievalNote: String? = nil
}

/// 每次动作有独立身份。停止、离开或新动作后，旧服务即使继续返回也无法更新界面。
@MainActor
final class AIRequestState: ObservableObject {
    @Published private(set) var output: AIRequestOutput?
    @Published private(set) var error: String?
    @Published private(set) var isRunning = false
    private var token = UUID()
    private var task: Task<Void, Never>?

    func run(_ work: @escaping @MainActor () async throws -> AIRequestOutput) {
        cancel()
        let identity = token
        isRunning = true
        error = nil
        task = Task { [weak self] in
            do {
                let result = try await work()
                guard let self, !Task.isCancelled, self.token == identity else { return }
                self.output = result
                self.isRunning = false
                self.task = nil
            } catch {
                guard let self, !Task.isCancelled, self.token == identity else { return }
                self.error = error.localizedDescription
                self.isRunning = false
                self.task = nil
            }
        }
    }
    func cancel() { token = UUID(); task?.cancel(); task = nil; isRunning = false }
    func reset() { cancel(); output = nil; error = nil }
    deinit { task?.cancel() }
}
