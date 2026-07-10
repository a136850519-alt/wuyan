import SwiftUI

@main
struct WuyanApp: App {
    @StateObject private var appState: AppState

    init() {
        do {
            WuyanFont.registerBundledFonts()
            // 将旧版 UserDefaults 中的凭据迁移到 Keychain
            SecureSettings.migrateAllFromDefaults()
            let database = try AppDatabase.makeDefault()
            let state = AppState(database: database)
            _appState = StateObject(wrappedValue: state)
        } catch {
            fatalError("Unable to initialize Wuyan database: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .frame(minWidth: 1080, minHeight: 680)
                .background(WindowMaximizer())
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
