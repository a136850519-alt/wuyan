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
    /// 横幅状态：当前条目在后台被外部更新（同步拉取/天气定位回写），且本地还有
    /// 未保存修改。出现时自动保存暂停，由用户选择「以当前编辑为准」或「重新载入」。
    @Published var externalUpdateDetected = false
    /// 当前条目的旧版本已被同步留档到冲突列表，即使编辑器当时没有未保存输入
    /// 也要给出可见提示。
    @Published var externalConflictCopyDetected = false
    /// R1-4: 缓存非空白字数，避免 View body 中每次 body 变化都 O(n) 重算
    @Published var nonWhitespaceCount: Int = 0

    private var saveTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var isLoading = false
    private weak var appState: AppState?
    /// 加载时的乐观版本，防止后台回写覆盖同步或用户的新编辑。
    private var loadedContentHash: String?
    /// 观察当前打开条目的数据库变化，感知同步等外部改写。
    private var observationTask: Task<Void, Never>?

    deinit {
        observationTask?.cancel()
    }

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

        // R1-4: body 变化时更新缓存字数
        $body
            .sink { [weak self] body in
                self?.nonWhitespaceCount = body.filter { !$0.isWhitespace }.count
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
            self.entry = nil
            loadedContentHash = nil
            externalUpdateDetected = false
            externalConflictCopyDetected = false
            restartObservation(id: nil, appState: appState)
            return
        }

        do {
            guard let fetched = try appState.entries.entry(id: id) else {
                entry = nil
                loadedContentHash = nil
                externalUpdateDetected = false
                externalConflictCopyDetected = false
                restartObservation(id: nil, appState: appState)
                return
            }
            externalUpdateDetected = false
            externalConflictCopyDetected = false
            apply(fetched)
        } catch {
            appState.errorMessage = error.localizedDescription
        }
        restartObservation(id: id, appState: appState)
    }

    /// 把数据库条目应用到编辑器各字段（载入与外部更新静默刷新共用）。
    /// isLoading 保护 Combine 管线：字段回填不应触发自动保存。
    private func apply(_ fetched: Entry) {
        guard let appState else { return }
        isLoading = true
        defer { isLoading = false }
        isDirty = false
        entry = fetched
        loadedContentHash = fetched.contentHash
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
    }

    /// Fields owned by the editor. Metadata and attachment changes can be
    /// rebased without replacing text currently being edited.
    private static func editorFieldsEqual(_ a: Entry, _ b: Entry) -> Bool {
        a.title == b.title && a.body == b.body && a.bodyRTF == b.bodyRTF &&
            a.tags == b.tags && a.mood == b.mood && a.journalDate == b.journalDate &&
            a.dayDate == b.dayDate && a.isFavorite == b.isFavorite &&
            a.boardId == b.boardId && a.deleted == b.deleted
    }

    /// Move the database base forward while retaining editor-owned fields.
    private func rebase(onto fetched: Entry) {
        guard let appState else { return }
        entry = fetched
        loadedContentHash = fetched.contentHash
        mediaAssets = (try? appState.db.mediaAssetDAO.assets(for: fetched.id)) ?? mediaAssets
        isLoading = true
        defer { isLoading = false }
        weatherCondition = fetched.weather?.condition ?? ""
        weatherTemp = fetched.weather.map { String(format: "%.1f", $0.tempC) } ?? ""
        placeName = fetched.location?.placeName ?? ""
        latitude = fetched.location.map { String($0.lat) } ?? ""
        longitude = fetched.location.map { String($0.lon) } ?? ""
    }

    func saveNow(appState: AppState) {
        // UI-07：救援模式下数据库不可信，禁止制造「已保存」假象
        guard !appState.isRescueMode else {
            appState.errorMessage = "救援模式：数据库未正常加载，当前内容不会被保存。请先导出救援副本。"
            return
        }
        // UI-02：归档进行中的年份锁定编辑，防止上传后本地删除丢掉新编辑
        if let archiving = appState.archivingYear,
           archiving == AppState.year(fromDayKey: DayKey.string(from: journalDate)) {
            externalUpdateDetected = true
            return
        }
        guard var entry else { return }
        applyEditorFields(to: &entry)

        do {
            try appState.entries.save(entry, expectedContentHash: loadedContentHash)
            self.entry = try appState.entries.entry(id: entry.id) ?? entry
            loadedContentHash = self.entry?.contentHash
            self.isDirty = false
            self.lastSavedAt = Date()
            appState.refreshRemindersForToday()
            // 通知自动同步防抖：编辑保存后 5 分钟自动同步
            appState.syncCoordinator.notifyEditCompleted()
        } catch EntrySaveError.concurrentModification {
            // The observation stream may arrive after this save. If only
            // metadata/attachments changed, rebase and retry once immediately.
            if let fresh = try? appState.entries.entry(id: entry.id),
               let current = self.entry,
               Self.editorFieldsEqual(fresh, current) {
                rebase(onto: fresh)
                var retry = fresh
                applyEditorFields(to: &retry)
                do {
                    try appState.entries.save(retry, expectedContentHash: fresh.contentHash)
                    self.entry = try appState.entries.entry(id: retry.id) ?? retry
                    loadedContentHash = self.entry?.contentHash
                    isDirty = false
                    externalUpdateDetected = false
                    lastSavedAt = Date()
                    appState.refreshRemindersForToday()
                    appState.syncCoordinator.notifyEditCompleted()
                    return
                } catch EntrySaveError.concurrentModification {
                    // A second concurrent edit is a real conflict; preserve it
                    // through the regular banner/flush path below.
                } catch {
                    appState.errorMessage = error.localizedDescription
                    return
                }
            }
            markExternalUpdateDetected()
        } catch EntrySaveError.entryRemoved {
            preserveRemovedEntryAsNewEntry(appState: appState)
            self.entry = nil
            loadedContentHash = nil
            isDirty = false
            externalUpdateDetected = false
            externalConflictCopyDetected = false
            appState.selectedEntryId = nil
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }

    /// 把编辑器字段写回条目（自动保存与「以当前编辑为准」共用）。
    /// 天气/定位不由编辑器改动，保留传入条目上的现有值。
    private func applyEditorFields(to entry: inout Entry) {
        entry.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : title
        entry.body = body
        entry.bodyRTF = bodyRTF
        entry.tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        entry.mood = mood
        entry.journalDate = journalDate
        // UI-08①（已确认）：改「记录时间」即改归属日——按天分组与年度归档
        // 跟随用户认定的日期；跨年修改会同时移动归档年份。
        entry.dayDate = DayKey.string(from: journalDate)
        entry.isFavorite = isFavorite
        if let boardId {
            entry.boardId = boardId
        }
    }

    func delete(appState: AppState) {
        guard !appState.isRescueMode else {
            appState.errorMessage = "救援模式：删除已禁用。"
            return
        }
        guard let id = entry?.id else { return }
        // UI-02：归档进行中的年份锁定删除操作
        if let archiving = appState.archivingYear,
           archiving == AppState.year(fromDayKey: DayKey.string(from: journalDate)) {
            externalUpdateDetected = true
            return
        }
        // Flush the final debounce window before moving the row to the trash.
        flushIfNeeded(appState: appState)
        guard !isDirty else { return }
        do {
            try appState.entries.softDelete(id: id)
            appState.syncCoordinator.notifyEditCompleted()
            appState.selectedEntryId = nil
            entry = nil
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }

    func importMedia(urls: [URL], appState: AppState, entryId: UUID? = nil, cleanupAfterImport: [URL] = []) {
        guard !appState.isRescueMode else {
            appState.errorMessage = "救援模式：附件导入已禁用。"
            return
        }
        // UI-09③：允许显式指定归属条目（录音停止时导入到录音开始时绑定的条目）；
        // 未指定时导入到当前编辑的条目。
        guard let targetId = entryId ?? entry?.id else { return }
        Task {
            do {
                for url in urls {
                    _ = try await appState.mediaStore.importMedia(url, entryId: targetId)
                }
                appState.syncCoordinator.notifyEditCompleted()
                for url in cleanupAfterImport {
                    try? FileManager.default.removeItem(at: url)
                }
                await MainActor.run {
                    if self.entry?.id == targetId {
                        if self.isDirty,
                           let latest = try? appState.entries.entry(id: targetId) {
                            self.rebase(onto: latest)
                        } else {
                            self.load(id: targetId, appState: appState)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    appState.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func saveMetadata(appState: AppState) {
        // UI-07：救援模式禁止写入
        guard !appState.isRescueMode else {
            appState.errorMessage = "救援模式：数据库未正常加载，当前修改不会被保存。"
            return
        }
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
            try appState.entries.save(entry, expectedContentHash: loadedContentHash)
            self.entry = try appState.entries.entry(id: entry.id) ?? entry
            loadedContentHash = self.entry?.contentHash
            externalUpdateDetected = false
            appState.syncCoordinator.notifyEditCompleted()
        } catch EntrySaveError.concurrentModification {
            markExternalUpdateDetected()
        } catch EntrySaveError.entryRemoved {
            preserveRemovedEntryAsNewEntry(appState: appState)
            self.entry = nil
            loadedContentHash = nil
            isDirty = false
            externalUpdateDetected = false
            externalConflictCopyDetected = false
            appState.selectedEntryId = nil
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }

    /// 暂停自动保存并亮出冲突横幅（不弹全局 alert）。
    private func markExternalUpdateDetected() {
        externalUpdateDetected = true
        saveTask?.cancel()
        saveTask = nil
    }

    /// 横幅「以当前编辑为准」：在数据库最新版本上叠加编辑器字段后保存。
    /// 条目以数据库版本为底稿，天气/定位等后台字段不会被旧值覆盖；
    /// 若条目已不存在（如被其它设备删除），回退为重新载入。
    func keepCurrentEdits(appState: AppState) {
        guard let current = entry,
              var fresh = try? appState.entries.entry(id: current.id) else {
            preserveRemovedEntryAsNewEntry(appState: appState)
            entry = nil
            loadedContentHash = nil
            isDirty = false
            return
        }
        applyEditorFields(to: &fresh)
        do {
            try appState.entries.save(fresh, expectedContentHash: fresh.contentHash)
            self.entry = try appState.entries.entry(id: fresh.id) ?? fresh
            loadedContentHash = self.entry?.contentHash
            isDirty = false
            externalUpdateDetected = false
            lastSavedAt = Date()
            appState.syncCoordinator.notifyEditCompleted()
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }

    /// 横幅「重新载入」：放弃未保存的编辑，以数据库当前版本为准。
    func reloadFromDatabase(appState: AppState) {
        guard let id = entry?.id else { return }
        load(id: id, appState: appState)
    }

    /// 将当前条目的未落盘变更立即同步写出（切换条目/退出时调用）
    func flushIfNeeded(appState: AppState) {
        guard isDirty, entry != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        saveNow(appState: appState)
        if isDirty {
            preserveUnsavedEdits(appState: appState)
        }
    }

    /// Persist a draft when a conflict prevents the normal save. This runs for
    /// every flush entry point so switching views or terminating cannot discard
    /// the user's text.
    private func preserveUnsavedEdits(appState: AppState, detachMedia: Bool = false) {
        guard var draft = entry, isDirty else { return }
        applyEditorFields(to: &draft)
        if detachMedia { draft.mediaIds = [] }
        draft.refreshForSave()
        do {
            let board = try appState.boards.board(id: draft.boardId)
            let assets = detachMedia ? [] : mediaAssets
            let envelope = try JSONEncoder.wuyan.encode(
                EntryEnvelope(entry: draft, board: board, dayNote: nil, mediaAssets: assets)
            )
            if try !appState.entries.hasConflictCopy(id: draft.id) {
                try appState.entries.saveConflictCopy(entry: draft, envelope: envelope, remotePath: "local-editor")
                let label = draft.title ?? String(draft.body.prefix(20))
                appState.errorMessage = "「\(label)」在后台被更新，你尚未保存的修改已另存，可在『设置 › 冲突列表』中对比恢复。"
            } else {
                var detached = draft
                detached.id = UUID()
                detached.title = "【未保存的编辑】" + (draft.title ?? "")
                detached.mediaIds = []
                detached.refreshForSave()
                try appState.entries.saveResolvedConflict(
                    entry: detached, board: board, dayNote: nil, mediaAssets: []
                )
                let label = draft.title ?? String(draft.body.prefix(20))
                appState.errorMessage = "「\(label)」已有待处理冲突，未保存的修改已另存为新日记「\(detached.title ?? "未保存的编辑")」。"
            }
        } catch {
            appState.errorMessage = "未保存的编辑无法留档：\(error.localizedDescription)"
        }
    }

    /// A removed entry can no longer safely be restored under its original ID:
    /// doing so would resurrect the remote tombstone and lose its attachments.
    /// Keep the user's text as an independent diary entry instead.
    private func preserveRemovedEntryAsNewEntry(appState: AppState) {
        guard var draft = entry, isDirty else { return }
        applyEditorFields(to: &draft)
        let originalTitle = draft.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        draft.id = UUID()
        draft.title = "【未保存的编辑】" + (originalTitle.isEmpty ? "" : originalTitle)
        draft.mediaIds = []
        draft.refreshForSave()
        do {
            let board = try appState.boards.board(id: draft.boardId)
            try appState.entries.saveResolvedConflict(
                entry: draft, board: board, dayNote: nil, mediaAssets: []
            )
            let label = draft.title ?? "未保存的编辑"
            appState.errorMessage = "原条目已被移除，未保存的内容已另存为新日记「\(label)」。"
        } catch {
            appState.errorMessage = "未保存的编辑无法另存：\(error.localizedDescription)"
        }
    }

    /// 切换观察目标。观察流在数据库事务提交时逐条回报，循环体在主 actor 上执行。
    private func restartObservation(id: UUID?, appState: AppState) {
        observationTask?.cancel()
        observationTask = nil
        guard let id else { return }
        observationTask = Task { [weak self] in
            for await updated in appState.entries.observeEntry(id: id) {
                self?.handleObservedEntry(updated, appState: appState)
            }
        }
    }

    /// 外部改写当前条目（同步拉取/天气定位回写/其它设备）时的处理：
    /// - 无未保存修改：静默应用新版本，编辑器与数据库保持一致；
    /// - 有未保存修改：暂停自动保存并亮横幅，由用户选择保留编辑或重新载入。
    private func handleObservedEntry(_ fetched: Entry?, appState: AppState) {
        guard let fetched else {
            guard entry != nil else { return }
            preserveRemovedEntryAsNewEntry(appState: appState)
            entry = nil
            loadedContentHash = nil
            isDirty = false
            externalUpdateDetected = false
            externalConflictCopyDetected = false
            appState.selectedEntryId = nil
            return
        }
        guard let current = entry, fetched.id == current.id else { return }
        // 自己刚保存的版本与已知版本不处理，避免自触发的回环。
        guard fetched.contentHash != loadedContentHash else { return }
        if !isDirty {
            apply(fetched)
            externalConflictCopyDetected = (try? appState.entries.hasConflictCopy(id: fetched.id)) == true
        } else if let current = entry, Self.editorFieldsEqual(fetched, current) {
            rebase(onto: fetched)
        } else if !externalUpdateDetected {
            markExternalUpdateDetected()
        }
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
                self.saveTask = nil
            }
        }
    }
}
