import SwiftUI

// MARK: - R2-2: 云端 AI 授权门控（共享模型 + 共享 alert 视图）

/// 云端 AI 动作执行前弹出确认对话框的共享状态管理。
/// 替代 RitualView / AIAssistantView 各自复制的 showsCloudConfirm + pendingAction 逻辑。
/// 判定基于 AIService.requiresCloudConsent（provider.isLocal == false），而非字符串白名单。
///
/// 用法：
///   @StateObject private var consentGate = CloudAIConsentGateModel()
///   consentGate.gate(appState: appState) { /* cloud action */ }
///   // 在视图层级加 .cloudAIConsentAlert(gate: consentGate, appState: appState)
@MainActor
final class CloudAIConsentGateModel: ObservableObject {
    @Published var showsConfirm = false
    private var pendingAction: (() -> Void)?

    /// 判断是否需要拦截并弹出确认；若不需要则直接执行。
    func gate(appState: AppState, action: @escaping () -> Void) {
        if appState.aiService.requiresCloudConsent, !appState.trustCloudForSession {
            pendingAction = action
            showsConfirm = true
        } else {
            action()
        }
    }

    func cancel() {
        pendingAction = nil
    }

    func trustSession(appState: AppState) {
        appState.trustCloudForSession = true
        pendingAction?()
        pendingAction = nil
    }

    func proceedOnce() {
        pendingAction?()
        pendingAction = nil
    }
}

/// 云端 AI 授权确认弹窗，附加到任意视图上。
struct CloudAIConsentAlert: ViewModifier {
    @ObservedObject var gate: CloudAIConsentGateModel
    @EnvironmentObject private var appState: AppState

    func body(content: Content) -> some View {
        content
            .alert("将发送内容到云端 AI", isPresented: $gate.showsConfirm) {
                Button("取消", role: .cancel) { gate.cancel() }
                Button("信任本会话") { gate.trustSession(appState: appState) }
                Button("仅本次") { gate.proceedOnce() }
            } message: {
                Text("将发送日记内容到云端 AI 生成结果。")
            }
    }
}

extension View {
    /// 附加云端 AI 授权确认弹窗。
    func cloudAIConsentAlert(gate: CloudAIConsentGateModel) -> some View {
        modifier(CloudAIConsentAlert(gate: gate))
    }
}
