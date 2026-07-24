import SwiftUI

struct NextAlarmSection: View {
    let record: ManagedAlarmRecord?
    let snapshotState: AppModel.SnapshotState
    let settings: AppSettings

    private var schedulingTimeZone: TimeZone {
        settings.calendar.timeZone
    }

    private var alarmDayFormat: Date.FormatStyle {
        var format = Date.FormatStyle.dateTime
            .weekday(.wide)
            .month()
            .day()
        format.timeZone = schedulingTimeZone
        return format
    }

    private var alarmTimeFormat: Date.FormatStyle {
        var format = Date.FormatStyle.dateTime
            .hour()
            .minute()
        format.timeZone = schedulingTimeZone
        return format
    }

    var body: some View {
        Section("下一次闹钟") {
            if snapshotState == .loading {
                ProgressView("正在读取闹钟…")
            } else if let record {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading) {
                            Text(record.fireDate, format: alarmDayFormat)
                                .foregroundStyle(.secondary)
                            Text(record.kind.displayName)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(record.fireDate, format: alarmTimeFormat)
                            .font(.largeTitle)
                            .bold()
                            .fontDesign(.rounded)
                            .monospacedDigit()
                    }

                    VStack(alignment: .leading) {
                        Text(record.fireDate, format: alarmTimeFormat)
                            .font(.largeTitle)
                            .bold()
                            .fontDesign(.rounded)
                            .monospacedDigit()
                        Text(record.fireDate, format: alarmDayFormat)
                            .foregroundStyle(.secondary)
                        Text(record.kind.displayName)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilitySummary(for: record))
            } else {
                Label("尚未安排保底闹钟", systemImage: "alarm")
                Text("请先授权晨航，并创建未来 14 天的保底闹钟。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func accessibilitySummary(for record: ManagedAlarmRecord) -> String {
        let day = record.fireDate.formatted(alarmDayFormat)
        let time = record.fireDate.formatted(alarmTimeFormat)
        return "下一次闹钟，\(day)，\(time)，\(record.kind.displayName)"
    }
}
