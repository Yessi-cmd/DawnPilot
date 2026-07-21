import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    private var scene: WeatherScene {
        WeatherScene(alarmKind: model.nextRecord?.kind)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                WeatherBackgroundView(scene: scene)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        header
                        AlarmHeroView(
                            record: model.nextRecord,
                            settings: model.settings,
                            scene: scene
                        )
                        VStack(spacing: 12) {
                            if !model.records.isEmpty {
                                alarmList
                            }
                            protectionCard
                            latestStatusCard
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
                    .padding(.bottom, 104)
                }
                .scrollIndicators(.hidden)
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                RefreshDock(model: model, scene: scene)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 6)
            }
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

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("晨航")
                    .font(.system(.title, design: .rounded, weight: .bold))
                Label(
                    model.settings.locationName ?? "固定天气位置",
                    systemImage: "location.fill"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.66))
            }
            .foregroundStyle(.white)

            Spacer(minLength: 0)

            NavigationLink {
                SettingsView(model: model)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .accessibilityLabel("地点与规则设置")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        }
        .frame(height: 64)
    }

    private var protectionCard: some View {
        HStack(spacing: 14) {
            Image(systemName: model.records.isEmpty ? "shield.slash" : "checkmark.shield.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(model.records.isEmpty ? .orange : .mint)
                .frame(width: 38, height: 38)
                .background(.white.opacity(0.08), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(model.records.isEmpty ? "保底守护尚未开启" : "未来 14 天守护已开启")
                    .font(.subheadline.weight(.semibold))
                Text(protectionDetail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.64))
            }

            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .weatherPanel(scene: scene)
        .accessibilityElement(children: .combine)
    }

    private var latestStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("最近一次判断", systemImage: "waveform.path.ecg")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(model.authorizationText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(model.authorizationText == "已授权" ? .mint : .orange)
            }

            Text(model.status.message)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.74))
                .fixedSize(horizontal: false, vertical: true)

            if model.status.updatedAt != .distantPast {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                    Text("更新于 \(DatePresentation.timestamp(model.status.updatedAt, calendar: model.settings.calendar))")
                    if model.status.forecastWasStale {
                        Text("· 缓存天气")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.60))
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .weatherPanel(scene: scene)
        .accessibilityElement(children: .combine)
    }

    private var protectionDetail: String {
        guard !model.records.isEmpty else {
            return "授权后会为启用日建立可靠的保底闹钟"
        }
        return "已有 \(model.records.count) 个未来闹钟，天气失败也不会漏响"
    }

    private var alarmList: some View {
        VStack(spacing: 8) {
            Label("未来闹钟", systemImage: "list.bullet.rectangle.portrait")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(model.records) { record in
                HStack(spacing: 12) {
                    Image(systemName: record.kind.iconName)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(.white.opacity(0.10), in: Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.dateDescription(calendar: model.settings.calendar))
                            .font(.subheadline.weight(.medium))
                        Text(record.kindDescription)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.62))
                    }

                    Spacer(minLength: 0)

                    Text(ClockTime(date: record.fireDate, calendar: model.settings.calendar).displayText)
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                .contextMenu {
                    Button(role: .destructive) {
                        model.cancelAlarm(record)
                    } label: {
                        Label("删除此闹钟", systemImage: "trash")
                    }
                }
            }
        }
        .padding(16)
        .weatherPanel(scene: scene)
    }
}

private struct AlarmHeroView: View {
    let record: ManagedAlarmRecord?
    let settings: AppSettings
    let scene: WeatherScene

    @ScaledMetric(relativeTo: .largeTitle) private var timeSize = 78.0

    var body: some View {
        VStack(spacing: 12) {
            Text("下一次唤醒")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.58))

            if record == nil {
                emptyState
            } else {
                scheduledState
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 304)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var scheduledState: some View {
        VStack(spacing: 12) {
            Text(timeText)
                .font(.system(size: timeSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .minimumScaleFactor(0.68)
                .lineLimit(1)

            Text(dateText)
                .font(.title3.weight(.medium))
                .foregroundStyle(.white.opacity(0.84))

            reasonPill
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "alarm.waves.left.and.right")
                .font(.system(size: 52, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white.opacity(0.88))
                .frame(height: 76)

            Text("尚未安排闹钟")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)

            Text("完成授权后，将自动建立未来 14 天的安全闹钟")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.62))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
    }

    private var reasonPill: some View {
        HStack(spacing: 9) {
            Image(systemName: scene.symbolName)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 18, weight: .semibold))
            Text(reasonText)
                .font(.footnote.weight(.semibold))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(scene.glassTint), in: .capsule)
    }

    private var timeText: String {
        guard let record else { return "--:--" }
        return ClockTime(date: record.fireDate, calendar: settings.calendar).displayText
    }

    private var dateText: String {
        guard let record else { return "尚未安排闹钟" }
        return DatePresentation.day(record.fireDate, calendar: settings.calendar)
    }

    private var reasonText: String {
        guard let record else { return "授权后开启天气唤醒" }
        switch record.kind {
        case .rainy:
            let advance = max(
                0,
                settings.clearAlarmTime.minutesFromMidnight - settings.rainyAlarmTime.minutesFromMidnight
            )
            let reason = advance > 0 ? "预计有雨，已提前 \(advance) 分钟" : "预计有雨，按雨天规则唤醒"
            return manualPrefix + reason
        case .clear:
            return manualPrefix + "通勤时段无明显降水"
        case .fallback:
            return manualPrefix + "天气暂不可用，使用保底时间"
        }
    }

    private var manualPrefix: String {
        record?.origin == .manualOverride ? "临时闹钟 · " : ""
    }
}

