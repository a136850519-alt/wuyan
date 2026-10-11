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
    @Published var scope = "本次功能所需的有限日记片段。"
    private var pendingAction: (() -> Void)?

    /// 判断是否需要拦截并弹出确认；若不需要则直接执行。
    /// S04/UI-05：会话信任绑定到「provider + 实际目的地」——目的地变化后旧授权失效。
    func gate(appState: AppState, scope: String = "本次功能所需的有限日记片段。", action: @escaping () -> Void) {
        self.scope = scope
        if appState.aiService.requiresCloudConsent,
           appState.trustCloudDestination != appState.aiService.consentDestinationIdentifier {
            pendingAction = action
            showsConfirm = true
        } else {
            action()
        }
    }

    func cancel() {
        showsConfirm = false
        pendingAction = nil
    }

    func trustSession(appState: AppState) {
        appState.trustCloudDestination = appState.aiService.consentDestinationIdentifier
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
                // S04/UI-05：明示实际目的地与发送范围
                Text("发送目的地：\(appState.aiService.consentDestinationIdentifier)。\n发送范围：\(gate.scope)已标记「禁止云端 AI」的板块不会发送。")
            }
    }
}

extension View {
    /// 附加云端 AI 授权确认弹窗。
    func cloudAIConsentAlert(gate: CloudAIConsentGateModel) -> some View {
        modifier(CloudAIConsentAlert(gate: gate))
    }
}
