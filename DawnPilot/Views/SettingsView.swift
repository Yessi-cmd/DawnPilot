import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var showsManualLocation = false
    @State private var showsServerSettings = false

    var body: some View {
        Form {
            locationSection
            alarmTimesSection
            weatherRuleSection
            weekdaysSection
            serverSection
        }
        .formStyle(.grouped)
        .navigationTitle("地点与规则")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            applyButton
        }
    }

    private var locationSection: some View {
        Section {
            Button {
                model.useCurrentLocation()
            } label: {
                HStack {
                    Label(
                        model.settings.locationName == nil ? "使用当前位置" : "重新获取当前位置",
                        systemImage: "location.fill"
                    )
                    Spacer()
                    if model.isLocating {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(model.isLocating)

            LabeledContent("天气地点") {
                Text(model.settings.locationName ?? "尚未自动确认")
                    .foregroundStyle(model.settings.locationName == nil ? .secondary : .primary)
            }
            LabeledContent("坐标") {
                Text(coordinateText)
                    .monospacedDigit()
            }
            LabeledContent("时区", value: model.settings.timeZoneIdentifier)

            DisclosureGroup("高级：手动输入位置", isExpanded: $showsManualLocation) {
                TextField(
                    "纬度",
                    value: coordinateBinding(\.latitude),
                    format: .number.precision(.fractionLength(4...6))
                )
                .keyboardType(.numbersAndPunctuation)
                TextField(
                    "经度",
                    value: coordinateBinding(\.longitude),
                    format: .number.precision(.fractionLength(4...6))
                )
                .keyboardType(.numbersAndPunctuation)
                TextField("时区", text: $model.settings.timeZoneIdentifier)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        } header: {
            Label("天气位置", systemImage: "location.circle")
        } footer: {
            Text("仅在点击时获取一次位置并保存在本机；晨航不会持续跟踪或使用后台定位。")
        }
    }

    private var alarmTimesSection: some View {
        Section {
            timePicker("有降水", systemImage: "cloud.rain.fill", keyPath: \.rainyAlarmTime)
            timePicker("无法判断", systemImage: "cloud.fog.fill", keyPath: \.fallbackAlarmTime)
            timePicker("无降水", systemImage: "sun.max.fill", keyPath: \.clearAlarmTime)
        } header: {
            Label("闹钟时间", systemImage: "alarm")
        } footer: {
            Text("天气越差越早唤醒；天气不可用时始终保留安全时间。")
        }
    }

    private var weatherRuleSection: some View {
        Section {
            timePicker("通勤开始", systemImage: "sunrise.fill", keyPath: \.forecastWindowStart)
            timePicker("通勤结束", systemImage: "sun.max.fill", keyPath: \.forecastWindowEnd)
            Stepper(
                "降水概率阈值：\(model.settings.precipitationProbabilityThreshold)%",
                value: $model.settings.precipitationProbabilityThreshold,
                in: 0...100,
                step: 5
            )
        } header: {
            Label("天气判断", systemImage: "cloud.sun")
        }
    }

    private var weekdaysSection: some View {
        Section {
            HStack(spacing: 0) {
                ForEach(WeekdayOption.all) { weekday in
                    weekdayButton(weekday)
                    if weekday.id != WeekdayOption.all.last?.id {
                        Spacer(minLength: 4)
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Label("启用星期", systemImage: "calendar")
        } footer: {
            Text("晨航不会自动识别法定节假日或调休。")
        }
    }

    private var serverSection: some View {
        Section {
            DisclosureGroup("天气服务器", isExpanded: $showsServerSettings) {
                TextField("https://example.com/dawnpilot", text: $model.settings.serverBaseURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                SecureField("访问令牌", text: $model.settings.bearerToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        } header: {
            Label("连接", systemImage: "network")
        } footer: {
            Text("访问令牌仅保存在本机，不会写入应用源代码。")
        }
    }

    private var applyButton: some View {
        Button {
            model.saveAndRebuild()
        } label: {
            HStack(spacing: 10) {
                if model.isWorking {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                }
                Text(model.isWorking ? "正在应用…" : "应用并更新明日闹钟")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
        }
        .buttonStyle(.glassProminent)
        .tint(.indigo)
        .disabled(model.isWorking || model.isLocating)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func timePicker(
        _ title: String,
        systemImage: String,
        keyPath: WritableKeyPath<AppSettings, ClockTime>
    ) -> some View {
        DatePicker(
            selection: Binding(
                get: { model.settings[keyPath: keyPath].pickerDate(calendar: model.settings.calendar) },
                set: { model.settings[keyPath: keyPath] = ClockTime(date: $0, calendar: model.settings.calendar) }
            ),
            displayedComponents: .hourAndMinute
        ) {
            Label(title, systemImage: systemImage)
        }
    }

    private func weekdayButton(_ weekday: WeekdayOption) -> some View {
        let isEnabled = model.settings.enabledWeekdays.contains(weekday.id)
        return Button {
            if isEnabled {
                model.settings.enabledWeekdays.remove(weekday.id)
            } else {
                model.settings.enabledWeekdays.insert(weekday.id)
            }
        } label: {
            Text(weekday.shortName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isEnabled ? .white : .secondary)
                .frame(width: 36, height: 36)
                .background(isEnabled ? Color.indigo : Color.secondary.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("星期\(weekday.shortName)")
        .accessibilityValue(isEnabled ? "已启用" : "未启用")
    }

    private var coordinateText: String {
        String(format: "%.4f, %.4f", model.settings.latitude, model.settings.longitude)
    }

    private func coordinateBinding(_ keyPath: WritableKeyPath<AppSettings, Double>) -> Binding<Double> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in
                model.settings[keyPath: keyPath] = value
                model.settings.locationName = nil
            }
        )
    }
}
