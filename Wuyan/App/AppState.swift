import Combine
import Foundation
import AppKit
import Quartz

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
    /// 全局云端 AI 信任标记：绑定到「provider + 实际目的地」标识（S04/UI-05）。
    /// 同一会话内对同一目的地确认一次后共享；配置变更（换 provider / 改地址）后
    /// 标识变化，旧授权自动失效，需要重新确认。
    @Published var trustCloudDestination: String?
    /// 已归档年份（本地内容已删除、仅存于 NAS）。按降序排列。
    @Published var archivedYears: [Int] = []
    /// UI-02（已确认）：归档进行中的年份——该年份内容锁定编辑，防止归档后本地删除丢掉新编辑。
    @Published var archivingYear: Int?
    @Published var pendingDeleteEntryId: UUID?
    /// 导入/导出任务跨设置页生命周期互斥，避免离开页面后重复还原。
    @Published var isBackupTaskRunning = false
    /// 日记访问锁状态在所有窗口共享。启用后应用启动即锁定。
    @Published private(set) var isDiaryLocked: Bool
    @Published private(set) var isDiaryPasswordEnabled: Bool
    @Published private(set) var diaryIdleTimeoutMinutes: Int
    /// UI-07：数据库打开失败的只读救援模式。禁止编辑与同步，提供救援副本导出。
    let isRescueMode: Bool

    var diaryCredentialUnavailable: Bool {
        if case .unavailable = DiaryLockStore.credentialState { return true }
        return false
    }

    /// Used by RootView before the idle timer gets a chance to fire, so reopening
    /// a window after a long idle period never renders the diary for one frame.
    var shouldPresentDiaryLock: Bool {
        guard isDiaryPasswordEnabled else { return false }
        if isDiaryLocked { return true }
        let timeout = AppSettings.diaryIdleTimeoutSeconds
        return timeout > 0 && Date().timeIntervalSince(diaryLastActivity) >= timeout
    }

    // 同步状态前向属性（兼容已有视图引用）
    var syncMessage: String? { syncCoordinator.syncMessage }
    var syncProgress: SyncProgress? { syncCoordinator.syncProgress }
    var syncConflicts: [UUID] { syncCoordinator.syncConflicts }

    /// 订阅 SyncCoordinator 的 objectWillChange，使其 @Published 变化能触发本对象 UI 刷新。
    private var syncCancellable: AnyCancellable?
    private var lastReminderRefresh: (dayKey: String, hasWrittenToday: Bool)?
    private var diaryLastActivity = Date()
    private var diaryActivityMonitor: Any?
    private var diaryNotificationTokens: [NSObjectProtocol] = []
    private var diaryDistributedNotificationTokens: [NSObjectProtocol] = []
    private var diaryUnlockThrottle = DiaryUnlockThrottle()

    // R2-6/Q01: 归档年份的读写统一经 AppSettings（SettingKey.archivedYears），
    // AppState 不再直接持有 defaults key。

    init(database: AppDatabase, rescueMode: Bool = false) {
        self.db = database
        self.isRescueMode = rescueMode
        self.boards = database.boardDAO
        self.entries = database.entryDAO
        self.dayNotes = database.dayNoteDAO
        // R2-4: 替换 try! 为安全初始化，失败降级而非崩溃
        let mediaStore: LocalMediaStore
        do {
            mediaStore = try LocalMediaStore(database: database)
        } catch {
            WuyanLog.general.error("LocalMediaStore 初始化失败：\(error.localizedDescription)")
            // 降级：创建空目录后重试
            let support = LocalMediaStore.mediaRootURL
            try? FileManager.default.createDirectory(at: support.appendingPathComponent("media", isDirectory: true), withIntermediateDirectories: true)
            // 第二次尝试
            do {
                mediaStore = try LocalMediaStore(database: database)
            } catch {
                fatalError("LocalMediaStore 初始化失败且无法降级：\(error)")
            }
        }
        self.mediaStore = mediaStore
        self.syncCoordinator = SyncCoordinator(database: database, mediaStore: mediaStore, rescueMode: rescueMode)
        self.isDiaryPasswordEnabled = DiaryLockStore.isEnabled
        self.isDiaryLocked = DiaryLockStore.isEnabled
        self.diaryIdleTimeoutMinutes = AppSettings.diaryIdleTimeoutMinutes
        self.aiService = AIService(
            provider: ProviderFactory.makeAIProvider(),
            isEnabled: AppSettings.aiEnabled,
            ritualPolishingEnabled: AppSettings.aiRitual
        )
        self.aiService.moodForDay = { try database.dayNoteDAO.effectiveMood(dayKey: $0) }
        self.aiService.cloudBlockedBoardIds = Self.cloudBlockedBoardIds(boards)
        // Q01：归档年份读写统一走 AppSettings（可注入 defaults），
        // 测试构造的 AppState 与被测设置共享同一容器。
        let stored = AppSettings.archivedYears
        self.archivedYears = stored.sorted(by: >)

        // R2-3: 通过 AppMigrationRunner 触发媒体 Caches 迁移（v2）
        // 这里只执行 v2 迁移，v1（Keychain）已在 WuyanApp.init 中执行
        if !rescueMode {
            AppMigrationRunner.run { [mediaStore] in
                try mediaStore.performCachesMigration()
            }
        }

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
        // UI-02：归档结束（无论成败）解除该年份的编辑锁定
        syncCoordinator.onArchiveFinished = { [weak self] _ in
            self?.archivingYear = nil
        }
    }

    // MARK: - 日记密码锁

    func startDiaryLockMonitoring() {
        guard diaryActivityMonitor == nil else { return }
        diaryLastActivity = Date()
        diaryActivityMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            Task { @MainActor in self?.recordDiaryActivity() }
            return event
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        diaryNotificationTokens.append(workspaceCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lockDiary() }
        })
        diaryNotificationTokens.append(workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lockDiary() }
        })
        diaryNotificationTokens.append(workspaceCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lockDiary() }
        })
        diaryDistributedNotificationTokens.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lockDiary() }
        })
        diaryNotificationTokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.checkDiaryIdleLock() }
        })
    }

    func recordDiaryActivity() {
        guard !isDiaryLocked else { return }
        diaryLastActivity = Date()
    }

    func checkDiaryIdleLock() {
        guard isDiaryPasswordEnabled, !isDiaryLocked else { return }
        let timeout = AppSettings.diaryIdleTimeoutSeconds
        guard timeout > 0, Date().timeIntervalSince(diaryLastActivity) >= timeout else { return }
        lockDiary()
    }

    func lockDiary() {
        guard isDiaryPasswordEnabled, !isDiaryLocked else { return }
        // 让编辑器在仍挂载时同步 flush，随后才切换根视图，避免 SwiftUI
        // 因为分支卸载而错过最后一段富文本保存。
        NotificationCenter.default.post(name: .wuyanDiaryLockRequested, object: nil)
        isDiaryLocked = true
        isShowingRitual = false
        boardChooserDay = nil
        pendingDeleteEntryId = nil
        errorMessage = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
        QLPreviewPanel.shared()?.orderOut(nil)
    }

    func unlockDiary(password: String) -> Bool {
        guard isDiaryPasswordEnabled, DiaryLockStore.verify(password: password) else { return false }
        unlockDiaryAfterVerification()
        return true
    }

    func diaryUnlockRemainingSeconds(at date: Date = Date()) -> Int {
        diaryUnlockThrottle.remainingSeconds(at: date)
    }

    @discardableResult
    func recordDiaryUnlockFailure(at date: Date = Date()) -> Int {
        diaryUnlockThrottle.recordFailure(at: date)
    }

    @discardableResult
    func unlockDiaryAfterVerification() -> Bool {
        guard isDiaryPasswordEnabled else { return false }
        diaryUnlockThrottle.reset()
        isDiaryLocked = false
        diaryLastActivity = Date()
        return true
    }

    func setDiaryPasswordEnabled(_ enabled: Bool) {
        isDiaryPasswordEnabled = enabled
        AppSettings.setDiaryPasswordEnabled(enabled)
        if enabled {
            diaryLastActivity = Date()
        } else {
            isDiaryLocked = false
            AppSettings.resetDiaryIdleTimeoutMinutes()
            diaryIdleTimeoutMinutes = AppSettings.diaryIdleTimeoutMinutes
        }
    }

    func updateDiaryIdleTimeout(minutes: Int) {
        diaryIdleTimeoutMinutes = minutes
        AppSettings.setDiaryIdleTimeoutMinutes(minutes)
        checkDiaryIdleLock()
    }

    deinit {
        if let diaryActivityMonitor { NSEvent.removeMonitor(diaryActivityMonitor) }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        diaryNotificationTokens.forEach { workspaceCenter.removeObserver($0) }
        diaryNotificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        diaryDistributedNotificationTokens.forEach { DistributedNotificationCenter.default().removeObserver($0) }
    }

    /// 更新 archivedYears 并持久化。Q01：经由 AppSettings 写入（可注入 defaults）。
    func setArchivedYears(_ years: Set<Int>) {
        let sorted = years.sorted(by: >)
        archivedYears = sorted
        AppSettings.setArchivedYears(sorted)
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
        guard !isRescueMode else {
            errorMessage = "救援模式：删除已禁用。"
            return
        }
        do {
            let assets = (try? entries.entry(id: entryId)).flatMap { try? db.mediaAssetDAO.allAssets(for: $0.mediaIds) } ?? []
            try entries.permanentlyDelete(id: entryId)
            syncCoordinator.notifyEditCompleted()
            for asset in assets where ((try? db.mediaAssetDAO.referenceCount(sha256: asset.sha256)) ?? 1) == 0 {
                try? mediaStore.removeLocalFiles(for: asset)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 同步前向方法

    func syncNow() {
        // UI-07：救援模式禁止同步，避免把内存降级库的内容当作真实数据推送
        guard !isRescueMode else {
            errorMessage = "救援模式：数据库未正常加载，同步已禁用。"
            return
        }
        syncCoordinator.syncNow(archivedYears: Set(archivedYears))
    }

    func archiveYearToRemote(_ year: Int) {
        guard !isRescueMode else {
            errorMessage = "救援模式：归档已禁用。"
            return
        }
        guard year != Self.year(fromDayKey: DayKey.today) else {
            errorMessage = "当前年份不能归档。"
            return
        }
        // UI-02：归档期间该年份锁定；同时只允许一个归档任务
        if let running = archivingYear {
            errorMessage = "已有 \(running) 年归档任务进行中，请等待完成。"
            return
        }
        guard syncCoordinator.archiveYearToRemote(year, archivedYears: Set(archivedYears)) else { return }
        // The coordinator creates its Task before returning, so this lock is
        // installed in the same main-actor turn only after startup is accepted.
        archivingYear = year
    }

    func downloadYearFromRemote(_ year: Int) {
        guard !isRescueMode else {
            errorMessage = "救援模式：下载已禁用。"
            return
        }
        guard archivedYears.contains(year) else {
            errorMessage = "只有已归档年份可以下载回本地。"
            return
        }
        syncCoordinator.downloadYearFromRemote(year)
        // 下载成功后由调用方更新 archivedYears
    }

    func enrichEntryMetadataIfNeeded(_ entryId: UUID) {
        guard !DevelopmentPreview.isEnabled else { return }
        guard !isRescueMode else { return }
        guard AppSettings.metadataEnabled else { return }
        Task {
            guard let _ = try? entries.entry(id: entryId),
                  let location = await locationMetadata.requestLocation()
            else { return }
            let placeName = await locationMetadata.geocode(location)
            let newLocation = GeoPlace(lat: location.coordinate.latitude, lon: location.coordinate.longitude, placeName: placeName)
            let newWeather = try? await OpenMeteoService().current(lat: location.coordinate.latitude, lon: location.coordinate.longitude)
            // 网络等待期间用户可以继续编辑；回写只填充仍为空的字段，
            // 不会覆盖用户手工设置或正文编辑。
            let updated = try? entries.fillMissingMetadata(
                id: entryId, weather: newWeather, location: newLocation
            )
            if updated == true {
                syncCoordinator.notifyEditCompleted()
            }
        }
    }

    func refreshRemindersForToday(force: Bool = false) {
        guard !DevelopmentPreview.isEnabled else { return }
        guard AppSettings.reminderEnabled else { return }
        let times = Self.reminderTimesFromDefaults()
        Task {
            let today = Date().dayKey
            // UI-09①：空草稿不算「已写」——今天只有草稿时仍按未写处理
            let todays = (try? entries.timeline(filter: .day(today))) ?? []
            let hasWrittenToday = todays.contains { !$0.isDraft }
            let key = (today, hasWrittenToday)
            if !force, lastReminderRefresh?.dayKey == key.0, lastReminderRefresh?.hasWrittenToday == key.1 {
                return
            }
            lastReminderRefresh = key
            await ReminderScheduler().refreshForToday(hasWrittenToday: hasWrittenToday, times: times)
        }
    }

    func restoreEntry(entryId: UUID) {
        guard !isRescueMode else {
            errorMessage = "救援模式：还原已禁用。"
            return
        }
        do {
            try entries.restore(id: entryId)
            syncCoordinator.notifyEditCompleted()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 所有删除入口共用同一条路径，确保救援模式和归档锁定规则一致。
    func softDelete(entryId: UUID) {
        guard !isRescueMode else {
            errorMessage = "救援模式：删除已禁用。"
            return
        }
        guard let current = try? entries.entry(id: entryId) else { return }
        if let archiving = archivingYear,
           archiving == Self.year(fromDayKey: current.dayDate) {
            errorMessage = "正在归档 \(archiving) 年，该年份暂时锁定。"
            return
        }
        do {
            try entries.softDelete(id: entryId)
            syncCoordinator.notifyEditCompleted()
            if selectedEntryId == entryId { selectedEntryId = nil }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestDeleteCurrentEntry() {
        guard selectedEntryId != nil else { return }
        pendingDeleteEntryId = selectedEntryId
    }

    func deleteBoard(boardId: UUID) {
        guard !isRescueMode else {
            errorMessage = "救援模式：板块修改已禁用。"
            return
        }
        do {
            try boards.delete(id: boardId)
            // Keep the service-layer privacy filter in sync with board removal.
            reloadAISettings()
            syncCoordinator.notifyEditCompleted()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reloadAISettings() {
        aiService.provider = ProviderFactory.makeAIProvider()
        aiService.isEnabled = AppSettings.aiEnabled
        aiService.ritualPolishingEnabled = AppSettings.aiRitual
        aiService.cloudBlockedBoardIds = Self.cloudBlockedBoardIds(boards)
    }

    // MARK: - UI-07：救援模式

    /// 真实数据库文件位置（救援副本导出来源）。
    static var productionDatabaseURL: URL {
        let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return (base?.appendingPathComponent("Wuyan", isDirectory: true) ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("Wuyan.sqlite")
    }

    /// 导出救援副本：把真实数据库文件（含 WAL/SHM）复制到用户指定目录。
    /// 救援模式下唯一的数据出口；复制失败会抛错并显示。
    func exportRescueCopy(to directory: URL) throws -> URL {
        let fm = FileManager.default
        let source = Self.productionDatabaseURL
        guard fm.fileExists(atPath: source.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let destination = directory.appendingPathComponent("Wuyan-rescue-\(stamp).sqlite")
        try fm.copyItem(at: source, to: destination)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: source.path + suffix)
            if fm.fileExists(atPath: sidecar.path) {
                // A rescue copy without a present WAL/SHM sidecar may be unreadable;
                // propagate the copy error instead of reporting a partial success.
                try fm.copyItem(at: sidecar, to: URL(fileURLWithPath: destination.path + suffix))
            }
        }
        return destination
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
        // Q01：读写统一走 AppSettings（可注入 defaults），测试不再触碰 standard 域。
        AppSettings.setReminderTimes(dates.map { formatter.string(from: $0) })
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
