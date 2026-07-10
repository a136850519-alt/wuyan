import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @Binding var isPresented: Bool
    @State private var step = 0
    @AppStorage(SettingKey.webDAVBaseURL) private var webDAVBaseURL = "https://nas.local:5006"
    @AppStorage(SettingKey.webDAVUsername) private var webDAVUsername = ""
    @State private var webDAVPassword = ""
    @State private var testMessage: String?
    @State private var saveMessage: String?
    @State private var isTestingWebDAV = false
    @State private var boards: [Board] = []
    @State private var newBoardName = ""

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $step) {
                welcome.tag(0)
                nasSetup.tag(1)
                boardSetup.tag(2)
            }
            .tabViewStyle(.automatic)
            .frame(width: 620, height: 430)

            HStack {
                Button("稍后") {
                    finish()
                }
                .buttonStyle(WuyanSecondaryButtonStyle())
                Spacer()
                if step > 0 {
                    Button("上一步") {
                        withAnimation(WuyanMotion.ease) { step -= 1 }
                    }
                    .buttonStyle(WuyanSecondaryButtonStyle())
                }
                Button(step == 2 ? "完成" : "下一步") {
                    if step == 2 {
                        finish()
                    } else {
                        withAnimation(WuyanMotion.ease) { step += 1 }
                    }
                }
                .buttonStyle(WuyanPrimaryButtonStyle())
            }
            .padding(24)
        }
        .background(Palette.paper)
        .task {
            boards = (try? appState.boards.all()) ?? []
            webDAVPassword = SecureSettings.load(SecureSettingKey.webDAVPassword, legacyDefaultsKey: SecureSettingKey.webDAVPassword)
        }
    }

    private var welcome: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("晤言")
                .font(WuyanFont.title(50))
            Text("与自己，对坐而谈")
                .font(WuyanFont.body(22))
                .foregroundStyle(.secondary)
            Text("本地优先写作，数据可同步到你自己的 NAS。")
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(44)
    }

    private var nasSetup: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("连接 NAS")
                .font(WuyanFont.title(30))
            Text("WebDAV 默认使用 HTTPS 5006，稍后也可在设置中修改。")
                .foregroundStyle(.secondary)
            TextField("WebDAV 地址", text: $webDAVBaseURL)
            TextField("账号", text: $webDAVUsername)
            SecureField("密码", text: $webDAVPassword)
            Button("保存配置") {
                saveWebDAVSettings()
            }
            .buttonStyle(WuyanSecondaryButtonStyle())
            Button(isTestingWebDAV ? "正在测试" : "测试连接") {
                testWebDAV()
            }
            .buttonStyle(WuyanPrimaryButtonStyle())
            .disabled(isTestingWebDAV)
            if let testMessage {
                Text(testMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let saveMessage {
                Text(saveMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(44)
    }

    private var boardSetup: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("板块")
                .font(WuyanFont.title(30))
            Text("默认板块已准备好，也可以先新建一个自己的板块。")
                .foregroundStyle(.secondary)
            ForEach(boards) { board in
                HStack {
                    Circle().fill(Color(hex: board.colorHex)).frame(width: 9, height: 9)
                    Label(board.name, systemImage: board.iconName)
                    Spacer()
                    if let age = board.ageText() {
                        WuyanPill(text: age, foreground: Palette.babyPinkText, background: Palette.babyPink)
                    }
                }
            }
            HStack {
                TextField("新板块名称", text: $newBoardName)
                Button("+ 新建") { addBoard() }
                    .buttonStyle(WuyanSecondaryButtonStyle())
            }
            Spacer()
        }
        .padding(44)
    }

    private func testWebDAV() {
        guard !isTestingWebDAV else { return }
        saveWebDAVSettings(showMessage: false)
        testMessage = "正在测试连接…"
        isTestingWebDAV = true

        guard let url = URL(string: webDAVBaseURL) else {
            testMessage = "地址无效"
            isTestingWebDAV = false
            return
        }
        let provider = WebDAVProvider(baseURL: url, username: webDAVUsername, password: webDAVPassword)
        Task {
            do {
                try await provider.testConnection()
                await MainActor.run {
                    testMessage = "连接成功，已完成读写探测。"
                    isTestingWebDAV = false
                }
            } catch {
                await MainActor.run {
                    testMessage = error.localizedDescription
                    isTestingWebDAV = false
                }
            }
        }
    }

    private func saveWebDAVSettings(showMessage: Bool = true) {
        webDAVBaseURL = webDAVBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        webDAVUsername = webDAVUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        SecureSettings.save(webDAVPassword, for: SecureSettingKey.webDAVPassword, legacyDefaultsKey: SecureSettingKey.webDAVPassword)
        if showMessage {
            saveMessage = "WebDAV 配置已保存。"
            testMessage = nil
        }
    }

    private func addBoard() {
        let name = newBoardName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let board = Board(name: name, colorHex: "#D85A30", iconName: "book", sortOrder: boards.count)
            try appState.boards.save(board)
            boards = try appState.boards.all()
            newBoardName = ""
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "onboarding.completed")
        isPresented = false
    }
}
