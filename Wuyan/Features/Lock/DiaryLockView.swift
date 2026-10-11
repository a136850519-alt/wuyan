import LocalAuthentication
import SwiftUI

struct DiaryLockView: View {
    @EnvironmentObject private var appState: AppState
    @FocusState private var passwordFocused: Bool
    @State private var password = ""
    @State private var message = ""
    @State private var isVerifying = false
    @State private var showsResetSheet = false
    @State private var retryClock = Date()

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
            HStack(spacing: 0) {
                bookFrontPage
                bookBackPage
            }
            .frame(maxWidth: 930, minHeight: 520)
            .background(Palette.paper)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 32, y: 16)
            .padding(42)
        }
        .ignoresSafeArea()
        .sheet(isPresented: $showsResetSheet) {
            DiaryPasswordSheet(mode: .reset)
                .environmentObject(appState)
        }
        .onAppear {
            passwordFocused = true
            // RootView can present this page directly when the idle deadline has
            // elapsed, before AppState's periodic timer runs.
            appState.lockDiary()
        }
        .onExitCommand {
            password = ""
            passwordFocused = false
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { retryClock = $0 }
    }

    private var bookFrontPage: some View {
        ZStack(alignment: .topLeading) {
            Palette.paper.opacity(0.92)
            Rectangle()
                .fill(Palette.cinnabar)
                .frame(width: 22, height: 68)
                .clipShape(RibbonShape())
                .padding(.leading, 34)
            VStack(spacing: 26) {
                HStack(spacing: 20) {
                    VStack(spacing: 14) {
                        Text("此间心事").verticalWriting()
                        Text("暂寄纸上").verticalWriting()
                    }
                    Text("晤言")
                        .font(WuyanFont.body(16))
                        .foregroundStyle(Palette.cinnabar)
                        .padding(8)
                        .overlay(Rectangle().stroke(Palette.cinnabar, lineWidth: 1))
                        .rotationEffect(.degrees(-3))
                }
                Text("把寻常的日子，写成自己的书。")
                    .font(WuyanFont.body(13))
                    .foregroundStyle(Palette.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { Text("· 01 ·").font(.caption2).foregroundStyle(Palette.muted).padding(.bottom, 22).accessibilityHidden(true) }
    }

    private var bookBackPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("日记已锁定", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("展卷，续写。")
                .font(WuyanFont.title(30))
                .padding(.top, 22)
            Text("输入密码，回到刚才那一页。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 10)

            SecureField("日记密码", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($passwordFocused)
                .padding(.top, 30)
                .disabled(isVerifying)
                .onSubmit { unlock() }
            Button {
                unlock()
            } label: {
                HStack {
                    Text(isVerifying ? "正在验证…" : "解锁日记")
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.cinnabar)
            .padding(.top, 13)
            .disabled(password.isEmpty || isVerifying)

            Button("忘记密码？") {
                DiaryLockStore.authenticateForReset { success in
                    if success { showsResetSheet = true } else { message = "系统身份验证未通过，日记仍保持锁定。" }
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.top, 14)
            .disabled(isVerifying)

            if retrySeconds > 0 {
                Text("请在 \(retrySeconds) 秒后重试。")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Palette.cinnabar)
                    .padding(.top, 18)
            }
            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Palette.cinnabar)
                    .padding(.top, retrySeconds > 0 ? 6 : 18)
            }
            Spacer()
            Text("你的记录，仅在解锁后呈现。")
                .font(WuyanFont.body(12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.paper)
        .overlay(alignment: .bottom) { Text("· 02 ·").font(.caption2).foregroundStyle(Palette.muted).padding(.bottom, 22).accessibilityHidden(true) }
    }

    private func unlock() {
        guard !password.isEmpty, !isVerifying else { return }
        if appState.diaryCredentialUnavailable {
            message = "钥匙串暂时不可读，请使用“忘记密码？”重设。"
            password = ""
            return
        }
        guard retrySeconds == 0 else {
            message = "尝试次数过多，请稍后再试。"
            return
        }
        isVerifying = true
        let attempt = password
        Task {
            let verified = await Task.detached(priority: .userInitiated) {
                DiaryLockStore.verify(password: attempt)
            }.value
            await MainActor.run {
                if verified && appState.unlockDiaryAfterVerification() {
                    password = ""
                    message = ""
                } else {
                    let delay = appState.recordDiaryUnlockFailure()
                    if delay > 0 {
                        retryClock = Date()
                        message = "尝试次数过多。"
                    } else {
                        message = "密码不正确，请再试一次。"
                    }
                    password = ""
                    passwordFocused = true
                }
                isVerifying = false
            }
        }
    }

    private var retrySeconds: Int {
        appState.diaryUnlockRemainingSeconds(at: retryClock)
    }
}

private struct RibbonShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: rect.maxX, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - 10))
        path.addLine(to: CGPoint(x: 0, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private extension Text {
    func verticalWriting() -> some View {
        self.font(WuyanFont.body(39))
            .lineSpacing(10)
            .frame(width: 46)
    }
}

enum DiaryPasswordSheetMode: Sendable {
    case enable, change, disable, reset
}

extension DiaryPasswordSheetMode: Identifiable {
    var id: String {
        switch self {
        case .enable: return "enable"
        case .change: return "change"
        case .disable: return "disable"
        case .reset: return "reset"
        }
    }
}

struct DiaryPasswordSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let mode: DiaryPasswordSheetMode
    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var errorMessage = ""
    @State private var isSaving = false

    init(mode: DiaryPasswordSheetMode) { self.mode = mode }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.weight(.semibold))
            if mode == .change || mode == .disable {
                SecureField("当前密码", text: $oldPassword)
            }
            if mode != .disable {
                SecureField("新密码", text: $newPassword)
                SecureField("再次输入新密码", text: $confirmPassword)
            }
            Text("至少 8 个字符，可使用中文、字母、数字和符号。密码只保存在这台 Mac 的钥匙串中。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !errorMessage.isEmpty {
                Text(errorMessage).font(.caption).foregroundStyle(Palette.cinnabar)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action: save) { Text(isSaving ? "正在处理…" : actionTitle) }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.cinnabar)
                    .disabled(isSaving)
            }
        }
        .padding(24)
        .frame(width: 390)
    }

    private var title: String {
        switch mode { case .enable: return "设置日记密码"; case .change: return "修改日记密码"; case .disable: return "关闭日记密码"; case .reset: return "重设日记密码" }
    }

    private var actionTitle: String { mode == .disable ? "验证并关闭" : "保存密码" }

    private func save() {
        guard !isSaving else { return }
        if mode != .disable {
            guard newPassword.count >= 8 else { errorMessage = "日记密码至少需要 8 个字符。"; return }
            guard newPassword == confirmPassword else { errorMessage = "两次输入的密码不一致。"; return }
        }

        let operationMode = mode
        let old = oldPassword
        let new = newPassword
        isSaving = true
        errorMessage = ""
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                if operationMode == .change || operationMode == .disable,
                   !DiaryLockStore.verify(password: old) {
                    return SaveOutcome.failure("当前密码不正确。")
                }
                if operationMode == .disable {
                    do {
                        try DiaryLockStore.remove()
                        return SaveOutcome.disabled
                    } catch {
                        return SaveOutcome.failure(error.localizedDescription)
                    }
                }
                do {
                    try DiaryLockStore.save(password: new)
                    return SaveOutcome.saved
                } catch {
                    return SaveOutcome.failure(error.localizedDescription)
                }
            }.value

            await MainActor.run {
                isSaving = false
                switch outcome {
                case let .failure(message):
                    errorMessage = message
                case .disabled:
                    appState.setDiaryPasswordEnabled(false)
                    dismiss()
                case .saved:
                    appState.setDiaryPasswordEnabled(true)
                    if operationMode == .reset { _ = appState.unlockDiaryAfterVerification() }
                    dismiss()
                }
            }
        }
    }

    private enum SaveOutcome: Sendable {
        case failure(String)
        case disabled
        case saved
    }
}
