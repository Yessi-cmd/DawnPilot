import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            ConfigurationSection(guidance: model.configurationGuidance)

            if model.operationIssue != nil || model.operationSuccessMessage != nil {
                OperationFeedbackSection(
                    issue: model.operationIssue,
                    successMessage: model.operationSuccessMessage,
                    showsSettingsRecovery: true,
                    dismissIssue: model.dismissOperationIssue,
                    dismissSuccess: model.dismissOperationSuccess
                )
            }

            NextAlarmSection(
                record: model.nextRecord,
                snapshotState: model.snapshotState,
                settings: model.settings
            )

            RefreshStatusSection(
                status: model.status,
                statusSummary: model.statusSummary,
                authorizationText: model.authorizationText,
                verificationState: model.alarmVerificationState,
                settings: model.settings
            )

            AlarmActionsSection(model: model)
            AutomationGuideSection()
        }
        .navigationTitle("晨航")
        .task {
            model.loadSnapshot()
        }
    }
}
