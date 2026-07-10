import Combine
import Foundation

@MainActor
final class EditorViewModel: ObservableObject {
    @Published var entry: Entry?
    @Published var title = ""
    @Published var body = ""
    @Published var bodyRTF: Data?
    @Published var tagsText = ""
    @Published var mood: Int?
    @Published var journalDate = Date()
    @Published var isFavorite = false
    @Published var boardId: UUID?
    @Published var mediaAssets: [MediaAsset] = []
    @Published var weatherCondition = ""
    @Published var weatherTemp = ""
    @Published var placeName = ""
    @Published var latitude = ""
    @Published var longitude = ""
    @Published var isDirty = false
    @Published var lastSavedAt: Date?

    private var saveTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var isLoading = false
    private weak var appState: AppState?

    init() {
        Publishers.CombineLatest4($title, $body, $tagsText, $mood)
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleSave()
            }
            .store(in: &cancellables)

        $bodyRTF
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleSave()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3($journalDate, $isFavorite, $boardId)
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleSave()
            }
            .store(in: &cancellables)
    }

    func configure(appState: AppState) {
        self.appState = appState
    }

    func load(id: UUID?, appState: AppState) {
        configure(appState: appState)
        // 切换条目前先 flush 当前未落盘的变更，防丢失最后 0.5 秒输入
        flushIfNeeded(appState: appState)
        saveTask?.cancel()
        saveTask = nil
        guard let id else {
            entry = nil
            return
        }

        do {
            guard let fetched = try appState.entries.entry(id: id) else {
                entry = nil
                return
            }
            isLoading = true
            isDirty = false
            entry = fetched
            title = fetched.title ?? ""
            body = fetched.body
            bodyRTF = fetched.bodyRTF
            tagsText = fetched.tags.joined(separator: ", ")
            mood = fetched.mood
            journalDate = fetched.journalDate
            isFavorite = fetched.isFavorite
            boardId = fetched.boardId
            mediaAssets = (try? appState.db.mediaAssetDAO.assets(for: fetched.id)) ?? []
            weatherCondition = fetched.weather?.condition ?? ""
            weatherTemp = fetched.weather.map { String(format: "%.1f", $0.tempC) } ?? ""
            placeName = fetched.location?.placeName ?? ""
            latitude = fetched.location.map { String($0.lat) } ?? ""
            longitude = fetched.location.map { String($0.lon) } ?? ""
            isLoading = false
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }

    func saveNow(appState: AppState) {
        guard var entry else { return }
        entry.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : title
        entry.body = body
        entry.bodyRTF = bodyRTF
        entry.tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        entry.mood = mood
        entry.journalDate = journalDate
        entry.isFavorite = isFavorite
        if let boardId {
            entry.boardId = boardId
        }

        do {
            try appState.entries.save(entry)
            self.entry = try appState.entries.entry(id: entry.id) ?? entry
            self.isDirty = false
            self.lastSavedAt = Date()
            appState.refreshRemindersForToday()
            // 通知自动同步防抖：编辑保存后 5 分钟自动同步
            appState.syncCoordinator.notifyEditCompleted()
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }

    func delete(appState: AppState) {
        guard let id = entry?.id else { return }
        do {
            try appState.entries.softDelete(id: id)
            appState.selectedEntryId = nil
            entry = nil
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }

    func importMedia(urls: [URL], appState: AppState) {
        guard let entry else { return }
        Task {
            do {
                for url in urls {
                    _ = try await appState.mediaStore.importMedia(url, entryId: entry.id)
                }
                await MainActor.run {
                    self.load(id: entry.id, appState: appState)
                }
            } catch {
                await MainActor.run {
                    appState.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func saveMetadata(appState: AppState) {
        guard var entry else { return }
        let condition = weatherCondition.trimmingCharacters(in: .whitespacesAndNewlines)
        if !condition.isEmpty {
            if let temp = Double(weatherTemp.trimmingCharacters(in: .whitespacesAndNewlines)) {
                entry.weather = Weather(condition: condition, tempC: temp)
            } else {
                // 温度解析失败：保留原天气，显示校验错误
                if entry.weather != nil {
                    appState.errorMessage = "温度格式不正确，天气信息保留原值。"
                } else {
                    // 原来没有天气，只能放弃本次设置
                    appState.errorMessage = "温度格式不正确，请输入有效数字。"
                }
            }
        } else {
            entry.weather = nil
        }

        let place = placeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !place.isEmpty {
            if let lat = Double(latitude), let lon = Double(longitude),
               (-90...90).contains(lat), (-180...180).contains(lon) {
                entry.location = GeoPlace(lat: lat, lon: lon, placeName: place)
            } else {
                // 经纬度解析失败或超范围：保留原地点，显示校验错误
                if entry.location != nil {
                    appState.errorMessage = "经纬度格式不正确或超范围，地点信息保留原值。"
                } else {
                    appState.errorMessage = "经纬度格式不正确，请输入有效数值（纬度 -90~90，经度 -180~180）。"
                }
            }
        } else {
            entry.location = nil
        }

        do {
            try appState.entries.save(entry)
            self.entry = try appState.entries.entry(id: entry.id) ?? entry
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }

    /// 将当前条目的未落盘变更立即同步写出（切换条目/退出时调用）
    func flushIfNeeded(appState: AppState) {
        guard saveTask != nil, entry != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        saveNow(appState: appState)
    }

    private func scheduleSave() {
        guard !isLoading else { return }
        isDirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, let appState = self.appState else { return }
                self.saveNow(appState: appState)
            }
        }
    }
}
