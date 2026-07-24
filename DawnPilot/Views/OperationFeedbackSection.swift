import SwiftUI

struct OperationFeedbackSection: View {
    @Environment(\.openURL) private var openURL

    let issue: AppModel.OperationIssue?
    let successMessage: String?
    let showsSettingsRecovery: Bool
    let dismissIssue: () -> Void
    let dismissSuccess: () -> Void

    var body: some View {
        Section("最近操作") {
            if let issue {
                Label(issue.title, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(issue.message)

                if issue.recoveryAction == .editSettings,
                   showsSettingsRecovery {
                    NavigationLink(value: ContentView.Route.settings) {
                        Label("检查设置", systemImage: "slider.horizontal.3")
                    }
                } else if issue.recoveryAction == .openSystemSettings {
                    Button(
                        "前往系统设置",
                        systemImage: "gear",
                        action: openSystemSettings
                    )
                }

                Button("关闭", role: .cancel, action: dismissIssue)
            } else if let successMessage {
                Label(successMessage, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("关闭", role: .cancel, action: dismissSuccess)
            }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}
