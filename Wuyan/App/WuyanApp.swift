import SwiftUI

extension Notification.Name {
    /// 应用即将退出，各组件应立即 flush 未保存数据
    static let wuyanWillTerminate = Notification.Name("wuyanWillTerminate")
}

@main
struct WuyanApp: App {
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
            // 数据库无法打开时仍需提供可用 AppState（降级模式），
            // 而非 fatalError 让用户每次启动都崩。
            WuyanLog.general.error("数据库初始化失败：\(error.localizedDescription)")
            do {
                // 尝试创建临时数据库（内存模式）作为降级
                let database = try AppDatabase.makeInMemory()
                let state = AppState(database: database)
                state.errorMessage = "数据库加载失败，已降级为空数据库。请检查磁盘空间或重启应用。"
                _appState = StateObject(wrappedValue: state)
            } catch {
                // 连内存数据库都创建不了，这才 fatalError
                fatalError("Unable to initialize Wuyan: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .frame(minWidth: 1080, minHeight: 680)
                .background(WindowMaximizer())
                .onAppear {
                    // 启动后 10 秒自动同步
                    appState.syncCoordinator.scheduleStartupSync()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    NotificationCenter.default.post(name: .wuyanWillTerminate, object: nil)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                    // 系统从睡眠恢复后自动同步
                    appState.syncCoordinator.handleWakeFromSleep()
                }
        }
        .commands {
            AppCommands(appState: appState)
        }
    }
}

private struct WindowMaximizer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if !window.isZoomed {
                window.zoom(nil)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