private struct RefreshDock: View {
    @ObservedObject var model: AppModel
    let scene: WeatherScene

    private var isAuthorized: Bool {
        model.authorizationText == "已授权"
    }

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    if isAuthorized {
                        model.refreshNow()
                    } else {
                        model.authorizeAndPrepare()
                    }
                } label: {
                    HStack(spacing: 10) {
                        if model.isWorking {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: isAuthorized ? "arrow.clockwise" : "alarm.waves.left.and.right")
                        }
                        Text(primaryActionTitle)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    .frame(height: 48)
                    .padding(.horizontal, 16)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.glassProminent)
                .tint(scene.actionTint)
                .disabled(model.isWorking)

                NavigationLink {
                    AutomationGuideView()
                } label: {
                    Image(systemName: "clock.badge.checkmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .accessibilityLabel("每晚自动更新设置")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var primaryActionTitle: String {
        if model.isWorking { return "正在更新…" }
        guard isAuthorized else { return "开启守护" }
        return isTomorrowEnabled ? "更新明日闹钟" : "临时设明日闹钟"
    }

    private var isTomorrowEnabled: Bool {
        let calendar = model.settings.calendar
        guard let tomorrow = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: Date())
        ) else {
            return true
        }
        return model.settings.isEnabledAlarmDay(tomorrow)
    }
}

struct AutomationGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "clock.arrow.trianglehead.2.counterclockwise.rotate.90")
                    .font(.system(size: 54, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.indigo)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)

                VStack(spacing: 14) {
                    AutomationStep(number: 1, title: "创建个人自动化", detail: "在快捷指令中选择“时间”作为触发条件。")
                    AutomationStep(number: 2, title: "设为每天 22:30", detail: "睡前更新第二天的天气和闹钟时间。")
                    AutomationStep(number: 3, title: "添加晨航动作", detail: "选择“更新明日闹钟”，设为立即运行并关闭运行前询问。")
                }

                Label(
                    "系统后台刷新会额外尝试，但快捷指令是自签环境下的主要触发方式。",
                    systemImage: "info.circle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(16)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
            .padding(20)
        }
        .navigationTitle("每晚自动更新")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AutomationStep: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.indigo, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
    }
}

private enum DatePresentation {
    private static let weekdays = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]

    static func day(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.month, .day, .weekday], from: date)
        let weekdayIndex = max(1, min(7, components.weekday ?? 1)) - 1
        return "\(components.month ?? 0)月\(components.day ?? 0)日 · \(weekdays[weekdayIndex])"
    }

    static func timestamp(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        return String(
            format: "%d月%d日 %02d:%02d",
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0
        )
    }
}

private extension WeatherScene {
    var glassTint: Color {
        switch self {
        case .clear: .orange.opacity(0.34)
        case .rainy: .blue.opacity(0.34)
        case .unknown: .indigo.opacity(0.28)
        }
    }

    var actionTint: Color {
        switch self {
        case .clear: Color(red: 0.78, green: 0.43, blue: 0.23)
        case .rainy: Color(red: 0.20, green: 0.43, blue: 0.62)
        case .unknown: Color(red: 0.34, green: 0.36, blue: 0.62)
        }
    }

    var panelTint: Color {
        switch self {
        case .clear: Color(red: 0.08, green: 0.18, blue: 0.30)
        case .rainy: Color(red: 0.04, green: 0.13, blue: 0.19)
        case .unknown: Color(red: 0.10, green: 0.12, blue: 0.22)
        }
    }
}

private struct WeatherPanelModifier: ViewModifier {
    let scene: WeatherScene

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.black.opacity(reduceTransparency ? 0.64 : 0.16))
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(scene.panelTint.opacity(reduceTransparency ? 0.38 : 0.18))
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(.white.opacity(reduceTransparency ? 0.18 : 0.11), lineWidth: 0.7)
            }
        }
    }
}

private extension View {
    func weatherPanel(scene: WeatherScene) -> some View {
        modifier(WeatherPanelModifier(scene: scene))
    }
}

#Preview("雨天闹钟主视觉") {
    ZStack {
        WeatherBackgroundView(scene: .rainy)
            .ignoresSafeArea()
        AlarmHeroView(
            record: ManagedAlarmRecord(
                dateKey: "2026-07-20",
                alarmID: UUID(uuidString: "69D98B24-6F04-4381-B44C-E9565FB78312")!,
                fireDate: AppSettings().rainyAlarmTime.date(
                    on: Date(timeIntervalSinceReferenceDate: 806_284_800),
                    calendar: AppSettings().calendar
                )!,
                kind: .rainy,
                updatedAt: Date(timeIntervalSinceReferenceDate: 806_284_800)
            ),
            settings: AppSettings(),
            scene: .rainy
        )
        .padding(18)
    }
}
