import SwiftUI

extension Notification.Name {
    /// 应用即将退出，各组件应立即 flush 未保存数据
    static let wuyanWillTerminate = Notification.Name("wuyanWillTerminate")
}

/// B08：macOS 26/27 的 SwiftUI 缺陷——WindowGroup 应用收到 reopen（点击 Dock 图标）时：
/// 1) 已最小化的窗口不会被还原（app 激活但窗口缩在 Dock 里没反应）；
/// 2) 窗口被红色按钮关闭后也不会重建（app 挂在 Dock 上无窗口可切）。
/// 在此手动接管：先还原最小化窗口；一个可见窗口都没有时用 openWindow 重建主窗口。
private final class WuyanAppDelegate: NSObject, NSApplicationDelegate {
    /// 由主窗口内容的 ReopenWindowActionCaptor 在 onAppear 时捕获，
    /// 窗口全部关闭后 delegate 仍可用它重建窗口（OpenWindowAction 可安全存储）。
    static var openWindowAction: OpenWindowAction?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let miniaturized = sender.windows.filter { $0.isMiniaturized }
        if !miniaturized.isEmpty {
            miniaturized.forEach { $0.deminiaturize(nil) }
            return false
        }
        guard !flag else { return false }
        if let openWindow = Self.openWindowAction {
            openWindow(id: "main")
            return false
        }
        return true
    }
}

/// 捕获 openWindow 环境动作供 AppDelegate 使用（SwiftUI 的 environment 无法在 delegate 里直接读取）。
private struct ReopenWindowActionCaptor: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { WuyanAppDelegate.openWindowAction = openWindow }
    }
}

@main
struct WuyanApp: App {
    @NSApplicationDelegateAdaptor(WuyanAppDelegate.self) private var appDelegate
    @StateObject private var appState: AppState

    init() {
        WuyanFont.registerBundledFonts()

        // R2-3: 使用 AppMigrationRunner 替代散点迁移调用，有序/幂等/失败不崩溃
        // v1 Keychain 迁移在此执行（不需要 database）
        AppMigrationRunner.run()

        // R2-4: 启动路径不再 try!/fatalError，失败时降级为可读错误状态
        do {
            let database = try AppDatabase.makeDefault()
            let state = AppState(database: database)
            _appState = StateObject(wrappedValue: state)
        } catch {
            // 数据库无法打开：进入只读救援模式（UI-07，已确认）——
            // 不再把可写内存库伪装成正常状态（虚假保存 + 照常同步）。
            WuyanLog.general.error("数据库初始化失败：\(error.localizedDescription)")
            do {
                // 内存库仅为维持界面结构可用；编辑与同步在 AppState 中被禁用
                let database = try AppDatabase.makeInMemory()
                let state = AppState(database: database, rescueMode: true)
                state.errorMessage = "数据库加载失败，已进入只读救援模式：编辑与同步已禁用，当前输入不会被保存。请先导出救援副本。"
                _appState = StateObject(wrappedValue: state)
            } catch {
                // 连内存数据库都创建不了，这才 fatalError
                fatalError("Unable to initialize Wuyan: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environmentObject(appState)
                .frame(minWidth: 1080, minHeight: 680)
                .background(ReopenWindowActionCaptor())
                .onAppear {
                    // Refill the non-repeating reminder window on every launch.
                    appState.refreshRemindersForToday(force: true)
                    // 启动后 10 秒自动同步（UI-07：救援模式下禁用同步）
                    if !appState.isRescueMode {
                        appState.syncCoordinator.scheduleStartupSync()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    NotificationCenter.default.post(name: .wuyanWillTerminate, object: nil)
                }
                // NSWorkspace posts wake events through its own notification center;
                // subscribing to NotificationCenter.default can miss the event.
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                    appState.refreshRemindersForToday(force: true)
                    // 系统从睡眠恢复后自动同步
                    appState.syncCoordinator.handleWakeFromSleep()
                }
        }
        .commands {
            AppCommands(appState: appState)
        }
    }
}
