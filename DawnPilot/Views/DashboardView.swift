import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: AppModel

    private var scene: WeatherScene {
        WeatherScene(alarmKind: model.nextRecord?.kind)
    }

    var body: some View {
        ZStack {
            WeatherBackgroundView(scene: scene)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 12) {
                    DashboardHeaderView(settings: model.settings)

                    AlarmHeroView(
                        record: model.nextRecord,
                        settings: model.settings,
                        scene: scene
                    )

                    if let guidance = model.configurationGuidance {
                        DashboardConfigurationCard(
                            guidance: guidance,
                            scene: scene
                        )
                    }

                    if model.operationIssue != nil || model.operationSuccessMessage != nil {
                        DashboardFeedbackCard(
                            issue: model.operationIssue,
                            successMessage: model.operationSuccessMessage,
                            dismissIssue: model.dismissOperationIssue,
                            dismissSuccess: model.dismissOperationSuccess,
                            scene: scene
                        )
                    }

                    DashboardProtectionCard(
                        records: model.records,
                        settings: model.settings,
                        isAuthorized: model.isAuthorized,
                        isWorking: model.isWorking,
                        repairAction: model.authorizeAndPrepare,
                        scene: scene
                    )

                    DashboardStatusCard(
                        status: model.status,
                        statusSummary: model.statusSummary,
                        authorizationText: model.authorizationText,
                        isAuthorized: model.isAuthorized,
                        verificationState: model.alarmVerificationState,
                        settings: model.settings,
                        scene: scene
                    )
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
        .task {
            model.loadSnapshot()
        }
    }
}

private struct DashboardHeaderView: View {
    let settings: AppSettings

    private var needsLocationConfirmation: Bool {
        settings.isUsingExampleLocation && !settings.exampleLocationConfirmed
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("晨航")
                    .font(.system(.title, design: .rounded, weight: .bold))
                Label(
                    needsLocationConfirmation ? "示例位置 · 尚未确认" : "固定天气位置",
                    systemImage: needsLocationConfirmation
                        ? "location.slash.fill"
                        : "location.fill"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(
                    needsLocationConfirmation ? Color.orange : Color.white.opacity(0.66)
                )
            }
            .foregroundStyle(.white)

            Spacer(minLength: 0)

            NavigationLink(value: ContentView.Route.settings) {
                Label("地点与规则设置", systemImage: "slider.horizontal.3")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        }
        .frame(height: 64)
    }
}

private struct DashboardConfigurationCard: View {
    let guidance: String
    let scene: WeatherScene

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("天气配置尚未完成", systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)

            Text(guidance)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.76))
                .fixedSize(horizontal: false, vertical: true)

            Text("你仍然可以先授权，并创建未来 14 天的保底闹钟。")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.60))

            NavigationLink(value: ContentView.Route.settings) {
                Label("完成地点与天气设置", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
        }
        .foregroundStyle(.white)
        .padding(16)
        .weatherPanel(scene: scene)
    }
}

private struct DashboardFeedbackCard: View {
    @Environment(\.openURL) private var openURL

    let issue: AppModel.OperationIssue?
    let successMessage: String?
    let dismissIssue: () -> Void
    let dismissSuccess: () -> Void
    let scene: WeatherScene

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let issue {
                Label(issue.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(issue.message)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)

                if issue.recoveryAction == .editSettings {
                    NavigationLink(value: ContentView.Route.settings) {
                        Label("检查设置", systemImage: "slider.horizontal.3")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                } else if issue.recoveryAction == .openSystemSettings {
                    Button(
                        "前往系统设置",
                        systemImage: "gear",
                        action: openSystemSettings
                    )
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.glass)
                }

                Button("关闭", role: .cancel, action: dismissIssue)
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.glass)
            } else if let successMessage {
                Label("操作完成", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.mint)
                Text(successMessage)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                Button("关闭", role: .cancel, action: dismissSuccess)
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.glass)
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .weatherPanel(scene: scene)
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

private struct DashboardProtectionCard: View {
    let records: [ManagedAlarmRecord]
    let settings: AppSettings
    let isAuthorized: Bool
    let isWorking: Bool
    let repairAction: () -> Void
    let scene: WeatherScene

    private var futureRecords: [ManagedAlarmRecord] {
        records.filter { $0.fireDate > .now }
    }

