import SwiftUI

struct SettingsView: View {
    @ObservedObject private var model: AppModel
    @State private var draft: AppSettings
    @State private var confirmsExampleLocation: Bool
    @State private var showsRecoveryConfirmation = false

    private var validationError: String? {
        if draft.storageRecoveryMessage != nil {
            return "本机设置需要重新确认。核对下方内容后，使用恢复按钮替换无法读取的旧设置。"
        }
        return draft.validationError
    }

    private var weatherConfigurationIssue: String? {
        model.weatherConfigurationIssue(
            for: draft,
            confirmsExampleLocation: confirmsExampleLocation
        )
    }

    private var canSaveFallbacks: Bool {
        validationError == nil && !model.isWorking
    }

    private var canSaveAndRefresh: Bool {
        validationError == nil
            && weatherConfigurationIssue == nil
            && !model.isWorking
    }

    init(model: AppModel) {
        self.model = model
        _draft = State(initialValue: model.settings)
        _confirmsExampleLocation = State(
            initialValue: model.isExampleLocationConfirmed(model.settings)
        )
    }

    var body: some View {
        Form {
            Section("天气服务器") {
                TextField("https://example.com/dawnpilot", text: $draft.serverBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("访问令牌", text: $draft.bearerToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("固定位置") {
                TextField(
                    "纬度",
                    value: $draft.latitude,
                    format: .number.precision(.fractionLength(4...6))
                )
                .keyboardType(.numbersAndPunctuation)
                TextField(
                    "经度",
                    value: $draft.longitude,
                    format: .number.precision(.fractionLength(4...6))
                )
                .keyboardType(.numbersAndPunctuation)
                TextField("时区", text: $draft.timeZoneIdentifier)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                if model.isUsingExampleLocation(draft) {
                    Toggle(
                        "确认这是我的固定位置",
                        isOn: $confirmsExampleLocation
                    )
                    Text("当前坐标是安装时提供的上海示例。只有确认后，晨航才会使用它判断天气。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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
                    "降水概率阈值：\(draft.precipitationProbabilityThreshold)%",
                    value: $draft.precipitationProbabilityThreshold,
                    in: 0...100,
                    step: 5
                )
                Text("""
                    达到该概率的明显降水（≥0.5mm）用雨天时间；\
                    只达到该概率的零星降水（≥0.1mm）用折中的保底时间；\
                    都不到才用晴天时间。阈值低于 50% 是刻意的：\
                    下雨天晚起的代价高于白早起。
                    """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("启用星期") {
                ForEach(WeekdayOption.all) { weekday in
                    Toggle(
                        "星期\(weekday.shortName)",
                        isOn: weekdayBinding(for: weekday.id)
                    )
                }
                Text("第一版不自动识别法定节假日或调休。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let validationError {
                Section("需要修正") {
                    Label(validationError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    if draft.storageRecoveryMessage != nil {
                        Button(role: .destructive, action: requestRecoveryConfirmation) {
                            Label(
                                "用当前表单替换损坏设置",
                                systemImage: "arrow.counterclockwise"
                            )
                        }
                        .confirmationDialog(
                            "替换无法读取的旧设置？",
                            isPresented: $showsRecoveryConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button(
                                "确认替换设置",
                                role: .destructive,
                                action: replaceRecoveredSettings
                            )
                        } message: {
                            Text("只会替换应用设置，不会重置系统闹钟记录。恢复后仍需由你明确选择重建闹钟。")
                        }
                    }
                }
            } else if let weatherConfigurationIssue {
                Section("天气更新准备") {
                    Label(weatherConfigurationIssue, systemImage: "cloud.sun")
                    Text("这不会阻止你先保存设置并创建未来 14 天的保底闹钟。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button(
                    "保存、重建并更新起床闹钟",
                    systemImage: "checkmark.circle",
                    action: saveAndRefresh
                )
                .disabled(!canSaveAndRefresh)

                Button(
                    "仅保存并重建保底闹钟",
                    systemImage: "shield.checkered",
                    action: saveFallbacksOnly
                )
                .disabled(!canSaveFallbacks)

                if model.isWorking {
                    ProgressView(model.operationPhase.message)
                }
            } footer: {
                Text("完整更新会先重建未来 14 天的保底闹钟，再用最新天气替换明天的一条。仅保底模式不会请求天气。")
            }

            if model.operationIssue != nil || model.operationSuccessMessage != nil {
                OperationFeedbackSection(
                    issue: model.operationIssue,
                    successMessage: model.operationSuccessMessage,
                    showsSettingsRecovery: false,
                    dismissIssue: model.dismissOperationIssue,
                    dismissSuccess: model.dismissOperationSuccess
                )
            }
        }
        .disabled(model.isWorking)
        .environment(\.calendar, draft.calendar)
        .environment(\.timeZone, draft.calendar.timeZone)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.isUsingExampleLocation(draft)) { wasExample, isExample in
            if isExample && !wasExample {
                confirmsExampleLocation = false
            }
        }
    }

    private func timePicker(
        _ title: String,
        keyPath: WritableKeyPath<AppSettings, ClockTime>
    ) -> some View {
        DatePicker(
            title,
            selection: Binding(
                get: {
                    draft[keyPath: keyPath].pickerDate(calendar: draft.calendar)
                },
                set: {
                    draft[keyPath: keyPath] = ClockTime(
                        date: $0,
                        calendar: draft.calendar
                    )
                }
            ),
            displayedComponents: .hourAndMinute
        )
    }

    private func weekdayBinding(for weekday: Int) -> Binding<Bool> {
        Binding(
            get: { draft.enabledWeekdays.contains(weekday) },
            set: { isEnabled in
                if isEnabled {
                    draft.enabledWeekdays.insert(weekday)
                } else {
                    draft.enabledWeekdays.remove(weekday)
                }
            }
        )
    }

    private func saveAndRefresh() {
        model.saveAndRebuild(
            settings: draft,
            includeWeatherRefresh: true,
            confirmsExampleLocation: confirmsExampleLocation
        )
    }

    private func saveFallbacksOnly() {
        model.saveAndRebuild(
            settings: draft,
            includeWeatherRefresh: false,
            confirmsExampleLocation: confirmsExampleLocation
        )
    }

    private func replaceRecoveredSettings() {
        let didRecover = model.replaceRecoveredSettings(
            with: draft,
            confirmsExampleLocation: confirmsExampleLocation
        )
        if didRecover {
            draft = model.settings
        }
    }

    private func requestRecoveryConfirmation() {
        showsRecoveryConfirmation = true
    }
}
