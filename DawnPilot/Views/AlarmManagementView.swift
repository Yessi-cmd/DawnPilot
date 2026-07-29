import SwiftUI

struct AlarmManagementView: View {
    @ObservedObject var model: AppModel

    @State private var deletionCandidate: ManagedAlarmRecord?
    @State private var showsDeletionConfirmation = false

    private var futureRecords: [ManagedAlarmRecord] {
        model.records
            .filter { $0.fireDate > .now }
            .sorted { $0.fireDate < $1.fireDate }
    }

    private var alarmDateFormat: Date.FormatStyle {
        var format = Date.FormatStyle.dateTime
            .month()
            .day()
            .weekday(.wide)
            .hour()
            .minute()
        format.locale = model.settings.calendar.locale ?? Locale(identifier: "zh_CN")
        format.timeZone = model.settings.calendar.timeZone
        return format
    }

    var body: some View {
        Group {
            if futureRecords.isEmpty {
                ContentUnavailableView(
                    "没有未来闹钟",
                    systemImage: "alarm",
                    description: Text("可以返回首页开启或修复未来 14 天的保底闹钟。")
                )
            } else {
                List {
                    Section {
                        ForEach(futureRecords) { record in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(record.fireDate.formatted(alarmDateFormat))
                                        .font(.headline)
                                    Label(
                                        "\(record.kind.displayName)闹钟",
                                        systemImage: symbolName(for: record.kind)
                                    )
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 0)

                                Button(
                                    "删除闹钟",
                                    systemImage: "trash",
                                    action: {
                                        requestDeletion(of: record)
                                    }
                                )
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.red)
                                .frame(width: 44, height: 44)
                                .buttonStyle(.plain)
                                .accessibilityLabel(
                                    "删除 \(record.fireDate.formatted(alarmDateFormat)) 的闹钟"
                                )
                            }
                            .swipeActions {
                                Button(
                                    "删除",
                                    systemImage: "trash",
                                    role: .destructive,
                                    action: {
                                        requestDeletion(of: record)
                                    }
                                )
                            }
                        }
                    } footer: {
                        Text(
                            "删除后，该日期不会被快捷指令或后台刷新重新创建。"
                                + "如需恢复，请在首页点“修复保底”。"
                        )
                    }

                    if model.isWorking {
                        Section {
                            ProgressView(model.operationPhase.message)
                        }
                    }

                    if model.operationIssue != nil
                        || model.operationSuccessMessage != nil {
                        OperationFeedbackSection(
                            issue: model.operationIssue,
                            successMessage: model.operationSuccessMessage,
                            showsSettingsRecovery: true,
                            dismissIssue: model.dismissOperationIssue,
                            dismissSuccess: model.dismissOperationSuccess
                        )
                    }
                }
            }
        }
        .navigationTitle("管理闹钟")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(model.isWorking)
        .confirmationDialog(
            "删除这条闹钟？",
            isPresented: $showsDeletionConfirmation,
            titleVisibility: .visible,
            presenting: deletionCandidate
        ) { record in
            Button(
                "确认删除",
                role: .destructive,
                action: {
                    confirmDeletion(of: record)
                }
            )
            Button("取消", role: .cancel) {
                deletionCandidate = nil
            }
        } message: { record in
            Text(
                "\(record.fireDate.formatted(alarmDateFormat)) 的闹钟将被删除，"
                    + "并在该日期结束前停止自动重建。"
            )
        }
    }

    private func requestDeletion(of record: ManagedAlarmRecord) {
        deletionCandidate = record
        showsDeletionConfirmation = true
    }

    private func confirmDeletion(of record: ManagedAlarmRecord) {
        deletionCandidate = nil
        model.deleteAlarm(record)
    }

    private func symbolName(for kind: ManagedAlarmKind) -> String {
        switch kind {
        case .rainy:
            "cloud.rain.fill"
        case .clear:
            "sun.max.fill"
        case .fallback:
            "shield.fill"
        }
    }
}