    private var upcomingRecords: [ManagedAlarmRecord] {
        Array(futureRecords.prefix(7))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: futureRecords.isEmpty ? "shield.slash" : "checkmark.shield.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(futureRecords.isEmpty ? .orange : .mint)
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.08), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(futureRecords.isEmpty ? "保底守护尚未开启" : "未来闹钟守护已开启")
                        .font(.subheadline.weight(.semibold))
                    Text(protectionDetail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.64))
                }

                Spacer(minLength: 0)
            }

            if !upcomingRecords.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(upcomingRecords) { record in
                            UpcomingAlarmChip(
                                record: record,
                                calendar: settings.calendar
                            )
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            if isAuthorized {
                Button(
                    "修复 14 天保底闹钟",
                    systemImage: "shield.checkered",
                    action: repairAction
                )
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .buttonStyle(.glass)
                .disabled(isWorking)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .weatherPanel(scene: scene)
    }

    private var protectionDetail: String {
        guard !futureRecords.isEmpty else {
            return "授权后会为启用日建立可靠的保底闹钟"
        }
        return "已有 \(futureRecords.count) 个未来闹钟，天气失败也不会漏响"
    }
}

private struct UpcomingAlarmChip: View {
    let record: ManagedAlarmRecord
    let calendar: Calendar

    private var dayText: String {
        if calendar.isDateInToday(record.fireDate) {
            return "今天"
        }
        if calendar.isDateInTomorrow(record.fireDate) {
            return "明天"
        }
        return DatePresentation.shortWeekday(record.fireDate, calendar: calendar)
    }

    private var timeText: String {
        ClockTime(date: record.fireDate, calendar: calendar).displayText
    }

    private var kindSymbol: String {
        switch record.kind {
        case .rainy: "cloud.rain.fill"
        case .clear: "sun.max.fill"
        case .fallback: "shield.fill"
        }
    }

    private var kindColor: Color {
        switch record.kind {
        case .rainy: Color(red: 0.52, green: 0.75, blue: 0.98)
        case .clear: Color(red: 0.99, green: 0.75, blue: 0.44)
        case .fallback: Color.white.opacity(0.55)
        }
    }

    var body: some View {
        VStack(spacing: 5) {
            Text(dayText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.62))
            Text(timeText)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
            Image(systemName: kindSymbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(kindColor)
        }
        .frame(minWidth: 58)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(dayText) \(timeText)，\(record.kind.displayName)闹钟")
    }
}

private struct DashboardStatusCard: View {
    let status: RefreshStatus
    let statusSummary: String
    let authorizationText: String
    let isAuthorized: Bool
    let verificationState: AppModel.AlarmVerificationState
    let settings: AppSettings
    let scene: WeatherScene

    private var schedulingTimeZone: TimeZone {
        settings.calendar.timeZone
    }

    private var statusDateFormat: Date.FormatStyle {
        var format = Date.FormatStyle.dateTime
            .month()
            .day()
            .hour()
            .minute()
        format.timeZone = schedulingTimeZone
        return format
    }

