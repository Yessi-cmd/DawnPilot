import SwiftUI

private struct AlarmDeletionCandidate: Identifiable {
    let id = UUID()
    let records: [ManagedAlarmRecord]

    var title: String {
        records.count == 1
            ? "删除这条闹钟？"
            : "删除 \(records.count) 条闹钟？"
    }
}

struct AlarmManagementView: View {
    @ObservedObject var model: AppModel

    @State private var isSelectingForDeletion = false
    @State private var selectedAlarmIDs: Set<UUID> = []
    @State private var deletionCandidate: AlarmDeletionCandidate?
    @State private var showsDeletionConfirmation = false

    private var futureRecords: [ManagedAlarmRecord] {
        model.records
            .filter { $0.fireDate > .now }
            .sorted { $0.fireDate < $1.fireDate }
    }

    private var selectedRecords: [ManagedAlarmRecord] {
        futureRecords.filter { selectedAlarmIDs.contains($0.alarmID) }
    }

    private var deletedDateKeys: [String] {
        let todayKey = makeDateKey(
            model.settings.calendar.startOfDay(for: .now)
        )
        return model.suppressedAlarmDateKeys
            .filter { $0 >= todayKey }
            .sorted()
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

    private var dayDateFormat: Date.FormatStyle {
        var format = Date.FormatStyle.dateTime
            .month()
            .day()
            .weekday(.wide)
        format.locale = model.settings.calendar.locale ?? Locale(identifier: "zh_CN")
        format.timeZone = model.settings.calendar.timeZone
        return format
    }

    var body: some View {
        Group {
            if futureRecords.isEmpty && deletedDateKeys.isEmpty {
                ContentUnavailableView(
                    "没有未来闹钟",
                    systemImage: "alarm",
                    description: Text("可以返回首页开启或修复未来 14 天的保底闹钟。")
                )
            } else {
                List {
                    futureAlarmSection

                    if !deletedDateKeys.isEmpty {
                        deletedDateSection
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
        .toolbar {
            if !futureRecords.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSelectingForDeletion ? "完成" : "选择") {
                        toggleSelectionMode()
                    }
                    .disabled(model.isWorking)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelectingForDeletion, !futureRecords.isEmpty {
                deletionToolbar
            }
        }
        .disabled(model.isWorking)
        .onDisappear {
            exitSelectionMode()
        }
        .confirmationDialog(
            deletionCandidate?.title ?? "删除闹钟？",
            isPresented: $showsDeletionConfirmation,
            titleVisibility: .visible,
            presenting: deletionCandidate
        ) { candidate in
            Button(
                candidate.records.count == 1
                    ? "确认删除"
                    : "删除 \(candidate.records.count) 条",
                role: .destructive,
                action: {
                    confirmDeletion(of: candidate)
                }
            )
            Button("取消", role: .cancel) {
                deletionCandidate = nil
            }
        } message: { candidate in
            if candidate.records.count == 1,
               let record = candidate.records.first {
                Text(
                    "\(record.fireDate.formatted(alarmDateFormat)) 的闹钟将被删除，"
                        + "并在该日期结束前停止自动重建。"
                )
            } else {
                Text(
                    "将删除 \(candidate.records.count) 条闹钟；"
                        + "这些日期在当天结束前都不会被自动重新创建。"
                )
            }
        }
    }

    @ViewBuilder
    private var futureAlarmSection: some View {
        Section {
            if futureRecords.isEmpty {
                Text("当前没有未来闹钟。可返回首页开启或修复未来 14 天的保底闹钟。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(futureRecords) { record in
                    alarmRow(record)
                }
            }
        } header: {
            Text("未来闹钟")
        } footer: {
            if !futureRecords.isEmpty {
                Text(
                    "删除后，该日期不会被快捷指令或后台刷新重新创建。"
                        + "可在下方“已删除日期”中单独恢复，或在首页点“修复保底”全部恢复。"
                )
            }
        }
    }

    private var deletedDateSection: some View {
        Section {
            ForEach(deletedDateKeys, id: \.self) { dateKey in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(dayText(for: dateKey))
                            .font(.headline)
                        Text("该日期不会自动重建闹钟")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    Button(
                        "恢复",
                        systemImage: "arrow.uturn.backward",
                        action: {
                            model.restoreAlarmDate(dateKey)
                        }
                    )
                    .buttonStyle(.borderless)
                    .accessibilityLabel("恢复 \(dayText(for: dateKey)) 的闹钟")
                }
            }
        } header: {
            Text("已删除日期")
        } footer: {
            Text(
                "删除状态会保留到当天结束。点击“恢复”只会恢复所选日期；"
                    + "首页的“修复保底”会一次恢复全部日期。"
            )
        }
    }

    private var deletionToolbar: some View {
        Button {
            requestDeletionOfSelectedRecords()
        } label: {
            Label(
                selectedRecords.isEmpty
                    ? "选择要删除的闹钟"
                    : "删除 \(selectedRecords.count) 条闹钟",
                systemImage: "trash"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(selectedRecords.isEmpty || model.isWorking)
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.bar)
    }

    private func alarmRow(_ record: ManagedAlarmRecord) -> some View {
        let isSelected = selectedAlarmIDs.contains(record.alarmID)
        return HStack(spacing: 12) {
            if isSelectingForDeletion {
                Image(
                    systemName: isSelected
                        ? "checkmark.circle.fill"
                        : "circle"
                )
                .font(.title3)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 28)
                .accessibilityLabel(isSelected ? "已选择" : "未选择")
            }

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

            if !isSelectingForDeletion {
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
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelectingForDeletion {
                toggleSelection(of: record)
            }
        }
        .swipeActions {
            if !isSelectingForDeletion {
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
    }

    private func toggleSelectionMode() {
        if isSelectingForDeletion {
            exitSelectionMode()
        } else {
            isSelectingForDeletion = true
            selectedAlarmIDs.removeAll()
        }
    }

    private func exitSelectionMode() {
        isSelectingForDeletion = false
        selectedAlarmIDs.removeAll()
    }

    private func toggleSelection(of record: ManagedAlarmRecord) {
        if selectedAlarmIDs.contains(record.alarmID) {
            selectedAlarmIDs.remove(record.alarmID)
        } else {
            selectedAlarmIDs.insert(record.alarmID)
        }
    }

    private func requestDeletion(of record: ManagedAlarmRecord) {
        deletionCandidate = AlarmDeletionCandidate(records: [record])
        showsDeletionConfirmation = true
    }

    private func requestDeletionOfSelectedRecords() {
        guard !selectedRecords.isEmpty else { return }
        deletionCandidate = AlarmDeletionCandidate(records: selectedRecords)
        showsDeletionConfirmation = true
    }

    private func confirmDeletion(of candidate: AlarmDeletionCandidate) {
        deletionCandidate = nil
        showsDeletionConfirmation = false
        exitSelectionMode()
        model.deleteAlarms(candidate.records)
    }

    private func dayText(for dateKey: String) -> String {
        guard let day = makeDay(from: dateKey) else { return dateKey }
        return day.formatted(dayDateFormat)
    }

    private func makeDay(from dateKey: String) -> Date? {
        let parts = dateKey.split(separator: "-", omittingEmptySubsequences: false)
        guard dateKey.count == 10,
              parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              let date = model.settings.calendar.date(from: DateComponents(
                  year: year,
                  month: month,
                  day: day
              )) else {
            return nil
        }
        let resolved = model.settings.calendar.dateComponents(
            [.year, .month, .day],
            from: date
        )
        guard resolved.year == year,
              resolved.month == month,
              resolved.day == day else {
            return nil
        }
        return date
    }

    private func makeDateKey(_ date: Date) -> String {
        let components = model.settings.calendar.dateComponents(
            [.year, .month, .day],
            from: date
        )
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
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
