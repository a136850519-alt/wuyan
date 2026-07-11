import Combine
import Foundation

enum SidebarSelection: Hashable {
    case all
    case favorites
    case drafts
    case todayInHistory
    case calendar
    case settings
    case trash
    case board(UUID)
    case year(Int)
    case yearBoard(Int, UUID)

    var boardId: UUID? {
        if case let .board(id) = self {
            return id
        }
        if case let .yearBoard(_, id) = self {
            return id
        }
        return nil
    }
}

@MainActor
final class AppState: ObservableObject {
    let db: AppDatabase
    let boards: BoardDAO
    let entries: EntryDAO
    let dayNotes: DayNoteDAO
    let aiService: AIService
    var poeticGenerator: PoeticGenerator { aiService }
    let mediaStore: LocalMediaStore
    let locationMetadata = LocationMetadataService()
    let audioRecorder = AudioRecorder()
    let syncCoordinator: SyncCoordinator

    @Published var sidebarSelection: SidebarSelection = .all
    @Published var selectedEntryId: UUID?
    @Published var isShowingRitual = false
    @Published var boardChooserDay: String?
    /// 全局错误信息：同步错误和其他运行时错误统一汇聚于此，由 RootView 弹出 alert。
    @Published var errorMessage: String?
    /// 全局云端 AI 信任标记：同一会话内确认一次后，AIAssistantView 和 RitualView 共享。
    @Published var trustCloudForSession = false
    /// 已归档年份（本地内容已删除、仅存于 NAS）。按降序排列。
    @Published var archivedYears: [Int] = []

    // 同步状态前向属性（兼容已有视图引用）
    var syncMessage: String? { syncCoordinator.syncMessage }
    var syncProgress: SyncProgress? { syncCoordinator.syncProgress }
    var syncConflicts: [UUID] { syncCoordinator.syncConflicts }

    /// 订阅 SyncCoordinator 的 objectWillChange，使其 @Published 变化能触发本对象 UI 刷新。
    private var syncCancellable: AnyCancellable?

    private static let archivedYearsKey = "archive.years"

    init(database: AppDatabase) {
        self.db = database
        self.boards = database.boardDAO
        self.entries = database.entryDAO
        self.dayNotes = database.dayNoteDAO
        self.mediaStore = try! LocalMediaStore(database: database)
        self.syncCoordinator = SyncCoordinator(database: database)
        self.aiService = AIService(
            provider: ProviderFactory.makeAIProvider(),
            isEnabled: AppSettings.aiEnabled,
            ritualPolishingEnabled: AppSettings.aiRitual
        )
        self.aiService.cloudBlockedBoardIds = Self.cloudBlockedBoardIds(boards)
        let stored = UserDefaults.standard.array(forKey: Self.archivedYearsKey) as? [Int] ?? []
        self.archivedYears = stored.sorted(by: >)

        // R0-1: 将 SyncCoordinator 的 objectWillChange 转发到 AppState，
        // 使 SettingsView/SidebarView 通过 appState.syncProgress 等计算属性读取时能刷新。
        self.syncCancellable = syncCoordinator.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        // R0-1: 将 SyncCoordinator 的错误统一汇聚到 AppState.errorMessage，供 RootView alert 展示。
        syncCoordinator.onError = { [weak self] message in
            self?.errorMessage = message
        }
        // R0-2: 归档成功后将该年加入 archivedYears 并持久化
        syncCoordinator.onArchiveComplete = { [weak self] year in
            guard let self else { return }
            var years = Set(self.archivedYears)
            years.insert(year)
            self.setArchivedYears(years)
        }
        // R0-2: 下载成功后将该年从 archivedYears 移除并持久化
        syncCoordinator.onDownloadComplete = { [weak self] year in
            guard let self else { return }
            var years = Set(self.archivedYears)
            years.remove(year)
            self.setArchivedYears(years)
        }
    }

    /// 更新 archivedYears 并持久化到 UserDefaults。
    /// R0-2: 改为 internal 以便 SyncCoordinator 回调链路可达。
    func setArchivedYears(_ years: Set<Int>) {
        let sorted = years.sorted(by: >)
        archivedYears = sorted
        UserDefaults.standard.set(sorted, forKey: Self.archivedYearsKey)
    }

    private static func cloudBlockedBoardIds(_ boards: BoardDAO) -> Set<UUID> {
        let all = (try? boards.all()) ?? []
        return Set(all.filter(\.disallowCloudAI).map(\.id))
    }