    private var statusIcon: String {
        switch status.outcome {
        case .rainy:
            "cloud.rain.fill"
        case .clear:
            "sun.max.fill"
        case .fallback:
            "shield.fill"
        case .skipped:
            "calendar.badge.minus"
        case .prepared:
            "alarm.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("最近一次判断", systemImage: "waveform.path.ecg")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(authorizationText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isAuthorized ? .mint : .orange)
            }

            AlarmVerificationBadge(
                state: verificationState,
                dateFormat: statusDateFormat
            )

            Label(statusSummary, systemImage: statusIcon)
                .font(.footnote.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)

            if status.message != statusSummary {
                Text(status.message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.66))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if status.updatedAt != .distantPast {
                StatusDateRow(
                    title: "最近判断",
                    date: status.updatedAt,
                    format: statusDateFormat
                )
            }

            if let alarmDate = status.alarmDate {
                StatusDateRow(
                    title: "本次闹钟",
                    date: alarmDate,
                    format: statusDateFormat
                )
            }

            if let fetchedAt = status.forecastFetchedAt {
                StatusDateRow(
                    title: "预报获取",
                    date: fetchedAt,
                    format: statusDateFormat
                )
            }

            if status.forecastWasStale {
                Label(
                    "本次判断使用了服务器缓存的预报",
                    systemImage: "clock.badge.exclamationmark"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .weatherPanel(scene: scene)
        .accessibilityElement(children: .combine)
    }
}

private struct AlarmVerificationBadge: View {
    let state: AppModel.AlarmVerificationState
    let dateFormat: Date.FormatStyle

    var body: some View {
        switch state {
        case .loading:
            Label("正在核对系统闹钟状态…", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.68))
        case .verified(let date):
            Label {
                Text("系统闹钟已核验 · \(date.formatted(dateFormat))")
            } icon: {
                Image(systemName: "checkmark.shield.fill")
            }
            .font(.caption)
            .foregroundStyle(.mint)
        case .unconfirmed:
            Label("暂无法确认系统闹钟是否存在", systemImage: "questionmark.diamond")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

private struct StatusDateRow: View {
    let title: String
    let date: Date
    let format: Date.FormatStyle

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Spacer(minLength: 8)
            Text(date, format: format)
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.60))
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

            if let record {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(countdownText(from: context.date, to: record.fireDate))
                        .font(.footnote.weight(.medium))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(.white.opacity(0.64))
                }
            }

            reasonPill
        }
    }

    private func countdownText(from now: Date, to fireDate: Date) -> String {
        guard fireDate > now else { return "即将响铃" }
        let components = settings.calendar.dateComponents(
            [.day, .hour, .minute],
            from: now,
            to: fireDate
        )
        let days = components.day ?? 0
        let hours = components.hour ?? 0
        let minutes = components.minute ?? 0
        if days > 0 {
            return "\(days) 天 \(hours) 小时后响铃"
        }
        if hours > 0 {
            return "\(hours) 小时 \(minutes) 分钟后响铃"
        }
        if minutes > 0 {
            return "\(minutes) 分钟后响铃"
        }
        return "即将响铃"
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
                settings.clearAlarmTime.minutesFromMidnight
                    - settings.rainyAlarmTime.minutesFromMidnight
            )
            return advance > 0 ? "预计有雨，已提前 \(advance) 分钟" : "预计有雨，按雨天规则唤醒"
        case .clear:
            return "通勤时段无明显降水"
        case .fallback:
            return "天气暂不可用，使用保底时间"
        }
    }
}

private struct RefreshDock: View {
    @ObservedObject var model: AppModel
    let scene: WeatherScene

    private var isAuthorized: Bool {
        model.isAuthorized
    }

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button(action: performPrimaryAction) {
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

                NavigationLink(value: ContentView.Route.automation) {
                    Label("自动更新设置", systemImage: "clock.badge.checkmark")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var primaryActionTitle: String {
        if model.isWorking { return "正在更新…" }
        return isAuthorized ? "立即更新闹钟" : "开启守护"
    }

    private func performPrimaryAction() {
        if isAuthorized {
            model.refreshNow()
        } else {
            model.authorizeAndPrepare()
        }
    }
}

struct AutomationGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "clock.arrow.trianglehead.2.counterclockwise.rotate.90")
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.indigo)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)

                VStack(spacing: 14) {
                    AutomationStep(
                        number: 1,
                        title: "创建个人自动化",
                        detail: "在快捷指令中选择“时间”作为触发条件。"
                    )
                    AutomationStep(
                        number: 2,
                        title: "设为每天 22:30",
                        detail: "睡前更新第二天的天气和闹钟时间。"
                    )
                    AutomationStep(
                        number: 3,
                        title: "添加晨航动作",
                        detail: "选择“更新起床闹钟”，设为立即运行并关闭运行前询问。"
                    )
                    AutomationStep(
                        number: 4,
                        title: "再建一条每天 06:00",
                        detail: "同样的动作。清晨的预报比前一晚准得多，会在响铃前校准今天的闹钟。"
                    )
                }

                Label(
                    "清晨校准只在距离最早闹钟还有 15 分钟以上时才会改动闹钟；系统后台刷新会额外尝试，但两条自动化仍是主要更新方式。",
                    systemImage: "info.circle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(16)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
            .padding(20)
        }
        .navigationTitle("自动更新闹钟")
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
    private static let weekdays = [
        "星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"
    ]

    private static let shortWeekdays = [
        "周日", "周一", "周二", "周三", "周四", "周五", "周六"
    ]

    static func day(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.month, .day, .weekday], from: date)
        let weekdayIndex = max(1, min(7, components.weekday ?? 1)) - 1
        return "\(components.month ?? 0)月\(components.day ?? 0)日 · \(weekdays[weekdayIndex])"
    }

    static func shortWeekday(_ date: Date, calendar: Calendar) -> String {
        let weekdayIndex = max(1, min(7, calendar.component(.weekday, from: date))) - 1
        return shortWeekdays[weekdayIndex]
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
