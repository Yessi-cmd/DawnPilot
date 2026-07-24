import SwiftUI

struct RefreshStatusSection: View {
    @Environment(\.openURL) private var openURL

    let status: RefreshStatus
    let statusSummary: String
    let authorizationText: String
    let verificationState: AppModel.AlarmVerificationState
    let settings: AppSettings

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

    private var authorizationDisplayText: String {
        switch authorizationText {
        case "尚未授权":
            "尚未授权"
        case "已拒绝":
            "已拒绝"
        case "已授权":
            "已授权"
        case "读取中":
            "正在读取"
        default:
            "无法确认"
        }
    }

    var body: some View {
        Section("闹钟与天气状态") {
            switch verificationState {
            case .loading:
                ProgressView("正在核对闹钟状态…")
            case .verified(let date):
                Label("系统闹钟已核验", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                LabeledContent("核验时间") {
                    Text(date, format: statusDateFormat)
                }
            case .unconfirmed:
                Label(
                    "无法确认系统闹钟是否仍然存在",
                    systemImage: "questionmark.diamond"
                )
                .foregroundStyle(.orange)
                Text("当前仅显示晨航保存的记录。运行一次保底修复或天气更新后即可重新核验。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Label(statusSummary, systemImage: statusIcon)

            if status.updatedAt != .distantPast {
                LabeledContent("最近判断") {
                    Text(status.updatedAt, format: statusDateFormat)
                }
            }

            if let alarmDate = status.alarmDate {
                LabeledContent("本次闹钟") {
                    Text(alarmDate, format: statusDateFormat)
                }
            }

            if let fetchedAt = status.forecastFetchedAt {
                LabeledContent("预报获取") {
                    Text(fetchedAt, format: statusDateFormat)
                }
            }

            if status.forecastWasStale {
                Label(
                    "本次判断使用了服务器缓存的预报",
                    systemImage: "clock.badge.exclamationmark"
                )
                .foregroundStyle(.orange)
            }

            LabeledContent("系统闹钟权限", value: authorizationDisplayText)

            if authorizationText == "已拒绝" {
                Button(
                    "前往系统设置开启权限",
                    systemImage: "gear",
                    action: openSystemSettings
                )
            }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}