    var selectedBoardId: UUID? {
        get { sidebarSelection.boardId }
        set {
            if let newValue {
                let year = Self.year(fromDayKey: DayKey.today)
                sidebarSelection = .yearBoard(year, newValue)
            } else {
                sidebarSelection = .all
            }
        }
    }

    func showNewEntryRitual() {
        isShowingRitual = true
    }

    func showBoardChooser(day: String) {
        boardChooserDay = day
    }

    func openEntry(id: UUID) {
        do {
            guard let entry = try entries.entry(id: id) else {
                selectedEntryId = nil
                return
            }
            let year = Self.year(fromDayKey: entry.dayDate)
            sidebarSelection = .yearBoard(year, entry.boardId)
            selectedEntryId = entry.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectEntry(_ entry: Entry?) {
        selectedEntryId = entry?.id
    }

    /// 永久删除条目，并清理「已无其它条目引用」的本地媒体文件。
    func permanentlyDelete(entryId: UUID) {
        do {
            let assets = (try? entries.entry(id: entryId)).flatMap { try? db.mediaAssetDAO.allAssets(for: $0.mediaIds) } ?? []
            try entries.permanentlyDelete(id: entryId)
            for asset in assets where ((try? db.mediaAssetDAO.referenceCount(sha256: asset.sha256)) ?? 1) == 0 {
                try? mediaStore.removeLocalFiles(for: asset)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 同步前向方法

    func syncNow() {
        syncCoordinator.syncNow(archivedYears: Set(archivedYears))
    }

    func archiveYearToRemote(_ year: Int) {
        syncCoordinator.archiveYearToRemote(year, archivedYears: Set(archivedYears))
        // 归档成功后由调用方更新 archivedYears
    }

    func downloadYearFromRemote(_ year: Int) {
        syncCoordinator.downloadYearFromRemote(year)
        // 下载成功后由调用方更新 archivedYears
    }

    func enrichEntryMetadataIfNeeded(_ entryId: UUID) {
        guard AppSettings.metadataEnabled else { return }
        Task {
            guard let location = await locationMetadata.requestLocation(),
                  var entry = try? entries.entry(id: entryId)
            else { return }
            let placeName = await locationMetadata.geocode(location)
            entry.location = GeoPlace(lat: location.coordinate.latitude, lon: location.coordinate.longitude, placeName: placeName)
            if let weather = try? await OpenMeteoService().current(lat: location.coordinate.latitude, lon: location.coordinate.longitude) {
                entry.weather = weather
            }
            try? entries.save(entry)
        }
    }

    func refreshRemindersForToday() {
        guard AppSettings.reminderEnabled else { return }
        let times = Self.reminderTimesFromDefaults()
        Task {
            let today = Date().dayKey
            let hasWrittenToday = ((try? entries.timeline(filter: .day(today))) ?? []).isEmpty == false
            await ReminderScheduler().refreshForToday(hasWrittenToday: hasWrittenToday, times: times)
        }
    }

    func reloadAISettings() {
        aiService.provider = ProviderFactory.makeAIProvider()
        aiService.isEnabled = AppSettings.aiEnabled
        aiService.ritualPolishingEnabled = AppSettings.aiRitual
        aiService.cloudBlockedBoardIds = Self.cloudBlockedBoardIds(boards)
    }

    // MARK: - 静态辅助（无状态）

    static func reminderTimesFromDefaults() -> [DateComponents] {
        let stored = AppSettings.reminderTimes
        return stored.compactMap { value in
            let parts = value.split(separator: ":").compactMap { Int(String($0)) }
            guard parts.count == 2 else { return nil }
            return DateComponents(hour: parts[0], minute: parts[1])
        }
    }

    static func saveReminderTimesToDefaults(_ dates: [Date]) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        UserDefaults.standard.set(dates.map { formatter.string(from: $0) }, forKey: SettingKey.reminderTimes)
    }

    static func year(fromDayKey dayKey: String) -> Int {
        Int(dayKey.prefix(4)) ?? Calendar.current.component(.year, from: Date())
    }

    static func reminderDatesFromDefaults() -> [Date] {
        let calendar = Calendar.current
        return reminderTimesFromDefaults().compactMap { components in
            calendar.date(bySettingHour: components.hour ?? 21, minute: components.minute ?? 30, second: 0, of: Date())
        }
    }
}
