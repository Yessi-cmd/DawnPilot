import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                nextAlarmSection
                statusSection
                actionsSection
                automationSection
                settingsSection
            }
            .navigationTitle("晨航")
            .task { model.loadSnapshot() }
            .alert(
                "操作未完成",
                isPresented: Binding(
                    get: { model.alertMessage != nil },
                    set: { if !$0 { model.alertMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(model.alertMessage ?? "未知错误")
            }
        }
    }

    private var nextAlarmSection: some View {
        Section("下一次闹钟") {
            if let record = model.nextRecord {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.fireDate, format: .dateTime.weekday(.wide).month().day())
                            .foregroundStyle(.secondary)
                        Text(record.kind.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(record.fireDate, format: .dateTime.hour().minute())
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            } else {
                Text("尚未安排。请先授权并创建保底闹钟。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusSection: some View {
        Section("最近一次判断") {
            Text(model.status.message)
            if model.status.updatedAt != .distantPast {
                LabeledContent("更新时间") {
                    Text(model.status.updatedAt, format: .dateTime.month().day().hour().minute())
                }
            }
            LabeledContent("AlarmKit 权限", value: model.authorizationText)
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                model.authorizeAndPrepare()
            } label: {
                Label("授权并创建保底闹钟", systemImage: "alarm.waves.left.and.right")
            }
            Button {
                model.refreshNow()
            } label: {
                Label("立即更新明日闹钟", systemImage: "arrow.clockwise")
            }
            .disabled(model.isWorking)

            if model.isWorking {
                ProgressView("正在更新…")
            }
        }
    }

    private var automationSection: some View {
        Section("每晚自动更新") {
            Label("快捷指令中创建“时间”个人自动化", systemImage: "1.circle")
            Label("建议每天 22:30 运行", systemImage: "2.circle")
            Label("动作选择“更新明日闹钟”并关闭运行前询问", systemImage: "3.circle")
            Text("系统后台刷新会额外尝试，但快捷指令是自签环境下的主触发方式。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var settingsSection: some View {
        Section {
            NavigationLink {
                SettingsView(model: model)
            } label: {
                Label("地点与规则设置", systemImage: "slider.horizontal.3")
            }
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("天气服务器") {
                TextField("https://example.com/dawnpilot", text: $model.settings.serverBaseURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                SecureField("访问令牌", text: $model.settings.bearerToken)
                    .textInputAutocapitalization(.never)
            }

            Section("固定位置") {
                TextField(
                    "纬度",
                    value: $model.settings.latitude,
                    format: .number.precision(.fractionLength(4...6))
                )
                .keyboardType(.numbersAndPunctuation)
                TextField(
                    "经度",
                    value: $model.settings.longitude,
                    format: .number.precision(.fractionLength(4...6))
                )
                .keyboardType(.numbersAndPunctuation)
                TextField("时区", text: $model.settings.timeZoneIdentifier)
                    .textInputAutocapitalization(.never)
            }

            Section("闹钟时间") {
                timePicker("有降水", keyPath: \.rainyAlarmTime)
                timePicker("无法判断", keyPath: \.fallbackAlarmTime)
                timePicker("无降水", keyPath: \.clearAlarmTime)
            }

            Section("天气判断") {
                timePicker("开始", keyPath: \.forecastWindowStart)
                timePicker("结束", keyPath: \.forecastWindowEnd)
                Stepper(
                    "降水概率阈值：\(model.settings.precipitationProbabilityThreshold)%",
                    value: $model.settings.precipitationProbabilityThreshold,
                    in: 0...100,
                    step: 5
                )
            }

            Section("启用星期") {
                ForEach(WeekdayOption.all) { weekday in
                    Toggle(
                        "星期\(weekday.shortName)",
                        isOn: Binding(
                            get: { model.settings.enabledWeekdays.contains(weekday.id) },
                            set: { enabled in
                                if enabled {
                                    model.settings.enabledWeekdays.insert(weekday.id)
                                } else {
                                    model.settings.enabledWeekdays.remove(weekday.id)
                                }
                            }
                        )
                    )
                }
                Text("第一版不自动识别法定节假日或调休。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    model.saveAndRebuild()
                } label: {
                    Label("保存、重建并更新明日闹钟", systemImage: "checkmark.circle")
                }
                .disabled(model.isWorking)
            } footer: {
                Text("保存会先恢复未来 14 天的默认闹钟，再尝试用最新天气替换明天的一条。")
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func timePicker(_ title: String, keyPath: WritableKeyPath<AppSettings, ClockTime>) -> some View {
        DatePicker(
            title,
            selection: Binding(
                get: { model.settings[keyPath: keyPath].pickerDate() },
                set: { model.settings[keyPath: keyPath] = ClockTime(date: $0) }
            ),
            displayedComponents: .hourAndMinute
        )
    }
}
